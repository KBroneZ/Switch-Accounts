// Hub mode, hub side: the tools the hub session calls and the successors it opens on its own.
// Only sessions of the hub account act as the hub. A worker is opened on one named account and
// stays there: its successor opens on the same account, and only while that account is ready.
// The hub never moves a worker to another account to get around a limit.
import type { EngineInterface } from 'claude-code'

import type { AccountView, Beat, ProviderView } from '../types'
import { isShown, normPath, shorten } from './core'
import {
  ABSOLUTE_PATH,
  appendInbox,
  earlierLiveSession,
  owesSuccessor,
  lastInboxSeq,
  briefPath,
  compactStatus,
  EFFORT,
  handoverPath,
  isWorkerAccount,
  MAX_BRIEF,
  MAX_MESSAGE,
  MODEL,
  needsSuccessor,
  parseWorker,
  PRIORITY_INPUTS,
  PRIORITY_LABEL,
  toPriority,
  WORKER_NAME,
  workerStartPrompt,
} from './hub-core'
import type { Priority, WorkerRecord } from './hub-core'
import { providerLines } from './providers'
import { runScript, S } from './shared'

const OPEN_TIMEOUT_MS = 180_000
/** After a failed successor, wait this long before trying again. */
const RETRY_MS = 5 * 60_000
/** A claim is settled after this long: the hub that wrote last owns it. */
const CLAIM_SETTLE_MS = 1_500
const retryAfter = new Map<string, number>()
const BRANCH = /^[A-Za-z0-9][A-Za-z0-9._/-]{0,79}$/

export type HubTool = 'fleet_status' | 'fleet_open_worker' | 'fleet_send' | 'fleet_stop_worker'

export const isHub = () => S.account !== null && S.account.toLowerCase() === S.cfg.hubAccount.toLowerCase()

/** Registering again replaces a tool, so this is safe on every session start. */
export async function registerHubTools($: EngineInterface) {
  const worker = { type: 'string', description: 'Worker name: 1-30 letters, digits, . _ - (e.g. w1)' }
  await $.tool.register({
    name: 'fleet_status',
    description:
      'Fleet hub: one line per Claude account (plan, health, 5-hour and weekly use against its caps, resets), per live session or worker (state, tool, context, hand-over, wait, last reply), and per other AI subscription the user has (ChatGPT via Codex, Gemini via Antigravity: windows, resets, reading age). Cheap; call it instead of reading files.',
    inputSchema: { type: 'object', properties: {}, additionalProperties: false },
  })
  await $.tool.register({
    name: 'fleet_open_worker',
    description:
      "Fleet hub: open a worker session on another of the user's accounts (not the hub's), in a folder or a new git worktree, with a brief. The account must be ready (logged in, below its caps); it is never swapped for another. The worker hands over to a fresh session of the same account at the context threshold and waits for its own account's reset at a limit.",
    inputSchema: {
      type: 'object',
      properties: {
        account: { type: 'string', description: 'Account name from accounts.json, e.g. B. Not "auto", not the hub account.' },
        worker,
        directory: { type: 'string', description: 'Absolute folder of the project (a git repo when worktree is set).' },
        brief: { type: 'string', description: 'The whole task, written for a session that knows nothing else. Saved to a file the worker reads.' },
        worktree: { type: 'string', description: 'Optional branch for a new worktree under <directory>/.claude/worktrees.' },
        model: { type: 'string', description: 'Optional: opus, sonnet, haiku, fable or a claude-* id.' },
        effort: { type: 'string', description: 'Optional: low, medium, high, xhigh or max.' },
        priority: { type: 'string', enum: PRIORITY_INPUTS, description: 'Optional task priority shown in the Fleet pane: high, medium or low (default medium). alta, media, baja are accepted too.' },
      },
      required: ['account', 'worker', 'directory', 'brief'],
      additionalProperties: false,
    },
  })
  await $.tool.register({
    name: 'fleet_send',
    description: 'Fleet hub: queue a message for a worker. It reaches the worker (or its successor) as a prompt once that session is idle.',
    inputSchema: { type: 'object', properties: { worker, text: { type: 'string' } }, required: ['worker', 'text'], additionalProperties: false },
  })
  await $.tool.register({
    name: 'fleet_stop_worker',
    description: 'Fleet hub: ask a worker to finish its current step, write its hand-over and stop; no successor is opened after it.',
    inputSchema: { type: 'object', properties: { worker }, required: ['worker'], additionalProperties: false },
  })
}

