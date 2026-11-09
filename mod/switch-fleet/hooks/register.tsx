// Fleet: every Claude Code account you own and every session running on each, in one pane.
//
// Two halves. The heartbeat: this session writes what it is doing to
// ~/.claude-switch/live/<sessionId>.json (state, tool, model, context, cost and the limits of
// its own account), so any other session with this mod sees it. The pane: it reads those
// heartbeats and status.json (written by `open-session.ps1 -List`), and runs -List again when
// status.json is older than `refreshMinutes`. Local files and local CLIs; no model calls. The one
// request it makes itself is Antigravity's `/usage` (gemini.ts), when that CLI is installed.
import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { AccountView, Beat, DeckView, FleetView, HubView, Meter, PipelineView, ProviderView, SessionView } from '../types'
import { alertsFor, buildFleet, parsePipeline, fmtSpan, fmtWhen, forecastText, gauge, healthChanges, maskSecrets, normPath, parseBeat, parseSnapshot, shorten, statusText, toolDetail } from './core'
import { parseHistory } from './forecast'
import type { History } from './forecast'
import { renderDeck, drafts, EMPTY_DECK } from './deck'
import type { DeckActions, DeckElements, WorkerDraft } from './deck'
import { buildWorkers } from './deck-view'
import { hubTick, hubToolCall, isHub, registerHubTools, setWorkerPriority } from './hub'
import { parseWorker, WORKER_NAME } from './hub-core'
import { newestFirst, parseCodexRollout, providerAlerts, providerStatus } from './providers'
import { maybeAskGemini, readGemini } from './gemini'
import type { WorkerRecord } from './hub-core'
import type { HubTool } from './hub'
import { parseConfig, pathsOf, readUsage, S, setBeat, writeBeat } from './shared'
import { carryOver, workerName, workerTick, workerTurnDone } from './worker'

const PANE = 'switch-fleet'
const TITLE = 'Fleet'
const POLL_MS = 5_000
const IDLE_BEAT_MS = 60_000
const REFRESH_TIMEOUT_MS = 180_000
const LOCK_MS = 4 * 60_000

const fleet = atom({ plugin: 'switch-fleet', key: 'fleet' } as const, null, { shape: 'fleet-7' })
/** The Deck's notes and two-press controls (the desktop pane). */
const deck = atom({ plugin: 'switch-fleet', key: 'deck' } as const, EMPTY_DECK, { shape: 'deck-2' })
/** Alerts already shown, kept across sessions so each one is toasted once. */
const ALERTED_KEY = 'alerted'
const MAX_ALERTED = 100

async function readBeats($: EngineInterface): Promise<Beat[]> {
  if (!S.paths) return []
  const entries = await $.fs.list(S.paths.live).catch(() => [])
  const files = entries.filter(f => f.kind === 'file' && f.name.endsWith('.json'))
  const beats = await Promise.all(
    files.map(f => $.fs.read(`${S.paths!.live}/${f.name}`).then(t => parseBeat(String(t)), () => null)),
  )
  return beats.filter((b): b is Beat => b !== null)
}

/** Every hub worker record on disk (workers/<name>.json); briefs and hand-overs are skipped. */
async function readWorkers($: EngineInterface): Promise<{ records: WorkerRecord[]; briefs: Map<string, string> }> {
  if (!S.paths) return { records: [], briefs: new Map() }
  const entries = await $.fs.list(S.paths.workers).catch(() => [])
  const names = entries.filter(f => f.kind === 'file' && f.name.endsWith('.json')).map(f => f.name.slice(0, -'.json'.length)).filter(n => WORKER_NAME.test(n))
  const [records, briefs] = await Promise.all([
    Promise.all(names.map(n => $.fs.read(`${S.paths!.workers}/${n}.json`).then(t => parseWorker(String(t)), () => null))),
    // Only the head of a brief: the board shows its first line.
    Promise.all(names.map(n => $.fs.read(`${S.paths!.workers}/${n}.brief.md`).then(t => [n, String(t).slice(0, 400)] as const, () => null))),
  ])
  return {
    records: records.filter((r): r is WorkerRecord => r !== null),
    briefs: new Map(briefs.filter((b): b is readonly [string, string] => b !== null)),
  }
}

/** usage-history.jsonl, read again only when it changed (it grows with every -List). */
async function readHistory($: EngineInterface): Promise<History> {
  if (!S.paths) return S.history
  const stat = await $.fs.stat(S.paths.history).catch(() => null)
  if (!stat || stat.mtimeMs === S.historyMtime) return S.history
  const text = await $.fs.read(S.paths.history).then(String, () => null)
  if (text !== null) {
    S.history = parseHistory(text)
    S.historyMtime = stat.mtimeMs
  }
  return S.history
}

