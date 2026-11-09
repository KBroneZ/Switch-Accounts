import { describe, expect, test } from 'claude-code/testing'

import type { Beat, FleetView } from '../types'
import { buildFleet, quotaAccountOf, fmtSpan, healthChanges, maskSecrets, parseBeat, parsePipeline, parseSnapshot, statusText, toolDetail } from '../hooks/core'

const NOW = Date.parse('2030-01-01T12:00:00Z')

const snapshotText = JSON.stringify({
  schema: 1,
  updatedAt: '2030-01-01T11:58:00Z',
  accounts: [
    {
      name: 'A',
      configDir: 'C:\\Users\\me\\.claude',
      auth: { status: 'LoggedIn', plan: 'max', tier: 'max_5x', expiresAt: '2030-01-20T00:00:00Z', loginCommand: 'claude auth login' },
      usage: { status: 'Known', fiveHourPercent: 44, resetsAt: '2030-01-01T15:00:00Z', weeklyPercent: 6, weeklyResetsAt: '2030-01-05T09:00:00Z' },
      caps: { fiveHour: 95, weekly: 98 },
      decision: 'Allow',
      reason: null,
      onboarding: 'Ready',
    },
    {
      name: 'B',
      configDir: 'C:\\Users\\me\\.claude-account2',
      auth: { status: 'LoggedOut', plan: null, tier: null, expiresAt: null, loginCommand: "$env:CLAUDE_CONFIG_DIR = 'x'; claude auth login" },
      usage: { status: 'Unknown', fiveHourPercent: null, resetsAt: null, weeklyPercent: null, weeklyResetsAt: null },
      caps: { fiveHour: 80, weekly: null },
      decision: 'Block',
      reason: 'Usage unknown',
      onboarding: 'Ready',
    },
  ],
})

const beat = (over: Partial<Beat>): Beat => ({
  schema: 1,
  sessionId: 's1',
  configDir: 'c:/users/me/.claude/',
  cwd: 'C:\\src\\app',
  repo: 'app',
  model: 'claude-opus-5-5',
  state: 'working',
  tool: 'Bash',
  detail: 'npm test',
  prompt: 'fix the login',
  ctxPct: 40,
  costUsd: 1.5,
  limits: null,
  limitsAt: null,
  worker: null,
  rollover: 'none',
  rolloverAt: null,
  waitingUntil: null,
  lastReply: null,
  finished: false,
  turns: 3,
  startedAt: NOW - 600_000,
  stateSince: NOW - 5_000,
  updatedAt: NOW - 2_000,
  ...over,
})

