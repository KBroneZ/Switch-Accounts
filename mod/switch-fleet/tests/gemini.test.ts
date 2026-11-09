import type { EngineInterface } from 'claude-code'
import { expect, test } from 'claude-code/testing'

import { failureNote, GEMINI_EVERY_MS, maybeAskGemini, readGemini } from '../hooks/gemini'
import { parseConfig, S } from '../hooks/shared'
import type { Paths } from '../hooks/shared'

const NOW = Date.parse('2030-01-10T12:00:00Z')
const DIR = 'C:/Users/me/.claude-switch'
const AGY = 'C:/Users/me/AppData/Local/agy/bin/agy.exe'
const ANSWER = JSON.stringify({
  status: 'SUCCESS',
  command: { name: 'usage', data: { groups: [{ name: 'Gemini Models', buckets: [{ window: 'weekly', remaining_fraction: 0.8, reset_time: '2030-01-15T00:00:00Z' }] }] } },
})

type Files = Map<string, { text: string; mtime: number }>

function usePaths(): Paths {
  const paths = {
    dir: DIR,
    gemini: `${DIR}/gemini-usage.json`,
    geminiLock: `${DIR}/gemini.lock`,
    geminiError: `${DIR}/gemini-error.txt`,
    agyLog: `${DIR}/agy-usage.log`,
    agy: AGY,
  } as Paths
  S.cfg = parseConfig({})
  S.paths = paths
  return paths
}

/** The few engine calls gemini.ts makes, over an in-memory file system whose writes are stamped `clock.now`. */
function fakeEngine(files: Files, runs: string[][], clock: { now: number }, stdout = ANSWER, exitCode = 0): EngineInterface {
  const missing = (path: string) => Promise.reject(new Error(`ENOENT ${path}`))
  return {
    fs: {
      stat: (path: string) => {
        const f = files.get(path)
        return f ? Promise.resolve({ kind: 'file', size: f.text.length, mtimeMs: f.mtime }) : missing(path)
      },
      read: (path: string) => {
        const f = files.get(path)
        return f ? Promise.resolve(f.text) : missing(path)
      },
      exists: (path: string) => Promise.resolve(path === AGY || files.has(path)),
      write: (path: string, data: string) => {
        files.set(path, { text: data, mtime: clock.now })
        return Promise.resolve()
      },
    },
    process: {
      run: (argv: string[]) => {
        runs.push(argv)
        return Promise.resolve({ exitCode, stdout, stderr: exitCode ? 'boom' : '' })
      },
    },
  } as unknown as EngineInterface
}

test('asks Antigravity once, keeps the answer and draws the card from it', async () => {
  const paths = usePaths()
  const files: Files = new Map()
  const runs: string[][] = []
  const clock = { now: NOW }
  const $ = fakeEngine(files, runs, clock)
  expect(await readGemini($, NOW)).toEqual([])
  await maybeAskGemini($, NOW)
  expect(runs).toEqual([[AGY, '-p', '/usage', '--output-format', 'json', '--print-timeout', '60s', '--log-file', paths.agyLog]])
  expect(files.get(paths.gemini)?.text).toBe(ANSWER)
  const [card] = await readGemini($, NOW + 5_000)
  expect(card?.windows.map(w => [w.label, w.pct])).toEqual([['Gemini 7d', 20]])
  expect(card?.readNote).toBe('asked Antigravity')
  // Asked again only once the answer is GEMINI_EVERY_MS old.
  await maybeAskGemini($, NOW + GEMINI_EVERY_MS - 1)
  expect(runs).toHaveLength(1)
  await maybeAskGemini($, NOW + GEMINI_EVERY_MS + 1)
  expect(runs).toHaveLength(2)
})

test('another session holding the lock means no run', async () => {
  const paths = usePaths()
  const at = NOW + 3 * GEMINI_EVERY_MS
  const files: Files = new Map([[paths.geminiLock, { text: String(at - 10_000), mtime: at - 10_000 }]])
  const runs: string[][] = []
  await maybeAskGemini(fakeEngine(files, runs, { now: at }), at)
  expect(runs).toHaveLength(0)
})

test('a failed run keeps the last answer, says why to every session, and waits the interval', async () => {
  const paths = usePaths()
  const old = NOW - 9 * GEMINI_EVERY_MS
  const files: Files = new Map([[paths.gemini, { text: ANSWER, mtime: old }]])
  const runs: string[][] = []
  const later = NOW + 20 * GEMINI_EVERY_MS
  const clock = { now: later }
  const $ = fakeEngine(files, runs, clock, 'You are not logged into Antigravity.', 1)
  await maybeAskGemini($, later)
  expect(runs).toHaveLength(1)
  expect(files.get(paths.gemini)?.mtime).toBe(old)
  const [card] = await readGemini($, later)
  expect(card?.readAt).toBe(old)
  expect(card?.readNote).toBe('agy /usage failed (1): boom')
  // The lock has expired, but the failure is recent: no other run before the interval.
  await maybeAskGemini($, later + 5 * 60_000)
  expect(runs).toHaveLength(1)
  // A later success clears the note.
  clock.now = later + 2 * GEMINI_EVERY_MS
  const $ok = fakeEngine(files, runs, clock)
  await maybeAskGemini($ok, clock.now)
  expect(runs).toHaveLength(2)
  expect((await readGemini($ok, clock.now))[0]?.readNote).toBe('asked Antigravity')
})

test('a failure note is one plain line without escapes or tokens', () => {
  expect(failureNote(2, '\x1b[31merror\x1b[0m\r\nAuthorization: Bearer abc.def')).toBe('agy /usage failed (2): error Authorization: Bearer ***')
  expect(failureNote(null, '')).toBe('agy /usage failed (?): no answer')
})
