// Gemini in the Fleet pane: Antigravity's CLI answers `/usage` in print mode without a model turn.
// One session at a time asks it (a lock file, like -List) every GEMINI_EVERY_MS and keeps the answer
// in ~/.claude-switch/gemini-usage.json; every session draws the card from that file. A failed run
// writes why to gemini-error.txt, so every session shows it and none asks again before the interval.
// The CLI's log goes to one file that each run overwrites: the runs leave nothing in Antigravity's folders.
import type { EngineInterface } from 'claude-code'

import type { ProviderView } from '../types'
import { maskSecrets, shorten } from './core'
import { parseAgyUsage } from './providers'
import { S } from './shared'

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

/** The card from the kept answer, with the last failure when it came after it; nothing before a first answer. */
export async function readGemini($: EngineInterface, now: number): Promise<ProviderView[]> {
  if (!S.paths) return []
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