describe('core', () => {
  test('parses the snapshot and drops what is not schema 1', () => {
    expect(parseSnapshot(snapshotText)?.accounts.map(a => a.name)).toEqual(['A', 'B'])
    expect(parseSnapshot('{"schema":2,"accounts":[]}')).toBeNull()
    expect(parseSnapshot('not json')).toBeNull()
  })

  test('parses a heartbeat and refuses one without an id or time', () => {
    expect(parseBeat(JSON.stringify(beat({})))?.sessionId).toBe('s1')
    expect(parseBeat(JSON.stringify({ ...beat({}), sessionId: '' }))).toBeNull()
    expect(parseBeat(JSON.stringify({ ...beat({}), updatedAt: 'x' }))).toBeNull()
  })

  test('groups sessions under their account across path spellings, working first', () => {
    const fleet = buildFleet(
      parseSnapshot(snapshotText),
      [beat({ sessionId: 'idle', state: 'idle', updatedAt: NOW - 1_000 }), beat({ sessionId: 'busy' })],
      NOW,
      'busy',
    )
    const a = fleet.accounts[0]!
    expect(a.health).toBe('ready')
    expect(a.sessions.map(s => s.id)).toEqual(['busy', 'idle'])
    expect(a.sessions[0]!.isSelf).toBe(true)
    expect(fleet.accounts[1]!.health).toBe('logged-out')
    expect(fleet.accounts[1]!.loginCommand).toContain('claude auth login')
  })

  test('prefers a session reading of the limits newer than the snapshot', () => {
    const fleet = buildFleet(
      parseSnapshot(snapshotText),
      [beat({ limits: { fiveHour: 96, fiveHourResetsAt: '2030-01-01T15:00:00Z', weekly: 7, weeklyResetsAt: null }, limitsAt: NOW - 5_000 })],
      NOW,
      null,
    )
    const a = fleet.accounts[0]!
    expect(a.fiveHour.pct).toBe(96)
    expect(a.fiveHour.isLive).toBe(true)
    expect(a.health).toBe('at-cap')
  })

  test('ignores limits read before the snapshot, however recent the heartbeat', () => {
    const old = { fiveHour: 40, fiveHourResetsAt: '2030-01-01T15:00:00Z', weekly: 5, weeklyResetsAt: null }
    const fleet = buildFleet(
      parseSnapshot(snapshotText),
      [
        beat({ limits: old, limitsAt: NOW - 3 * 3_600_000, updatedAt: NOW - 1_000 }),
        beat({ sessionId: 'b', configDir: 'C:/Users/me/.claude-account2', limits: old, limitsAt: NOW - 3 * 3_600_000 }),
      ],
      NOW,
      null,
    )
    expect(fleet.accounts[0]!.fiveHour.pct).toBe(44)
    expect(fleet.accounts[0]!.fiveHour.isLive).toBe(false)
    expect(fleet.accounts[1]!.health).toBe('logged-out')
  })

  test('a window whose reset passed is unknown, not at its old use', () => {
    const text = snapshotText.replace('"resetsAt":"2030-01-01T15:00:00Z"', '"resetsAt":"2030-01-01T11:00:00Z"')
    const a = buildFleet(parseSnapshot(text), [], NOW, null).accounts[0]!
    expect(a.fiveHour.pct).toBeNull()
    expect(a.health).toBe('unknown')
  })

  test('hides gone and ended sessions, and marks quiet ones', () => {
    const fleet = buildFleet(
      parseSnapshot(snapshotText),
      [
        beat({ sessionId: 'gone', updatedAt: NOW - 30 * 60_000 }),
        beat({ sessionId: 'ended', state: 'ended', updatedAt: NOW - 5 * 60_000 }),
        beat({ sessionId: 'quiet', state: 'idle', updatedAt: NOW - 5 * 60_000 }),
      ],
      NOW,
      null,
    )
    expect(fleet.accounts[0]!.sessions.map(s => [s.id, s.liveness])).toEqual([['quiet', 'quiet']])
  })

  test('lists a config dir that accounts.json does not know', () => {
    const fleet = buildFleet(parseSnapshot(snapshotText), [beat({ configDir: 'D:/other/.claude-x' })], NOW, null)
    expect(fleet.accounts.map(a => a.name)).toEqual(['A', 'B', '.claude-x'])
  })

  test('masks keys and tokens in tool details and prompts', () => {
    expect(toolDetail('Bash', { command: 'curl -H "Authorization: Bearer abc.def" x' })).not.toContain('abc.def')
    const fakeKey = ['sk', 'abcdefghijklmnop'].join('-')
    expect(maskSecrets(`export API_KEY=${fakeKey}`)).not.toContain(fakeKey)
    expect(toolDetail('Read', { file_path: 'C:\\src\\app\\main.ts' })).toBe('main.ts')
    const cmd = `x --token mytok123 -d '{"password":"hunter2"}' -H "Authorization: Basic dXNlcjpwdw" https://me:pw99@host`
    for (const leak of ['mytok123', 'hunter2', 'dXNlcjpwdw', 'pw99']) expect(maskSecrets(cmd)).not.toContain(leak)
  })

  test('formats spans, the status line and health changes', () => {
    expect(fmtSpan(40_000)).toBe('40s')
    expect(fmtSpan(3 * 3_600_000 + 12 * 60_000)).toBe('3h12m')
    const fleet = buildFleet(parseSnapshot(snapshotText), [], NOW, null)
    expect(statusText(fleet)).toBe('fleet A 44% · B login!')
    const before: FleetView = { ...fleet, hub: null, pipeline: null, isRefreshing: false, error: null, accounts: fleet.accounts.map(a => ({ ...a, health: 'ready' as const })) }
    expect(healthChanges(before, fleet)).toEqual(['Cuenta B: login caducado'])
    expect(healthChanges(null, fleet)).toEqual([])
  })
})

const PANE = {
  plugin: 'switch-fleet',
  component: 'Pane',
  requestId: 'switch-fleet',
  props: { title: 'Fleet', isFocused: false, bodyColumns: 60, placement: 'dock', scroll: { offset: 0, bodyRows: 30 }, view: {} },
} as const

test('the pane draws each account and its sessions, on every surface', async ($, on) => {
  const built = buildFleet(parseSnapshot(snapshotText), [beat({})], NOW, null)
  const view: FleetView = { ...built, hub: null, pipeline: null, isRefreshing: false, error: null }
  on('clock.now', () => ({ value: NOW }))
  on('state.get', () => ({ value: { value: { shape: 'fleet-5', value: view }, version: 1 } }))

  for (const surface of ['terminal', 'desktop', 'vscode', 'mobile'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })
    expect(await ui.find({ type: 'Text', text: /FLEET/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /login caducado/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /Bash: npm test/ })).toBeDefined()
    await ui.unmount()
  }
})