/** Toasts each warning once across sessions (the ids are kept in $.store). */
async function raiseAlerts($: EngineInterface, accounts: AccountView[], providers: ProviderView[], now: number) {
  const offset = new Date(now).getTimezoneOffset()
  const alerts = [...alertsFor(accounts, now, offset), ...providerAlerts(providers, now, iso => fmtWhen(iso, now, offset))]
  if (alerts.length === 0) return
  const stored = await $.store.get(ALERTED_KEY).catch(() => null)
  const seen = Array.isArray(stored) ? stored.filter((x): x is string => typeof x === 'string') : []
  const fresh = alerts.filter(a => !seen.includes(a.id))
  if (fresh.length === 0) return
  await $.store.set(ALERTED_KEY, [...seen, ...fresh.map(a => a.id)].slice(-MAX_ALERTED))
  for (const a of fresh) await $.ui.toast(a.text, { timeoutMs: 10_000 })
}

/** How often the Codex sessions folder is listed again; between listings the found file is re-read only when it changed. */
const CODEX_LIST_MS = 60_000
/** Rollout files tried, newest first, for one with rate limits (a session with no turn has none). */
const CODEX_TRIES = 6
const codex: { listedAt: number; files: string[]; path: string | null; mtime: number; view: ProviderView | null } = { listedAt: 0, files: [], path: null, mtime: 0, view: null }

/** The newest rollout files under <codexHome>/sessions/YYYY/MM/DD, newest first. */
async function listCodexRollouts($: EngineInterface, root: string): Promise<string[]> {
  const names = async (dir: string) => (await $.fs.list(dir).catch(() => [])).map(f => f.name)
  const out: string[] = []
  for (const y of newestFirst(await names(root))) {
    for (const m of newestFirst(await names(`${root}/${y}`))) {
      for (const d of newestFirst(await names(`${root}/${y}/${m}`))) {
        const files = (await names(`${root}/${y}/${m}/${d}`)).filter(n => /^rollout-.*\.jsonl$/.test(n)).sort().reverse()
        out.push(...files.map(f => `${root}/${y}/${m}/${d}/${f}`))
        if (out.length >= CODEX_TRIES) return out.slice(0, CODEX_TRIES)
      }
    }
  }
  return out
}

/** ChatGPT's rate limits from the newest Codex session that has them; nothing when Codex is not there. */
async function readCodex($: EngineInterface, now: number): Promise<ProviderView[]> {
  if (!S.paths) return []
  if (now - codex.listedAt > CODEX_LIST_MS) {
    codex.listedAt = now
    codex.files = await listCodexRollouts($, `${S.paths.codexHome}/sessions`)
  }
  for (const path of codex.files) {
    const stat = await $.fs.stat(path).catch(() => null)
    if (!stat || stat.kind !== 'file') continue
    if (path === codex.path && stat.mtimeMs === codex.mtime && codex.view) return [codex.view]
    const text = await $.fs.read(path).then(String, () => null)
    const view = text ? parseCodexRollout(text, now) : null
    if (view) {
      codex.path = path
      codex.mtime = stat.mtimeMs
      codex.view = view
      return [view]
    }
  }
  return []
}

async function rebuild($: EngineInterface) {
  if (!S.paths) return
  const [text, beats, history, pipelineText, workers, t] = await Promise.all([
    $.fs.read(S.paths.status).then(String, () => null),
    readBeats($),
    readHistory($),
    $.fs.read(S.paths.pipeline).then(String, () => null),
    readWorkers($),
    $.clock.now(),
  ])
  const snapshot = text ? parseSnapshot(text) : null
  if (snapshot && S.beat) {
    const mine = normPath(S.beat.configDir)
    S.account = snapshot.accounts.find(a => normPath(a.configDir) === mine)?.name ?? null
  }
  const built = buildFleet(snapshot, beats, t, S.beat?.sessionId ?? null, history)
  const before = await read($, fleet)
  const pipeline = pipelineText ? parsePipeline(pipelineText, t) : null
  const hub: HubView = {
    hubAccount: S.cfg.hubAccount,
    isHub: isHub(),
    rolloverPercent: S.cfg.rolloverPercent,
    cwd: S.beat?.cwd ?? null,
    workers: buildWorkers(workers.records, beats, S.cfg.hubAccount, t, workers.briefs),
  }
  const none = () => [] as ProviderView[]
  const providers = (await Promise.all([readCodex($, t).catch(none), readGemini($, t).catch(none)])).flat()
  const view: FleetView = { ...built, providers, hub, pipeline, isRefreshing: S.isRefreshing, error: S.lastError }
  // Redraw only when something a reader sees changed (builtAt alone does not count).
  const same = before && JSON.stringify({ ...before, builtAt: 0 }) === JSON.stringify({ ...view, builtAt: 0 })
  if (!same) await update($, fleet, () => view)
  for (const msg of healthChanges(before, built)) await $.ui.toast(msg)
  await raiseAlerts($, built.accounts, providers, t)
  if (S.cfg.statusLine) {
    const line = [statusText(built), ...providerStatus(providers)].filter(Boolean).join(' · ')
    await $.ui.status(line || undefined)
  }
  return { accounts: built.accounts, beats }
}

