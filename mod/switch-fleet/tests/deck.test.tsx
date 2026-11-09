import { describe, expect, test } from 'claude-code/testing'
import type { TestBody } from 'claude-code/testing'

import type { Beat, DeckView, FleetView, HubView } from '../types'
import { buildFleet, parseSnapshot } from '../hooks/core'
import { buildWorkers, contextSvg, meterColor, meterSvg, PALETTE, phaseLabel, STARTING_MS, workerPhase } from '../hooks/deck-view'
import type { WorkerRecord } from '../hooks/hub-core'

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
      configDir: 'C:\\Users\\me\\.claude-account3',
      auth: { status: 'LoggedIn', plan: 'pro', tier: null, expiresAt: '2030-01-20T00:00:00Z', loginCommand: 'claude auth login' },
      usage: { status: 'Known', fiveHourPercent: 10, resetsAt: '2030-01-01T14:00:00Z', weeklyPercent: 3, weeklyResetsAt: '2030-01-05T09:00:00Z' },
      caps: { fiveHour: 80, weekly: null },
      decision: 'Allow',
      reason: null,
      onboarding: 'Ready',
    },
  ],
})

const beat = (over: Partial<Beat>): Beat => ({
  schema: 1,
  sessionId: 'w1-gen1',
  configDir: 'C:/Users/me/.claude-account3',
  cwd: 'C:/src/app',
  repo: 'app',
  model: null,
  state: 'working',
  tool: 'Edit',
  detail: 'src/app.ts',
  prompt: null,
  ctxPct: 25,
  costUsd: null,
  limits: null,
  limitsAt: null,
  worker: 'w1',
  rollover: 'none',
  rolloverAt: null,
  waitingUntil: null,
  lastReply: 'Tests verdes',
  finished: false,
  turns: 3,
  startedAt: NOW - 50_000,
  stateSince: NOW - 5_000,
  updatedAt: NOW - 2_000,
  ...over,
})

const record = (over: Partial<WorkerRecord>): WorkerRecord => ({
  schema: 1,
  name: 'w1',
  account: 'B',
  directory: 'C:/src/app',
  model: null,
  effort: null,
  generation: 1,
  state: 'active',
  openedAt: NOW - 60_000,
  claimedBy: null,
  mailFrom: 0,
  successorDue: null,
  createdAt: NOW,
  updatedAt: NOW,
  ...over,
})

describe('worker phases', () => {
  test('reads the phase from the record first, then the current generation heartbeat', () => {
    expect(workerPhase(record({ state: 'stopped' }), beat({}), 'A', NOW)).toBe('stopped')
    expect(workerPhase(record({ successorDue: 1 }), beat({}), 'A', NOW)).toBe('successor')
    expect(workerPhase(record({}), null, 'A', NOW)).toBe('starting')
    expect(workerPhase(record({ openedAt: NOW - STARTING_MS - 1 }), null, 'A', NOW)).toBe('gone')
    expect(workerPhase(record({}), beat({ finished: true }), 'A', NOW)).toBe('finished')
    expect(workerPhase(record({}), beat({ waitingUntil: '2030-01-01T14:00:00Z' }), 'A', NOW)).toBe('waiting')
    expect(workerPhase(record({}), beat({ rollover: 'requested' }), 'A', NOW)).toBe('handover')
    expect(workerPhase(record({}), beat({ state: 'ended' }), 'A', NOW)).toBe('gone')
    expect(workerPhase(record({}), beat({ state: 'idle' }), 'A', NOW)).toBe('idle')
    expect(workerPhase(record({}), beat({}), 'A', NOW)).toBe('working')
  })

  test('takes only the current generation, busiest first', () => {
    const old = beat({ sessionId: 'old', startedAt: NOW - 120_000, state: 'idle' })
    const workers = buildWorkers(
      [record({ name: 'w2', openedAt: NOW - 10_000, state: 'stopped' }), record({})],
      [old, beat({}), beat({ worker: 'w2', sessionId: 'x', startedAt: NOW - 200_000 })],
      'A',
      NOW,
    )
    expect(workers.map(w => [w.name, w.phase])).toEqual([
      ['w1', 'working'],
      ['w2', 'stopped'],
    ])
    expect(workers[0]?.tool).toBe('Edit')
    expect(workers[1]?.ctxPct).toBeNull()
  })

  test('words each phase', () => {
    const [w] = buildWorkers([record({})], [beat({ waitingUntil: '2030-01-01T14:00:00Z' })], 'A', NOW)
    expect(phaseLabel(w!, () => '14:00')).toBe('esperando reinicio · 14:00')
    expect(phaseLabel({ ...w!, phase: 'working' }, () => '')).toBe('trabajando · Edit: src/app.ts')
  })
})