const recordPath = (name: string) => `${S.paths!.workers}/${name}.json`

export async function readRecord($: EngineInterface, name: string): Promise<WorkerRecord | null> {
  if (!S.paths || !WORKER_NAME.test(name)) return null
  const text = await $.fs.read(recordPath(name)).then(String, () => null)
  return text ? parseWorker(text) : null
}

async function writeRecord($: EngineInterface, record: WorkerRecord, keepStop = false) {
  // A write from a copy read earlier never undoes a fleet_stop_worker that landed in between.
  const stopped = keepStop && (await readRecord($, record.name))?.state === 'stopped'
  if (stopped) record = { ...record, state: 'stopped' }
  await $.fs.write(recordPath(record.name), JSON.stringify({ ...record, updatedAt: await $.clock.now() }, null, 2))
}

/**
 * Takes the record for this hub session: writes the claim, waits, reads it back. Of two hub
 * sessions racing, only the one whose claim is on disk after the wait goes on.
 */
async function claim($: EngineInterface, record: WorkerRecord): Promise<boolean> {
  const me = S.beat?.sessionId ?? null
  if (!me) return false
  await writeRecord($, { ...record, claimedBy: me }, true)
  await $.clock.sleep(CLAIM_SETTLE_MS)
  const back = await readRecord($, record.name)
  return back !== null && back.state === 'active' && back.claimedBy === me && back.generation === record.generation
}

const field = (input: Record<string, unknown>, key: string) => (typeof input[key] === 'string' ? (input[key] as string).trim() : '')

/** Opens the tab of one worker generation. Returns the folder it opened in, or throws with the script's words. */
async function openTab($: EngineInterface, record: WorkerRecord, worktree: string | null): Promise<string> {
  if (!isWorkerAccount(record.account, S.cfg.hubAccount)) throw new Error(`account ${record.account} cannot carry workers`)
  const args = ['-Account', record.account, '-WorkerName', record.name, '-Directory', record.directory, '-Json',
    '-InitialPrompt', workerStartPrompt(record.name, record.account, S.paths!.workers, record.generation)]
  if (worktree) args.push('-Worktree', worktree)
  if (record.model) args.push('-Model', record.model)
  if (record.effort) args.push('-Effort', record.effort)
  const r = await runScript($, args, OPEN_TIMEOUT_MS)
  if (r.exitCode !== 0) throw new Error(shorten((r.stderr || r.stdout).trim(), 400))
  try {
    const out = JSON.parse(r.stdout) as { Directory?: unknown }
    return typeof out.Directory === 'string' && out.Directory ? out.Directory : record.directory
  } catch {
    return record.directory
  }
}

function accountProblem(accounts: AccountView[], name: string): string | null {
  const a = accounts.find(x => x.name.toLowerCase() === name.toLowerCase())
  if (!a) return `account ${name} is not in accounts.json`
  if (a.health === 'ready') return null
  const reset = a.fiveHour.resetsAt ? `; 5 h reset: ${a.fiveHour.resetsAt}` : ''
  return `account ${a.name} is not available (${a.reason ?? a.health})${reset}`
}

/** A live session of this worker that started after the one asking for a successor. */
const newerSession = (beats: Beat[], asking: Beat, record: WorkerRecord, now: number) =>
  beats.find(b => b.worker === record.name && b.sessionId !== asking.sessionId && b.startedAt > asking.startedAt && b.startedAt >= record.openedAt && b.state !== 'ended' && b.rollover === 'none' && isShown(b, now))

/** A session of this worker that is still on the go (shown, not closed). */
const liveWorker = (beats: Beat[], name: string, now: number) => beats.find(b => b.worker === name && b.state !== 'ended' && isShown(b, now))

async function queueMail($: EngineInterface, name: string, text: string, now: number) {
  const path = `${S.paths!.inbox}/${name}.jsonl`
  const existing = await $.fs.read(path).then(String, () => '')
  const next = appendInbox(existing, 'hub', text, now)
  await $.fs.write(path, next.text)
  return next.seq
}