/** Runs `open-session.ps1 -List` when status.json is older than refreshMinutes (or when forced). */
async function maybeRefresh($: EngineInterface, force: boolean) {
  if (!S.paths || S.isRefreshing) return
  const t = await $.clock.now()
  if (!force) {
    const stat = await $.fs.stat(S.paths.status).catch(() => null)
    if (stat && t - stat.mtimeMs < S.cfg.refreshMs) return
    // Another session may be refreshing: one -List at a time across sessions.
    const lock = await $.fs.read(S.paths.lock).then(s => Number(String(s)), () => 0)
    if (lock && t - lock < LOCK_MS) return
  }
  if (!(await $.fs.exists(S.paths.script))) {
    S.lastError = `No encuentro ${S.paths.script}. Instala la skill switch-account o pon scriptPath.`
    await rebuild($)
    return
  }
  S.isRefreshing = true
  S.lastError = null
  try {
    await $.fs.write(S.paths.lock, String(t)).catch(() => undefined)
    await rebuild($)
    const r = await $.process.run(['pwsh', '-NoProfile', '-NonInteractive', '-File', S.paths.script, '-List'], { timeoutMs: REFRESH_TIMEOUT_MS })
    if (r.exitCode !== 0) S.lastError = shorten(`-List falló (${r.exitCode}): ${(r.stderr || r.stdout).trim()}`, 200)
  } catch (err) {
    S.lastError = shorten(`No pude ejecutar pwsh: ${String(err)}`, 200)
  } finally {
    S.isRefreshing = false
  }
  await rebuild($)
}

/** One poll: write the heartbeat when it changed (or every minute while idle), then redraw. */
async function tick($: EngineInterface) {
  if (S.beat && (S.isDirty || (await $.clock.now()) - S.beat.updatedAt > IDLE_BEAT_MS)) await writeBeat($)
  const seen = await rebuild($)
  // In the background: the answer lands in a file the next poll draws.
  void maybeAskGemini($, await $.clock.now()).catch(noteError)
  await workerTick($)
  if (seen) await hubTick($, seen.accounts, seen.beats)
}

/** A hub tool call: answered from a fresh look at the files. */
async function answerHubTool($: EngineInterface, tool: HubTool, input: Record<string, unknown>) {
  const seen = await rebuild($)
  const text = await hubToolCall($, tool, input, seen?.accounts ?? [], seen?.beats ?? [])
  return { result: text }
}

/** Sets the Deck's note (and clears what waited for a second press). */
async function deckNote($: EngineInterface, note: string | null, isError = false, patch: Partial<DeckView> = {}) {
  await update($, deck, d => ({ ...(d ?? EMPTY_DECK), note, isNoteError: isError, confirmStop: null, ...patch }))
}

/** A Deck control that acts as the hub: the same checks as the model's fleet_* tools. */
async function deckHub($: EngineInterface, tool: HubTool, input: Record<string, unknown>): Promise<string> {
  const seen = await rebuild($)
  const text = await hubToolCall($, tool, input, seen?.accounts ?? [], seen?.beats ?? [])
  await rebuild($)
  return text
}

/** An open from the Deck in flight: checked and set before any await, so a double press opens one. */
let isDeckOpening = false