describe('svg', () => {
  test('a meter draws the use, the projection and the cap tick', () => {
    const svg = meterSvg({ pct: 50, cap: 80, resetsAt: null, isLive: false }, 70, 200)
    expect(svg.startsWith('<svg')).toBe(true)
    expect(svg).toContain('width="100"')
    expect(svg).toContain('width="140"')
    expect(svg).toContain('x="160"')
    expect(svg).not.toContain('<script')
  })

  test('colours the use against the cap', () => {
    expect(meterColor(10, 80)).toBe(PALETTE.ok)
    expect(meterColor(75, 80)).toBe(PALETTE.warn)
    expect(meterColor(85, 80)).toBe(PALETTE.bad)
    expect(meterColor(99, null)).toBe(PALETTE.ok)
  })

  test('a context bar marks the hand-over threshold', () => {
    const svg = contextSvg(50, 40, 100)
    expect(svg).toContain('x="40"')
    expect(svg).toContain(PALETTE.warn)
  })
})

const PANE = {
  plugin: 'switch-fleet',
  component: 'Pane',
  requestId: 'switch-fleet',
  props: { title: 'Fleet', isFocused: false, bodyColumns: 80, placement: 'dock', scroll: { offset: 0, bodyRows: 40 }, view: {} },
} as const

const EMPTY: DeckView = { note: null, isNoteError: false, busy: null, confirmStop: null, isFormOpen: false }

function viewWith(hub: HubView): FleetView {
  const built = buildFleet(parseSnapshot(snapshotText), [beat({})], NOW, null)
  return { ...built, hub, pipeline: null, isRefreshing: false, error: null }
}

const hubView = (isHub: boolean): HubView => ({
  hubAccount: 'A',
  isHub,
  rolloverPercent: 40,
  cwd: 'C:/src/app',
  workers: buildWorkers([record({})], [beat({})], 'A', NOW),
})

function seed(on: Parameters<TestBody>[1], view: FleetView, deck: DeckView) {
  on('clock.now', () => ({ value: NOW }))
  on('state.get', (_$, e) =>
    e.key === 'deck' ? { value: { value: { shape: 'deck-1', value: deck }, version: 1 } } : { value: { value: { shape: 'fleet-4', value: view }, version: 1 } },
  )
}

test('the desktop Deck draws gauges, the hub lanes and their controls', async ($, on) => {
  seed(on, viewWith(hubView(true)), { ...EMPTY, isFormOpen: true, note: 'Mensaje 1 en cola para w1; le llega en cuanto esté libre.' })
  for (const surface of ['desktop', 'vscode'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })
    expect(await ui.find({ type: 'Text', text: /FLEET DECK/ })).toBeDefined()
    expect(await ui.find({ type: 'Svg' })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /trabajando · Edit/ })).toBeDefined()
    expect(await ui.find({ key: 'msg-w1' })).toBeDefined()
    expect(await ui.find({ key: 'stop-w1' })).toBeDefined()
    expect(await ui.find({ key: 'nw-brief' })).toBeDefined()
    expect(await ui.find({ key: 'nw-account' })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /Mensaje 1 en cola/ })).toBeDefined()
    expect(await ui.find({ key: 'open-B' })).toBeDefined()
    await ui.unmount()
  }
})

test('outside the hub the Deck shows the lanes without controls', async ($, on) => {
  seed(on, viewWith(hubView(false)), EMPTY)
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect(await ui.find({ type: 'Text', text: /Los controles están en las sesiones de la cuenta A/ })).toBeDefined()
  expect(await ui.find({ key: 'msg-w1' })).toBeUndefined()
  expect(await ui.find({ key: 'nw-toggle' })).toBeUndefined()
  await ui.unmount()
})

test('the stop button asks for a second press', async ($, on) => {
  seed(on, viewWith(hubView(true)), { ...EMPTY, confirmStop: 'w1' })
  const ui = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect((await ui.find({ key: 'stop-w1' }))?.text).toContain('pulsa otra vez')
  await ui.unmount()
})

test('the terminal keeps the text pane', async ($, on) => {
  seed(on, viewWith(hubView(true)), EMPTY)
  const ui = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect(await ui.find({ type: 'Text', text: /^FLEET$/ })).toBeDefined()
  expect(await ui.find({ type: 'Text', text: /FLEET DECK/ })).toBeUndefined()
  await ui.unmount()
})
