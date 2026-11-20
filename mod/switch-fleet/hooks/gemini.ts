// Gemini in the Fleet pane: Antigravity's CLI answers `/usage` in print mode without a model turn.
// One session at a time asks it (a lock file, like -List) every GEMINI_EVERY_MS and keeps the answer
// in ~/.claude-switch/gemini-usage.json; every session draws the card from that file. A failed run
// writes why to gemini-error.txt, so every session shows it and none asks again before the interval.
// The CLI's log goes to one file that each run overwrites: the runs leave nothing in Antigravity's folders.
//
// Several Google accounts (~/.claude-switch/gemini-accounts.json, aisw profiles): one usage file and one
// error file per account, and one card per account. agy has one live sign-in at a time, so a read means
// "switch to the account, ask, put the default back": gemini-usage.ps1 does that under gemini.lock and
// this module only runs it, for at most ONE account per check. /usage can spend quota, so an account is
// read when it has never been read, when a window of its last reading has reset (the numbers are then
// unknown), or when its reading is GEMINI_IDLE_MS old. An account used through ask-gemini.ps1 is read
// again by that script right after the call, so a busy account is always fresh and an idle one is rare.
import type { EngineInterface } from 'claude-code'

import type { ProviderView } from '../types'
import { maskSecrets, shorten } from './core'
import { parseAgyUsage, providerView } from './providers'
import { S } from './shared'
import type { Paths } from './shared'

/** How old the kept answer (or the last failure) may get before a session asks Antigravity again. */
export const GEMINI_EVERY_MS = 10 * 60_000
const AGY_TIMEOUT_MS = 90_000
/** A lock older than this was left by a session that stopped mid-run. */
const LOCK_MS = AGY_TIMEOUT_MS + 30_000

const gemini = { isRunning: false, triedAt: 0 }

type Kept = { text: string; mtime: number }

async function readKept($: EngineInterface, path: string): Promise<Kept | null> {
  const stat = await $.fs.stat(path).catch(() => null)
  if (!stat || stat.kind !== 'file') return null
  const text = await $.fs.read(path).then(String, () => null)
  return text === null ? null : { text, mtime: stat.mtimeMs }
}