function deckActions($: EngineInterface): DeckActions {
  const run = (work: () => Promise<void>) => void work().catch(err => {
    noteError(err)
    void deckNote($, `Error: ${shorten(String(err), 200)}`, true, { busy: null }).catch(() => undefined)
  })
  return {
    refresh: () => run(() => maybeRefresh($, true)),
    openSession: account => run(() => openSessionOn($, account)),
    send: (worker, text) =>
      run(async () => {
        if (!text.trim()) return
        const answer = await deckHub($, 'fleet_send', { worker, text })
        drafts.messages[worker] = ''
        drafts.sent[worker] = (drafts.sent[worker] ?? 0) + 1
        await deckNote($, answer, !/^Mensaje \d+ en cola/.test(answer))
      }),
    askStop: worker =>
      run(async () => {
        const at = await $.clock.now()
        await update($, deck, d => ({ ...(d ?? EMPTY_DECK), confirmStop: worker, confirmAt: at }))
      }),
    stop: worker =>
      run(async () => {
        const answer = await deckHub($, 'fleet_stop_worker', { worker })
        await deckNote($, answer, !/^Worker \S+: parará/.test(answer))
      }),
    toggleForm: () =>
      run(async () => {
        await update($, deck, d => ({ ...(d ?? EMPTY_DECK), isFormOpen: !(d ?? EMPTY_DECK).isFormOpen }))
      }),
    openWorker: (draft: WorkerDraft) =>
      run(async () => {
        if (isDeckOpening) return
        isDeckOpening = true
        try {
          await openFromDeck(draft)
        } finally {
          isDeckOpening = false
        }
      }),
    setPriority: (worker, priority) =>
      run(async () => {
        const answer = await setWorkerPriority($, worker, priority)
        await rebuild($)
        await deckNote($, answer, !answer.startsWith(`${worker}:`) && !answer.includes('ya tiene'))
      }),
    dismissNote: () => run(() => deckNote($, null)),
  }

  async function openFromDeck(draft: WorkerDraft) {
    await deckNote($, `Abriendo el worker ${draft.name || '?'} en la cuenta ${draft.account || '?'}…`, false, { busy: 'open' })
    const input: Record<string, unknown> = { account: draft.account, worker: draft.name, directory: draft.directory, brief: draft.brief }
    if (draft.model) input.model = draft.model
    if (draft.effort) input.effort = draft.effort
    if (draft.priority) input.priority = draft.priority
    const answer = await deckHub($, 'fleet_open_worker', input)
    const isOpened = answer.startsWith(`Worker ${draft.name} abierto`)
    if (isOpened) drafts.worker = { ...drafts.worker, name: '', brief: '' }
    await deckNote($, answer, !isOpened, { busy: null, ...(isOpened ? { isFormOpen: false } : {}) })
  }
}

function noteError(err: unknown) {
  S.lastError = shorten(`Fleet: ${String(err)}`, 200)
}

/**
 * Opens a Claude Code tab on one account in this session's folder, through the same script the
 * switch-account skill runs (it checks caps and readiness itself). Answers a press, never a timer.
 */
async function openSessionOn($: EngineInterface, account: string) {
  if (!S.paths || !S.beat) return
  if (!/^[A-Za-z0-9._-]{1,40}$/.test(account)) return
  await $.ui.toast(`Abriendo una sesión en la cuenta ${account}…`)
  const r = await $.process.run(
    ['pwsh', '-NoProfile', '-NonInteractive', '-File', S.paths.script, '-Account', account, '-Directory', S.beat.cwd],
    { timeoutMs: REFRESH_TIMEOUT_MS },
  )
  const lines = (r.exitCode === 0 ? r.stdout : r.stderr || r.stdout).trim().split(/\r?\n/)
  const last = lines[lines.length - 1] ?? ''
  await $.ui.toast(r.exitCode === 0 ? last : `No se abrió (código ${r.exitCode}): ${shorten(last, 160)}`, { timeoutMs: 10_000 })
}

/** The per-day usage table of usage-report.ps1, which the skill installs beside open-session.ps1. */
async function usageReport($: EngineInterface): Promise<string> {
  if (!S.paths) return 'Fleet aún no ha arrancado.'
  // The sibling of the configured script by folder and a fixed name, never the script itself.
  const folder = S.paths.script.replace(/[\\/][^\\/]*$/, '')
  const script = `${folder}/usage-report.ps1`
  if (folder === S.paths.script || !(await $.fs.exists(script))) return `No encuentro ${script}. Reinstala la skill switch-account.`
  const r = await $.process.run(['pwsh', '-NoProfile', '-NonInteractive', '-File', script], { timeoutMs: 60_000 })
  const out = (r.exitCode === 0 ? r.stdout : r.stderr || r.stdout).trim()
  const fence = '```'
  return r.exitCode === 0 ? [fence, out, fence].join('\n') : `El informe falló (${r.exitCode}): ${shorten(out, 300)}`
}

/** Opens the pane once per load when openOnStart is on and something other than a phone draws. */
async function openOnStart($: EngineInterface) {
  if (!S.cfg.openOnStart || S.hasOpenedOnStart) return
  const surfaces = await $.session.surfaces().catch(() => [] as const)
  if (!surfaces.some(s => s !== 'mobile')) return
  S.hasOpenedOnStart = true
  void openPane($).catch(err => noteError(err))
}