export async function hubToolCall($: EngineInterface, tool: HubTool, input: Record<string, unknown>, accounts: AccountView[], beats: Beat[], providers: ProviderView[] = []): Promise<string> {
  if (!S.paths) return 'Fleet has not started in this session yet.'
  if (!isHub()) return `Only the hub (account ${S.cfg.hubAccount}) uses these tools; this session is on account ${S.account ?? 'unknown'}.`
  const now = await $.clock.now()
  if (tool === 'fleet_status') {
    const byDir = new Map<string, string>()
    const text = await $.fs.read(S.paths.status).then(String, () => '')
    try {
      for (const a of (JSON.parse(text) as { accounts?: { name?: string; configDir?: string }[] }).accounts ?? []) {
        if (a.name && a.configDir) byDir.set(normPath(a.configDir), a.name)
      }
    } catch {
      // no snapshot yet
    }
    const shown = beats.filter(b => isShown(b, now))
    const lines = [compactStatus(accounts, shown, dir => byDir.get(normPath(dir)) ?? dir, now), ...providerLines(providers, now)].filter(Boolean)
    return lines.join('\n') || 'No accounts or sessions yet.'
  }
  const name = field(input, 'worker')
  if (!WORKER_NAME.test(name)) return 'Invalid worker name: 1-30 letters, digits, . _ -'
  if (tool === 'fleet_send') {
    const text = field(input, 'text')
    if (!text || text.length > MAX_MESSAGE) return `The message must be 1 to ${MAX_MESSAGE} characters.`
    if (!(await readRecord($, name))) return `There is no worker ${name}.`
    const seq = await queueMail($, name, text, now)
    return `Message ${seq} queued for ${name}; it gets there once the worker is free.`
  }
  if (tool === 'fleet_stop_worker') {
    const record = await readRecord($, name)
    if (!record) return `There is no worker ${name}.`
    await writeRecord($, { ...record, state: 'stopped' })
    await queueMail($, name, `The hub asks you to stop: finish the current step, write your hand-over to ${handoverPath(S.paths.workers, name)} and start nothing else.`, now)
    return `Worker ${name}: will stop after its current step; no successor will open.`
  }
  return openWorker($, name, input, accounts, beats, now)
}

async function openWorker($: EngineInterface, name: string, input: Record<string, unknown>, accounts: AccountView[], beats: Beat[], now: number) {
  const account = field(input, 'account')
  const directory = field(input, 'directory')
  const brief = typeof input.brief === 'string' ? input.brief.trim() : ''
  const worktree = field(input, 'worktree') || null
  const model = field(input, 'model') || null
  const effort = field(input, 'effort') || null
  const priorityIn = field(input, 'priority')
  const parsedPriority = toPriority(priorityIn)
  if (priorityIn && !parsedPriority) return 'priority must be high, medium or low.'
  const priority: Priority = parsedPriority ?? 'media'
  if (!isWorkerAccount(account, S.cfg.hubAccount)) {
    return `Name a specific work account (e.g. B): not "auto" and not the hub's (${S.cfg.hubAccount}).`
  }
  if (!ABSOLUTE_PATH.test(directory) || /[\r\n]/.test(directory)) return 'directory must be an absolute path.'
  if (!brief || brief.length > MAX_BRIEF) return `The brief must be 1 to ${MAX_BRIEF} characters.`
  if (worktree && !BRANCH.test(worktree)) return 'worktree is not a valid branch name.'
  if (model && !MODEL.test(model)) return 'Invalid model.'
  if (effort && !EFFORT.test(effort)) return 'Invalid effort.'
  const existing = await readRecord($, name)
  if (existing && existing.state === 'active' && existing.account.toLowerCase() !== account.toLowerCase()) {
    // A worker never changes account: that is how work would move to get around a limit.
    return `Worker ${name} belongs to account ${existing.account}. A worker never changes account: stop it with fleet_stop_worker or use another name.`
  }
  if (liveWorker(beats, name, now)) return `Worker ${name} is already running; use another name or fleet_send.`
  const problem = accountProblem(accounts, account)
  if (problem) return `Not opening the worker: ${problem}. Wait until that account is ready; no other account is used instead.`
  const record: WorkerRecord = {
    schema: 1,
    name,
    account,
    directory,
    model,
    effort,
    generation: 1,
    priority,
    state: 'active',
    openedAt: now,
    claimedBy: null,
    successorDue: null,
    // Mail left for an earlier run of this name (a stop request, say) is not this run's.
    mailFrom: lastInboxSeq(await $.fs.read(`${S.paths!.inbox}/${name}.jsonl`).then(String, () => '')),
    createdAt: existing?.createdAt ?? now,
    updatedAt: now,
  }
  await $.fs.write(briefPath(S.paths!.workers, name), brief)
  // Written before the tab opens, so a worker that starts always finds its record.
  await writeRecord($, record)
  try {
    const folder = await openTab($, record, worktree)
    if (folder !== directory) await writeRecord($, { ...record, directory: folder }, true)
    return `Worker ${name} opened on account ${account}, in ${folder}. Its brief is in ${briefPath(S.paths!.workers, name)}.`
  } catch (err) {
    await writeRecord($, { ...record, state: 'stopped' }).catch(() => undefined)
    return `Worker ${name} did not open: ${err instanceof Error ? err.message : String(err)}`
  }
}

