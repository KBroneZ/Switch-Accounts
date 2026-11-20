import type { EngineInterface } from 'claude-code'
import { expect, test } from 'claude-code/testing'

import { dueAccount, failureNote, GEMINI_EVERY_MS, GEMINI_IDLE_MS, GEMINI_RETRY_MS, maybeAskGemini, parseGeminiAccounts, readGemini } from '../hooks/gemini'
import { providerLines, providerStatus } from '../hooks/providers'
import { parseConfig, S } from '../hooks/shared'
import type { Paths } from '../hooks/shared'

const NOW = Date.parse('2030-01-10T12:00:00Z')
const DIR = 'C:/Users/me/.claude-switch'
const AGY = 'C:/Users/me/AppData/Local/agy/bin/agy.exe'
const SCRIPT = 'C:/Users/me/.claude/skills/fleet-director/scripts/gemini-usage.ps1'
const ANSWER = JSON.stringify({
  status: 'SUCCESS',
  command: { name: 'usage', data: { groups: [{ name: 'Gemini Models', buckets: [{ window: 'weekly', remaining_fraction: 0.8, reset_time: '2030-01-15T00:00:00Z' }] }] } },
})

type Files = Map<string, { text: string; mtime: number }>

function usePaths(): Paths {
  const paths = {
    dir: DIR,
    gemini: `${DIR}/gemini-usage.json`,
    geminiAccounts: `${DIR}/gemini-accounts.json`,
    geminiScript: SCRIPT,
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

// --- several Google accounts -----------------------------------------------------------------

// The module remembers when it last asked, across tests: each test that asks takes a later day.
let day = NOW + 40 * 24 * 3_600_000
const nextDay = () => (day += 24 * 3_600_000)
const LATE = ANSWER.replace('2030-01-15', '2031-01-15')
const ACCOUNTS = JSON.stringify({ accounts: [{ name: 'G1', profile: 'g1', label: 'main' }, { name: 'G2', profile: 'g2', label: 'second' }] })
const usageOf = (n: string) => `${DIR}/gemini-usage-${n}.json`
const errorOf = (n: string) => `${DIR}/gemini-error-${n}.txt`
const accountFiles = (extra: [string, { text: string; mtime: number }][] = []): Files =>
  new Map([[`${DIR}/gemini-accounts.json`, { text: ACCOUNTS, mtime: NOW }], [SCRIPT, { text: '', mtime: NOW }], ...extra])

test('the accounts file is validated: names, profiles, duplicates', () => {
  expect(parseGeminiAccounts(ACCOUNTS)).toEqual({
    accounts: [{ name: 'G1', profile: 'g1', label: 'main' }, { name: 'G2', profile: 'g2', label: 'second' }],
  })
  expect(parseGeminiAccounts('nope')).toEqual({ error: 'gemini-accounts.json is not valid JSON' })
  expect(parseGeminiAccounts('{"accounts":[]}')).toEqual({ error: 'gemini-accounts.json has no accounts' })
  expect(parseGeminiAccounts('{"accounts":[{"name":"auto","profile":"g1"}]}')).toHaveProperty('error')
  expect(parseGeminiAccounts('{"accounts":[{"name":"G1"}]}')).toEqual({ error: 'gemini-accounts.json: G1 needs an aisw profile' })
  expect(parseGeminiAccounts('{"accounts":[{"name":"G1","profile":"g1"},{"name":"g1","profile":"g2"}]}')).toEqual({ error: 'gemini-accounts.json: g1 is listed twice' })
})

test('one card per account; an account never read shows as no data, never as 0 %', async () => {
  usePaths()
  const files = accountFiles([[usageOf('G1'), { text: ANSWER, mtime: NOW - 60_000 }]])
  const cards = await readGemini(fakeEngine(files, [], { now: NOW }), NOW)
  expect(cards.map(c => [c.id, c.name, c.health])).toEqual([
    ['gemini-G1', 'Gemini G1 (main)', 'ready'],
    ['gemini-G2', 'Gemini G2 (second)', 'unknown'],
  ])
  expect(cards[0]?.windows.map(w => [w.label, w.pct])).toEqual([['Gemini 7d', 20]])
  expect(cards[1]?.windows).toEqual([])
  expect(cards[1]?.readNote).toBe('not read yet')
  expect(providerStatus(cards)).toEqual(['Gemini G1 20%', 'Gemini G2 ?'])
  const lines = providerLines(cards, NOW)
  expect(lines[0]).toContain('Gemini G1 (main) (via Antigravity): available · Gemini 7d 20%')
  expect(lines[1]).toContain('Gemini G2 (second) (via Antigravity): no data')
})

test('a file that is not a usable list shows as one failed card', async () => {
  usePaths()
  const files: Files = new Map([[`${DIR}/gemini-accounts.json`, { text: '{"accounts":[]}', mtime: NOW }]])
  const [card] = await readGemini(fakeEngine(files, [], { now: NOW }), NOW)
  expect(card?.readNote).toBe('gemini-accounts.json has no accounts')
  expect(card?.health).toBe('unknown')
})

test('reads one account per check, through gemini-usage.ps1 and not agy directly', async () => {
  const paths = usePaths()
  const files = accountFiles()
  const runs: string[][] = []
  const t = nextDay()
  await maybeAskGemini(fakeEngine(files, runs, { now: t }), t)
  expect(runs).toEqual([['pwsh', '-NoProfile', '-NonInteractive', '-File', SCRIPT, '-Account', 'G1', '-AgyPath', AGY]])
  // No timestamp lock: the script holds the real one.
  expect(files.has(paths.geminiLock)).toBe(false)
  // Checks come GEMINI_EVERY_MS apart, and the next takes the account still unread.
  await maybeAskGemini(fakeEngine(files, runs, { now: t }), t + 1)
  expect(runs).toHaveLength(1)
  files.set(usageOf('G1'), { text: LATE, mtime: t })
  await maybeAskGemini(fakeEngine(files, runs, { now: t }), t + GEMINI_EVERY_MS)
  expect(runs[1]?.slice(5, 7)).toEqual(['-Account', 'G2'])
})

test('an idle reading is read again only when it is old; a fresh one never spends a call', () => {
  const accounts = [{ name: 'G1', profile: 'g1', label: '' }, { name: 'G2', profile: 'g2', label: '' }]
  const read = (at: number) => ({ text: ANSWER, mtime: at })
  const none = new Map<string, null>()
  expect(dueAccount(accounts, new Map([['G1', read(NOW)], ['G2', read(NOW)]]), none, NOW + GEMINI_IDLE_MS - 1)).toBeNull()
  // The oldest reading first once both are idle.
  expect(dueAccount(accounts, new Map([['G1', read(NOW)], ['G2', read(NOW - 1000)]]), none, NOW + GEMINI_IDLE_MS)).toBe('G2')
})

test('a window that reset since the last reading is read again, but a recent failure waits', () => {
  const accounts = [{ name: 'G1', profile: 'g1', label: '' }]
  // ANSWER resets on 2030-01-15: after that the numbers are unknown.
  const afterReset = Date.parse('2030-01-16T00:00:00Z')
  const kept = new Map([['G1', { text: ANSWER, mtime: afterReset - 60_000 }]])
  expect(dueAccount(accounts, kept, new Map(), afterReset)).toBe('G1')
  const failed = new Map([['G1', { text: 'agy /usage failed (1): boom', mtime: afterReset - 60_000 }]])
  expect(dueAccount(accounts, kept, failed, afterReset)).toBeNull()
  expect(dueAccount(accounts, kept, failed, afterReset - 60_000 + GEMINI_RETRY_MS)).toBe('G1')
})

test('a busy lock (exit 4) is no failure: no note, and the check comes back within a minute', async () => {
  usePaths()
  const files = accountFiles()
  const runs: string[][] = []
  const t = nextDay()
  await maybeAskGemini(fakeEngine(files, runs, { now: t }, '', 4), t)
  expect(files.has(errorOf('G1'))).toBe(false)
  await maybeAskGemini(fakeEngine(files, runs, { now: t }, '', 4), t + 30_000)
  expect(runs).toHaveLength(1)
  await maybeAskGemini(fakeEngine(files, runs, { now: t }, '', 4), t + 61_000)
  expect(runs).toHaveLength(2)
})

test('an unavailable account (exit 6) says why on its own card, and the next try takes the other account', async () => {
  usePaths()
  const files = accountFiles()
  const runs: string[][] = []
  const t = nextDay()
  const $ = fakeEngine(files, runs, { now: t }, 'Google account G1 is unavailable: aisw was not found', 6)
  await maybeAskGemini($, t)
  expect(files.get(errorOf('G1'))?.text).toBe('agy /usage failed (6): boom')
  expect((await readGemini($, t))[0]?.readNote).toBe('agy /usage failed (6): boom')
  await maybeAskGemini(fakeEngine(files, runs, { now: t }), t + GEMINI_EVERY_MS)
  expect(runs[1]?.[6]).toBe('G2')
})

test('without the skill installed, the card says so and nothing runs', async () => {
  usePaths()
  const files = accountFiles()
  files.delete(SCRIPT)
  const runs: string[][] = []
  const t = nextDay()
  await maybeAskGemini(fakeEngine(files, runs, { now: t }), t)
  expect(runs).toHaveLength(0)
  expect(files.get(errorOf('G1'))?.text).toContain('install the fleet-director skill')
})