async function openPane($: EngineInterface) {
  return $.ui.open({ id: PANE, title: TITLE, columns: 64, rows: 12 })
}

export const register: Register = (on, options) => {
  S.cfg = parseConfig(options)

  // ------------------------------------------------------------ heartbeat

  on('session.start', async ($, e, next) => {
    const done = await next(e)
    await $.command.register({
      name: 'fleet',
      description: 'Fleet: all your Claude Code accounts and their sessions in one pane',
      argumentHint: '[open|close|refresh|report]',
    })
    S.paths = await pathsOf($, S.cfg)
    await registerHubTools($)
    const [id, cwd, model, repo, configDir, t, worker] = await Promise.all([
      $.session.id(),
      $.session.cwd(),
      $.session.model().catch(() => null),
      $.session.repo().catch(() => null),
      $.env.get('CLAUDE_CONFIG_DIR'),
      $.clock.now(),
      workerName($),
    ])
    S.beat = {
      schema: 1,
      sessionId: id,
      configDir: configDir || S.paths.defaultConfigDir,
      cwd,
      repo: repo?.name ?? null,
      model,
      state: 'idle',
      tool: null,
      detail: null,
      prompt: null,
      ctxPct: null,
      costUsd: null,
      limits: null,
      limitsAt: null,
      worker,
      rollover: 'none',
      rolloverAt: null,
      waitingUntil: null,
      lastReply: null,
      finished: false,
      turns: 0,
      startedAt: t,
      stateSince: t,
      updatedAt: t,
    }
    // A reload runs this again: keep what the heartbeat of this same session already said.
    const previous = await $.fs.read(`${S.paths.live}/${id}.json`).then(t => parseBeat(String(t)), () => null)
    S.beat = carryOver(previous, S.beat)
    await setBeat($, await readUsage($), true)
    if (!S.hasTimers) {
      // One set of timers per load, however often session.start fires.
      S.hasTimers = true
      $.clock.every(POLL_MS, () => void tick($).catch(err => noteError(err)))
      $.clock.every(60_000, () => void maybeRefresh($, false).catch(err => noteError(err)))
    }
    // An open that was in flight when the module last stopped is not running any more.
    await update($, deck, d => ({ ...(d ?? EMPTY_DECK), busy: null, confirmStop: null, confirmAt: null })).catch(err => noteError(err))
    await rebuild($).catch(err => noteError(err))
    void maybeRefresh($, false).catch(err => noteError(err))
    // Under the REPL the terminal is there at start. The desktop app and the editor run the
    // session through the SDK and attach later, so those open at the first turn.
    if (e.isInteractive) await openOnStart($)
    return done
  })

  on('turn.start', async ($, e, next) => {
    if (!e.agentId) await openOnStart($)
    if (!e.agentId) {
      const prompt = e.text.trim() ? shorten(maskSecrets(e.text.replace(/\s+/g, ' ').trim()), 70) : null
      await setBeat($, { state: 'working', tool: null, detail: null, prompt, model: await $.session.model().catch(() => S.beat?.model ?? null) }, true)
    }
    return next(e)
  })

  on('tool.call', async ($, e, next) => {
    if (!e.agentId && S.beat) {
      const input = e as unknown as Record<string, unknown>
      await setBeat($, { tool: String(e.tool), detail: toolDetail(String(e.tool), input) }, false)
    }
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    const done = await next(e)
    if (!('agentId' in e && e.agentId) && S.beat) {
      await setBeat($, { state: 'idle', tool: null, detail: null, turns: S.beat.turns + 1, ...(await readUsage($)) }, true)
      await workerTurnDone($, typeof done?.text === 'string' ? done.text : '')
    }
    return done
  })

  on('tool.call', { tool: 'mcp__switch-fleet__fleet_status' }, async ($, e) =>
    answerHubTool($, 'fleet_status', e as unknown as Record<string, unknown>),
  )
  on('tool.call', { tool: 'mcp__switch-fleet__fleet_open_worker' }, async ($, e) =>
    answerHubTool($, 'fleet_open_worker', e as unknown as Record<string, unknown>),
  )
  on('tool.call', { tool: 'mcp__switch-fleet__fleet_send' }, async ($, e) =>
    answerHubTool($, 'fleet_send', e as unknown as Record<string, unknown>),
  )
  on('tool.call', { tool: 'mcp__switch-fleet__fleet_stop_worker' }, async ($, e) =>
    answerHubTool($, 'fleet_stop_worker', e as unknown as Record<string, unknown>),
  )

  on('session.end', async ($, e, next) => {
    await setBeat($, { state: 'ended', tool: null, detail: null }, true)
    return next(e)
  })

  // ------------------------------------------------------------ command

  on('command.run', { command: 'fleet' }, async ($, e) => {
    const verb = e.args.trim().split(/\s+/)[0] || 'open'
    if (verb === 'close') {
      await $.ui.close({ id: PANE })
      return { text: 'Fleet cerrado.' }
    }
    if (verb === 'report') {
      return { text: await usageReport($) }
    }
    if (verb === 'refresh') {
      void maybeRefresh($, true).catch(err => noteError(err))
      await openPane($)
      return { text: 'Fleet: leyendo el uso de todas las cuentas…' }
    }
    const opened = await openPane($)
    return { text: opened.isPlaced ? 'Fleet abierto. /fleet refresh vuelve a leer el uso.' : `Fleet aún no se muestra: ${opened.reason}` }
  })

  // ------------------------------------------------------------ pane

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    if (e.surface === 'desktop' || e.surface === 'vscode') {
      const [view, d, now] = await Promise.all([read($, fleet), read($, deck), $.clock.now()])
      return renderDeck($.ui.resolve(e) as unknown as DeckElements, view, d ?? EMPTY_DECK, now, deckActions($))
    }
    const { Box, Text, Button } = $.ui.resolve(e)
    const [view, t] = await Promise.all([read($, fleet), $.clock.now()])
    const W = Math.max(28, e.props.bodyColumns)
    const offset = new Date(t).getTimezoneOffset()
    const C = { main: 'claude', ok: 'success', warn: 'warning', bad: 'error', dim: 'inactive', faint: 'subtle', text: 'text', info: 'suggestion' } as const

    const header = (
      <Box justifyContent="space-between" width={W}>
        <Text color={C.main} bold>
          FLEET
        </Text>
        <Box flexShrink={0} columnGap={1}>
          <Text color={C.dim}>
            {view?.isRefreshing ? 'leyendo uso…' : view?.snapshotAt ? `uso hace ${fmtSpan(t - Date.parse(view.snapshotAt))}` : 'sin datos de uso'}
          </Text>
          <Button key="refresh" hotkey="r" label="actualizar" onPress={() => void maybeRefresh($, true).catch(err => noteError(err))} />
        </Box>
      </Box>
    )
    if (!view) {
      return (
        <Box flexDirection="column" width={W}>
          {header}
          <Text color={C.dim}>Cargando…</Text>
        </Box>
      )
    }

    const healthChip = (a: AccountView) => {
      switch (a.health) {
        case 'ready':
          return <Text color={C.ok}>● lista</Text>
        case 'at-cap':
          return <Text color={C.warn}>◐ {a.reason}</Text>
        case 'logged-out':
          return <Text color={C.bad}>✗ login caducado</Text>
        case 'not-ready':
          return <Text color={C.warn}>◌ {a.reason}</Text>
        default:
          return <Text color={C.dim}>? desconocido</Text>
      }
    }

    const meterRow = (label: string, m: Meter, inner: number) => {
      if (m.pct === null) {
        return (
          <Box>
            <Text color={C.dim}>{label.padEnd(4)}sin dato</Text>
          </Box>
        )
      }
      const gw = Math.max(6, Math.min(16, inner - 30))
      const g = gauge(m.pct, gw)
      const isOver = m.cap !== null && m.pct >= m.cap
      const isNear = m.cap !== null && m.pct >= m.cap - 10
      const color = isOver ? C.bad : isNear ? C.warn : C.ok
      const reset = m.resetsAt ? `↻ ${fmtWhen(m.resetsAt, t, offset)} (${fmtSpan(Date.parse(m.resetsAt) - t)})` : ''
      return (
        <Box columnGap={1} overflow="hidden">
          <Text color={C.dim}>{label.padEnd(3)}</Text>
          <Text>
            <Text color={color}>{g.on}</Text>
            <Text color={C.faint}>{g.off}</Text>
          </Text>
          <Text color={color} bold>
            {`${Math.round(m.pct)}%`.padStart(4)}
          </Text>
          <Text color={C.dim}>{m.cap !== null ? `/${Math.round(m.cap)}` : ''}</Text>
          <Text color={C.dim} wrap="truncate">
            {reset}
            {m.isLive ? ' ·en vivo' : ''}
          </Text>
        </Box>
      )
    }

    const forecastRow = (f: AccountView['fiveHourForecast']) => {
      const line = forecastText(f, t, offset)
      if (!line) return null
      return (
        <Text color={line.isWarning ? C.warn : C.dim} wrap="truncate">
          {'    '}
          {line.text}
        </Text>
      )
    }

    const sessionRow = (s: SessionView, inner: number) => {
      const isWorking = s.state === 'working'
      const dot = s.liveness === 'quiet' ? '◌' : isWorking ? '●' : s.state === 'ended' ? '✕' : '○'
      const color = s.liveness === 'quiet' || s.state === 'ended' ? C.faint : isWorking ? C.main : C.dim
      const badge = s.waitingUntil
        ? `esperando reinicio (${fmtWhen(s.waitingUntil, t, offset)})`
        : s.rollover === 'requested'
          ? 'escribiendo relevo'
          : s.rollover === 'ready'
            ? 'relevo listo, esperando sucesor'
            : null
      const idleWhat = s.state === 'ended' ? 'cerrada' : (badge ?? (s.lastReply ? `en espera · «${s.lastReply}»` : 'en espera'))
      const what = isWorking ? (s.tool ? `${s.tool}${s.detail ? `: ${s.detail}` : ''}` : 'pensando') : idleWhat
      const meta = [s.model ? s.model.replace(/^claude-/, '').replace(/-\d{8}$/, '') : null, s.ctxPct !== null ? `ctx ${Math.round(s.ctxPct)}%` : null, s.costUsd ? `$${s.costUsd.toFixed(2)}` : null, fmtSpan(t - s.stateSince)]
        .filter(Boolean)
        .join(' · ')
      return (
        <Box flexDirection="column" width={inner}>
          <Box justifyContent="space-between" width={inner} overflow="hidden">
            <Text color={color} bold={isWorking} wrap="truncate">
              {dot} {s.worker ? `[${s.worker}] ` : ''}
              {s.place}
              {s.isSelf ? ' (esta)' : ''}
              {s.quotaAccount ? <Text color={C.warn}>{` · cuota de ${s.quotaAccount}`}</Text> : null}
            </Text>
            <Box flexShrink={0}>
              <Text color={C.dim}>{meta}</Text>
            </Box>
          </Box>
          <Text color={isWorking ? C.text : C.dim} wrap="truncate">
            {'  '}
            {shorten(what, Math.max(10, inner - 2))}
          </Text>
          {s.prompt && isWorking ? (
            <Text color={C.faint} wrap="truncate">
              {'  “'}
              {shorten(s.prompt, Math.max(10, inner - 4))}”
            </Text>
          ) : null}
        </Box>
      )
    }

    const pipelineBox = (p: PipelineView) => {
      const inner = W - 4
      const color = p.state === 'running' ? C.main : p.state === 'waiting' ? C.warn : p.state === 'stopped' ? C.bad : C.dim
      const label = { running: '● en marcha', waiting: '◐ esperando reinicio', done: '✓ terminado', stopped: '✗ parado' }[p.state]
      return (
        <Box key="pipeline" flexDirection="column" borderStyle="single" borderColor={color} paddingX={1} width={W}>
          <Box justifyContent="space-between" width={inner}>
            <Text bold wrap="truncate">
              <Text color={C.main}>PIPELINE</Text>
              <Text color={C.dim}>{` · ${p.repo} · ciclo ${p.cycle}/${p.maxCycles}`}</Text>
            </Text>
            <Box flexShrink={0}>
              <Text color={color}>{label}</Text>
            </Box>
          </Box>
          {p.roles.map(role => (
            <Text color={C.text} wrap="truncate">
              {role.role === 'implementer' ? 'A implementa' : 'B revisa'}
              <Text color={C.dim}>{` · tarea ${role.task ?? '—'} · ${[role.outcome, role.status].filter(Boolean).join(' ')}`}</Text>
            </Text>
          ))}
          {p.waitUntil ? <Text color={C.warn}>reintenta {fmtWhen(p.waitUntil, t, offset)}</Text> : null}
          {p.message ? (
            <Text color={C.dim} wrap="truncate">
              {p.message}
            </Text>
          ) : null}
          <Text color={C.faint}>act. hace {fmtSpan(t - Date.parse(p.updatedAt))}</Text>
        </Box>
      )
    }

    const providerBox = (p: ProviderView) => {
      const inner = W - 4
      const color = p.health === 'at-cap' ? C.bad : p.isStale ? C.faint : C.info
      return (
        <Box key={`prov-${p.id}`} flexDirection="column" borderStyle="round" borderColor={color} paddingX={1} width={W}>
          <Box justifyContent="space-between" width={inner}>
            <Text bold wrap="truncate">
              <Text color={C.info}>{p.name}</Text>
              <Text color={C.dim}>{`${p.plan ? ` · ${p.plan}` : ''} · vía ${p.source}`}</Text>
            </Text>
            <Box flexShrink={0}>{p.health === 'at-cap' ? <Text color={C.bad}>✗ límite</Text> : p.health === 'ready' ? <Text color={C.ok}>● disponible</Text> : <Text color={C.dim}>? sin dato</Text>}</Box>
          </Box>
          {p.windows.map(w => {
            const meter: Meter = { pct: w.pct, cap: null, resetsAt: w.resetsAt, isLive: false }
            // A group's name (Claude/GPT 7d) gets its own line; a bare window (30d) sits beside its gauge.
            return w.label.length <= 4 ? (
              <Box key={`pw-${p.id}-${w.label}`}>{meterRow(w.label, meter, inner)}</Box>
            ) : (
              <Box key={`pw-${p.id}-${w.label}`} flexDirection="column">
                <Text color={C.dim}>{w.label}</Text>
                {meterRow('', meter, inner)}
              </Box>
            )
          })}
          <Text color={p.isStale ? C.warn : C.faint}>{p.readAt ? `leído hace ${fmtSpan(t - p.readAt)} (${p.readNote})` : 'sin fecha de lectura'}</Text>
        </Box>
      )
    }

    const card = (a: AccountView, index: number) => {
      const inner = W - 4
      const border = a.health === 'logged-out' ? C.bad : a.health === 'at-cap' ? C.warn : a.health === 'ready' ? C.main : C.faint
      const working = a.sessions.filter(s => s.state === 'working').length
      const days = a.loginExpiresAt ? (Date.parse(a.loginExpiresAt) - t) / 86_400_000 : null
      return (
        <Box key={`acct-${a.name}`} flexDirection="column" borderStyle="round" borderColor={border} paddingX={1} width={W}>
          <Box justifyContent="space-between" width={inner}>
            <Text bold wrap="truncate">
              <Text color={C.main}>{a.name}</Text>
              <Text color={C.dim}>{a.plan ? ` · ${a.plan}` : ''}</Text>
              <Text color={C.dim}>{a.sessions.length ? ` · ${a.sessions.length} ses.${working ? `, ${working} activa${working > 1 ? 's' : ''}` : ''}` : ''}</Text>
            </Text>
            <Box flexShrink={0}>{healthChip(a)}</Box>
          </Box>
          {a.health === 'logged-out' ? (
            <Box flexDirection="column">
              <Text color={C.bad}>Inicia sesión otra vez en una terminal:</Text>
              <Text color={C.text}>{a.loginCommand ?? 'claude auth login'}</Text>
            </Box>
          ) : (
            <Box flexDirection="column">
              {meterRow('5h', a.fiveHour, inner)}
              {forecastRow(a.fiveHourForecast)}
              {meterRow('sem', a.weekly, inner)}
              {forecastRow(a.weeklyForecast)}
              {days !== null && days < 7 ? (
                <Text color={days < 2 ? C.bad : C.warn}>login caduca en {fmtSpan(Date.parse(a.loginExpiresAt!) - t)}</Text>
              ) : null}
            </Box>
          )}
          {a.health === 'ready' ? (
            <Box>
              <Button
                key={`open-${a.name}`}
                plain
                {...(index < 9 ? { hotkey: String(index + 1) } : {})}
                label={`+ abrir sesión en ${a.name} aquí`}
                onPress={() => void openSessionOn($, a.name).catch(err => noteError(err))}
              />
            </Box>
          ) : null}
          {a.sessions.length > 0 ? (
            <Box flexDirection="column" marginTop={0}>
              <Text color={C.faint}>{'─'.repeat(Math.max(1, inner))}</Text>
              {a.sessions.slice(0, 6).map(s => sessionRow(s, inner))}
              {a.sessions.length > 6 ? <Text color={C.dim}>+{a.sessions.length - 6} más</Text> : null}
            </Box>
          ) : null}
        </Box>
      )
    }

    const total = view.accounts.reduce((n, a) => n + a.sessions.length, 0)
    const busy = view.accounts.reduce((n, a) => n + a.sessions.filter(s => s.state === 'working').length, 0)
    return (
      <Box flexDirection="column" width={W}>
        {header}
        <Text color={C.dim}>
          {view.accounts.length} cuenta{view.accounts.length === 1 ? '' : 's'} · {total} sesi{total === 1 ? 'ón' : 'ones'} · {busy} trabajando
        </Text>
        {view.error ? (
          <Text color={C.bad} wrap="wrap">
            {view.error}
          </Text>
        ) : null}
        {view.accounts.length === 0 ? <Text color={C.dim}>Sin cuentas. Pulsa actualizar o ejecuta /fleet refresh.</Text> : null}
        {view.pipeline ? pipelineBox(view.pipeline) : null}
        {view.accounts.map(card)}
        {(view.providers ?? []).map(providerBox)}
      </Box>
    )
  })
}