/** A failure as one plain line for the card: no control characters, no token-looking values. */
export function failureNote(exitCode: number | null, output: string): string {
  const clean = maskSecrets(output.replace(/\x1b\[[0-9;]*[A-Za-z]/g, '').replace(/[\x00-\x1f\x7f]+/g, ' ').trim())
  return shorten(`agy /usage failed (${exitCode ?? '?'}): ${clean || 'no answer'}`, 120)
}

/** An idle account's reading is read again when it is this old. */
export const GEMINI_IDLE_MS = 3 * 3_600_000
/** After a failed read, the account waits this long. */
export const GEMINI_RETRY_MS = 30 * 60_000
/** Another Gemini run holds the account lock: ask again soon, without a failure note. */
const BUSY_RETRY_MS = 60_000
const ACCOUNT_NAME = /^[A-Za-z0-9][A-Za-z0-9._-]{0,29}$/

export type GeminiAccount = { name: string; profile: string; label: string }

/** The accounts of gemini-accounts.json, or the reason it is not a usable list. */
export function parseGeminiAccounts(text: string): { accounts: GeminiAccount[] } | { error: string } {
  let raw: unknown
  try {
    raw = JSON.parse(text)
  } catch {
    return { error: 'gemini-accounts.json is not valid JSON' }
  }
  const list = typeof raw === 'object' && raw !== null ? (raw as { accounts?: unknown }).accounts : null
  if (!Array.isArray(list) || list.length === 0) return { error: 'gemini-accounts.json has no accounts' }
  const accounts: GeminiAccount[] = []
  for (const item of list) {
    const o = (typeof item === 'object' && item !== null ? item : {}) as Record<string, unknown>
    const name = typeof o.name === 'string' ? o.name : ''
    const profile = typeof o.profile === 'string' ? o.profile : ''
    if (!ACCOUNT_NAME.test(name) || name.toLowerCase() === 'auto') return { error: `gemini-accounts.json: bad account name ${shorten(name, 20)}` }
    if (!ACCOUNT_NAME.test(profile)) return { error: `gemini-accounts.json: ${name} needs an aisw profile` }
    if (accounts.some(a => a.name.toLowerCase() === name.toLowerCase())) return { error: `gemini-accounts.json: ${name} is listed twice` }
    const label = typeof o.label === 'string' ? o.label.replace(/[\x00-\x1f\x7f]+/g, ' ').trim().slice(0, 40) : ''
    accounts.push({ name, profile, label })
  }
  return { accounts }
}

const usagePath = (paths: Paths, name: string) => `${paths.dir}/gemini-usage-${name}.json`
const errorPath = (paths: Paths, name: string) => `${paths.dir}/gemini-error-${name}.txt`

/** One account's card: its windows, or "no data" with the reason when it was never read. */
function accountView(account: GeminiAccount, kept: Kept | null, failed: Kept | null, now: number): ProviderView {
  const who = { id: `gemini-${account.name}`, name: `Gemini ${account.name}${account.label ? ` (${account.label})` : ''}`, source: 'Antigravity' }
  const note = failed && failed.text.trim() && (!kept || failed.mtime >= kept.mtime) ? failed.text.trim() : null
  const view = kept ? parseAgyUsage(kept.text, now, kept.mtime) : null
  if (!view) return { ...providerView({ ...who, readNote: note ?? 'not read yet' }, null, [], kept?.mtime ?? null, false, now), isStale: true }
  return { ...view, ...who, readNote: note ?? view.readNote }
}

/** One card per declared account; an account never read shows as "no data", it is not hidden. */
export async function readGeminiAccounts($: EngineInterface, now: number): Promise<ProviderView[]> {
  if (!S.paths) return []
  const paths = S.paths
  const text = await $.fs.read(paths.geminiAccounts).then(String, () => null)
  if (text === null) return []
  const parsed = parseGeminiAccounts(text)
  if ('error' in parsed) {
    return [{ ...providerView({ id: 'gemini', name: 'Gemini', source: 'Antigravity', readNote: parsed.error }, null, [], null, false, now), isStale: true }]
  }
  return Promise.all(parsed.accounts.map(async a => accountView(a, await readKept($, usagePath(paths, a.name)), await readKept($, errorPath(paths, a.name)), now)))
}

/** Whether a reading has a window that reset since it was read: its numbers are unknown now. */
function hasResetWindow(kept: Kept, now: number): boolean {
  const view = parseAgyUsage(kept.text, now, kept.mtime)
  return view !== null && view.windows.some(w => w.pct === null)
}

/**
 * The one account worth reading now, or null: never read, a window reset since the last read, or an
 * idle reading GEMINI_IDLE_MS old. An account whose last read failed waits GEMINI_RETRY_MS. The oldest goes first.
 */
export function dueAccount(accounts: GeminiAccount[], kept: Map<string, Kept | null>, failed: Map<string, Kept | null>, now: number): string | null {
  const due = accounts
    .map(a => {
      const k = kept.get(a.name) ?? null
      const f = failed.get(a.name) ?? null
      if (f && f.text.trim() && now - f.mtime < GEMINI_RETRY_MS) return null
      const isDue = k === null || now - k.mtime >= GEMINI_IDLE_MS || hasResetWindow(k, now)
      return isDue ? { name: a.name, since: k?.mtime ?? 0 } : null
    })
    .filter((d): d is { name: string; since: number } => d !== null)
    .sort((a, b) => a.since - b.since)
  return due[0]?.name ?? null
}

/** Reads the account that is due, through gemini-usage.ps1 (it switches, asks and puts the default back under the lock). */
async function refreshAccounts($: EngineInterface, paths: Paths, accounts: GeminiAccount[], now: number): Promise<void> {
  const kept = new Map<string, Kept | null>()
  const failed = new Map<string, Kept | null>()
  for (const a of accounts) {
    kept.set(a.name, await readKept($, usagePath(paths, a.name)))
    failed.set(a.name, await readKept($, errorPath(paths, a.name)))
  }
  const name = dueAccount(accounts, kept, failed, now)
  if (!name) return
  if (!(await $.fs.exists(paths.geminiScript))) {
    await $.fs.write(errorPath(paths, name), shorten(`cannot find ${paths.geminiScript}; install the fleet-director skill or set geminiScriptPath`, 120))
    return
  }
  let note: string
  try {
    const r = await $.process.run(['pwsh', '-NoProfile', '-NonInteractive', '-File', paths.geminiScript, '-Account', name, '-AgyPath', paths.agy], {
      timeoutMs: AGY_TIMEOUT_MS + 60_000,
    })
    if (r.exitCode === 0) return
    // Busy: an ask-gemini call holds the lock and reads its own account afterwards. Ask again soon, no failure note.
    if (r.exitCode === 4) {
      gemini.triedAt = now - GEMINI_EVERY_MS + BUSY_RETRY_MS
      return
    }
    // Exit 3: the script kept the failure in the account's error file.
    if (r.exitCode === 3 && (await readKept($, errorPath(paths, name)))?.text.trim()) return
    note = failureNote(r.exitCode, r.stderr || r.stdout)
  } catch (err) {
    note = failureNote(null, `could not run gemini-usage.ps1: ${String(err)}`)
  }
  await $.fs.write(errorPath(paths, name), note)
}

/** The card from the kept answer, with the last failure when it came after it; nothing before a first answer. */
export async function readGemini($: EngineInterface, now: number): Promise<ProviderView[]> {
  if (!S.paths) return []
  const accounts = await readGeminiAccounts($, now)
  if (accounts.length > 0) return accounts
  const [kept, failed] = await Promise.all([readKept($, S.paths.gemini), readKept($, S.paths.geminiError)])
  const view = kept ? parseAgyUsage(kept.text, now, kept.mtime) : null
  if (!view) return []
  const note = failed && failed.text.trim() && failed.mtime >= kept!.mtime ? failed.text.trim() : null
  return [note ? { ...view, readNote: note } : view]
}

/** Asks Antigravity for `/usage` when the kept answer and the last failure are old and no other session is asking. */
export async function maybeAskGemini($: EngineInterface, now: number): Promise<void> {
  if (!S.paths || gemini.isRunning || now - gemini.triedAt < GEMINI_EVERY_MS) return
  const paths = S.paths
  // Taken before the first await: a poll that lands while this one checks never starts a second run.
  gemini.isRunning = true
  try {
    // Several Google accounts: gemini-usage.ps1 takes the lock itself (an open file handle), so no timestamp lock here.
    const declared = await $.fs.read(paths.geminiAccounts).then(String, () => null)
    const parsed = declared === null ? null : parseGeminiAccounts(declared)
    if (parsed) {
      gemini.triedAt = now
      if ('accounts' in parsed) await refreshAccounts($, paths, parsed.accounts, now)
      return
    }
    const [kept, failed] = await Promise.all([readKept($, paths.gemini), readKept($, paths.geminiError)])
    if (kept && now - kept.mtime < GEMINI_EVERY_MS) return
    if (failed && failed.text.trim() && now - failed.mtime < GEMINI_EVERY_MS) return
    const lock = await $.fs.read(paths.geminiLock).then(s => Number(String(s)), () => 0)
    if (lock && now - lock < LOCK_MS) return
    gemini.triedAt = now
    if (!(await $.fs.exists(paths.agy))) return
    await $.fs.write(paths.geminiLock, String(now))
    let note: string
    try {
      const r = await $.process.run([paths.agy, '-p', '/usage', '--output-format', 'json', '--print-timeout', '60s', '--log-file', paths.agyLog], {
        timeoutMs: AGY_TIMEOUT_MS,
      })
      if (r.exitCode === 0 && parseAgyUsage(r.stdout, now, now)) {
        await $.fs.write(paths.gemini, r.stdout.trim())
        await $.fs.write(paths.geminiError, '')
        return
      }
      note = failureNote(r.exitCode, r.stderr || r.stdout)
    } catch (err) {
      note = failureNote(null, `could not run agy: ${String(err)}`)
    }
    await $.fs.write(paths.geminiError, note)
  } finally {
    gemini.isRunning = false
  }
}