test('the pane says it is loading before the first build', async ($, on) => {
  on('clock.now', () => ({ value: NOW }))
  on('state.get', () => ({ value: { version: 0 } }))
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect((await ui.find({ type: 'Text', text: /Cargando/ }))?.text).toBe('Cargando…')
  await ui.unmount()
})

describe('pipeline', () => {
  const doc = {
    schema: 1,
    repo: 'app',
    state: 'waiting',
    cycle: 2,
    maxCycles: 10,
    updatedAt: '2030-01-01T11:50:00Z',
    waitUntil: '2030-01-01T15:00:00Z',
    message: 'Waiting for the 5-hour window to reset.',
    roles: [{ role: 'implementer', account: 'A', task: '002', outcome: 'CapWait', status: null, reason: null }],
  }

  test('reads a recent status and drops an old or foreign one', () => {
    expect(parsePipeline(JSON.stringify(doc), NOW)?.roles[0]?.task).toBe('002')
    expect(parsePipeline(JSON.stringify({ ...doc, updatedAt: '2029-12-31T00:00:00Z' }), NOW)).toBeNull()
    expect(parsePipeline(JSON.stringify({ ...doc, state: 'weird' }), NOW)).toBeNull()
    expect(parsePipeline('nope', NOW)).toBeNull()
  })

  test('the pane draws the pipeline box and an open button for a ready account', async ($, on) => {
    const built = buildFleet(parseSnapshot(snapshotText), [], NOW, null)
    const view: FleetView = { ...built, hub: null, pipeline: parsePipeline(JSON.stringify(doc), NOW), isRefreshing: false, error: null }
    on('clock.now', () => ({ value: NOW }))
    on('state.get', () => ({ value: { value: { shape: 'fleet-5', value: view }, version: 1 } }))
    for (const surface of ['terminal', 'desktop'] as const) {
      const ui = await $.ui.mount({ ...PANE, surface })
      expect(await ui.find({ type: 'Text', text: /esperando reinicio/ })).toBeDefined()
      expect(await ui.find({ key: 'open-A' })).toBeDefined()
      expect(await ui.find({ key: 'open-B' })).toBeUndefined()
      await ui.unmount()
    }
  })
})

describe('quota account', () => {
  const snap = parseSnapshot(snapshotText)!
  const weekB = '2030-01-08T01:00:00.000Z'
  const withB = parseSnapshot(JSON.stringify({ ...JSON.parse(snapshotText), accounts: JSON.parse(snapshotText).accounts.map((a: { name: string; usage: object }) => (a.name === 'B' ? { ...a, usage: { ...a.usage, weeklyResetsAt: '2030-01-08T01:00:00Z' } } : a)) }))!
  const limits = (weeklyResetsAt: string) => ({ fiveHour: 22, fiveHourResetsAt: '2030-01-01T14:00:00Z', weekly: 3, weeklyResetsAt })

  test('names the account by its weekly reset, or nothing when unknown or not unique', () => {
    expect(quotaAccountOf(beat({ limits: limits(weekB) }), withB.accounts)).toBe('B')
    expect(quotaAccountOf(beat({ limits: limits('2030-01-05T09:00:00.000Z') }), withB.accounts)).toBe('A')
    expect(quotaAccountOf(beat({ limits: null }), withB.accounts)).toBeNull()
    expect(quotaAccountOf(beat({ limits: limits('2030-02-01T00:00:00Z') }), withB.accounts)).toBeNull()
    expect(snap.accounts.length).toBe(2)
  })

  test('a session of A that spends B gives its live use to B and is marked, A keeps its own', () => {
    const b = beat({ limits: limits(weekB), limitsAt: NOW - 1_000 })
    const fleet = buildFleet(withB, [b], NOW, null)
    const a = fleet.accounts.find(x => x.name === 'A')!
    const bAcc = fleet.accounts.find(x => x.name === 'B')!
    expect(a.fiveHour.pct).toBe(44)
    expect(a.fiveHour.isLive).toBe(false)
    expect(bAcc.fiveHour.pct).toBe(22)
    expect(bAcc.fiveHour.isLive).toBe(true)
    expect(a.sessions[0]?.quotaAccount).toBe('B')
  })
})