/** The Deck's priority control: hub sessions only, an existing worker, one of the three values. */
export async function setWorkerPriority($: EngineInterface, name: string, input: string): Promise<string> {
  if (!S.paths) return 'Fleet has not started in this session yet.'
  if (!isHub()) return `Only the hub (account ${S.cfg.hubAccount}) changes priorities.`
  const priority = toPriority(input)
  if (!WORKER_NAME.test(name) || !priority) return 'Invalid priority or worker.'
  const record = await readRecord($, name)
  if (!record) return `There is no worker ${name}.`
  if (record.priority === priority) return `${name} already has priority ${PRIORITY_LABEL[priority]}.`
  await writeRecord($, { ...record, priority }, true)
  return `${name}: priority ${PRIORITY_LABEL[priority]}.`
}

/**
 * Notes each successor a worker asks for in its record, then opens every successor owed, on the
 * worker's own account, once that account is ready. Runs in hub sessions only, from the poll timer.
 */
export async function hubTick($: EngineInterface, accounts: AccountView[], beats: Beat[]) {
  if (!isHub() || !S.paths) return
  const now = await $.clock.now()
  await noteSuccessorRequests($, beats, now)
  await openOwedSuccessors($, accounts)
}

/** Writes `successorDue` for each shown heartbeat that asks for a successor (or adopts a tab already open). */
async function noteSuccessorRequests($: EngineInterface, beats: Beat[], now: number) {
  const live = beats.filter(b => isShown(b, now))
  const done = new Set<string>()
  for (const beat of live) {
    const name = beat.worker
    if (!name || done.has(name) || S.opening.has(name)) continue
    const record = await readRecord($, name)
    if (!record || !needsSuccessor(beat, record, S.cfg.hubAccount)) continue
    done.add(name)
    const newer = newerSession(beats, beat, record, now)
    if (newer) {
      // A tab opened by an earlier try that timed out: adopt it rather than open another.
      await writeRecord($, { ...record, generation: record.generation + 1, openedAt: newer.startedAt, claimedBy: null, successorDue: null }, true)
      continue
    }
    if (earlierLiveSession(live, beat, record)) continue // not this generation's worker: no duplicate
    if (record.successorDue !== record.generation) await writeRecord($, { ...record, successorDue: record.generation }, true)
  }
}

/** Opens one successor per worker whose record says one is owed and whose account is ready. */
async function openOwedSuccessors($: EngineInterface, accounts: AccountView[]) {
  const entries = await $.fs.list(S.paths!.workers).catch(() => [])
  const now = await $.clock.now()
  for (const f of entries) {
    if (f.kind !== 'file' || !f.name.endsWith('.json')) continue
    const name = f.name.slice(0, -'.json'.length)
    if (!WORKER_NAME.test(name) || S.opening.has(name) || (retryAfter.get(name) ?? 0) > now) continue
    const record = await readRecord($, name)
    if (!record || !owesSuccessor(record, S.cfg.hubAccount)) continue
    if (accountProblem(accounts, record.account)) continue // waits for its own account
    S.opening.add(name)
    try {
      const next: WorkerRecord = { ...record, generation: record.generation + 1, openedAt: now, successorDue: null }
      if (!(await claim($, next))) continue // another hub session took it
      await openTab($, next, null)
      await $.ui.toast(`Fleet: successor ${next.generation} of ${name} opened on account ${next.account}.`)
    } catch (err) {
      retryAfter.set(name, now + RETRY_MS)
      // Back to the generation that asked, still owed, so the next try can claim it again.
      await writeRecord($, { ...record, claimedBy: null }, true).catch(() => undefined)
      S.lastError = shorten(`Successor of ${name} not opened: ${err instanceof Error ? err.message : String(err)}`, 200)
    } finally {
      S.opening.delete(name)
    }
  }
}
