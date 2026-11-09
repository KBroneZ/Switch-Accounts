import { describe, expect, test } from 'claude-code/testing'

import type { DeckView, FleetView, ProviderView } from '../types'
import { buildFleet, parseSnapshot } from '../hooks/core'
import { newestFirst, parseAgyUsage, parseCodexRollout, providerAlerts, providerLines, providerStatus, STALE_MS, windowLabel } from '../hooks/providers'

const NOW = Date.parse('2030-01-10T12:00:00Z')
const RESET = Math.round(Date.parse('2030-01-25T16:18:25Z') / 1000)

const event = (rateLimits: unknown, at = '2030-01-10T11:00:00.000Z') =>
  JSON.stringify({ timestamp: at, type: 'event_msg', payload: { type: 'token_count', info: null, rate_limits: rateLimits } })

const goPlan = {
  limit_id: 'codex',
  primary: { used_percent: 99.0, window_minutes: 43200, resets_at: RESET },
  secondary: null,
  credits: { has_credits: false, unlimited: false, balance: null },
  plan_type: 'go',
  rate_limit_reached_type: null,
}

describe('codex rollout', () => {
  test('reads the newest rate limits of a rollout file', () => {
    const text = [
      JSON.stringify({ timestamp: 'x', type: 'session_meta', payload: {} }),
      event({ ...goPlan, primary: { ...goPlan.primary, used_percent: 50 } }, '2030-01-10T10:00:00.000Z'),
      'not json',
      event(goPlan),
      '',
    ].join('\n')
    const p = parseCodexRollout(text, NOW)!
    expect(p.name).toBe('ChatGPT')
    expect(p.plan).toBe('go')
    expect(p.windows).toEqual([{ label: '30d', windowMinutes: 43200, pct: 99, resetsAt: '2030-01-25T16:18:25.000Z' }])
    expect(p.readAt).toBe(Date.parse('2030-01-10T11:00:00.000Z'))
    expect(p.isStale).toBe(false)
    expect(p.health).toBe('ready')
  })

  test('takes both windows, and a past reset as unknown use', () => {
    const p = parseCodexRollout(
      event({
        primary: { used_percent: 40, window_minutes: 300, resets_at: Math.round((NOW - 60_000) / 1000) },
        secondary: { used_percent: 12, window_minutes: 10080, resets_at: RESET },
        plan_type: 'plus',
      }),
      NOW,
    )!
    expect(p.windows.map(w => [w.label, w.pct])).toEqual([
      ['5h', null],
      ['7d', 12],
    ])
  })

  test('a reached limit or 100 % is at its cap; an old reading is stale', () => {
    expect(parseCodexRollout(event({ ...goPlan, rate_limit_reached_type: 'primary' }), NOW)?.health).toBe('at-cap')
    expect(parseCodexRollout(event({ ...goPlan, primary: { ...goPlan.primary, used_percent: 100 } }), NOW)?.health).toBe('at-cap')
    expect(parseCodexRollout(event(goPlan, new Date(NOW - STALE_MS - 1).toISOString()), NOW)?.isStale).toBe(true)
  })

  test('nothing from a file without rate limits, or with an odd plan name', () => {
    expect(parseCodexRollout('{"type":"session_meta"}\n', NOW)).toBeNull()
    expect(parseCodexRollout(event({ primary: null, secondary: null }), NOW)).toBeNull()
    expect(parseCodexRollout(event({ ...goPlan, plan_type: '<script>' }), NOW)?.plan).toBeNull()
  })

  test('names windows by length and sorts date folders newest first', () => {
    expect([windowLabel(300), windowLabel(10080), windowLabel(43200), windowLabel(90), windowLabel(null)]).toEqual(['5h', '7d', '30d', '90m', '?'])
    expect(newestFirst(['2025', 'x', '2026', '09', '11'])).toEqual(['2026', '2025', '11', '09'])
  })
})

// The real shape of `agy -p /usage --output-format json` on a Google AI Plus account.
const agyOutput = (gemini: number, thirdParty: number, reset = '2030-01-15T20:26:10Z') =>
  JSON.stringify({
    conversation_id: '',
    status: 'SUCCESS',
    response: 'Gemini Models\tWeekly Limit Remaining\t100%\t…\n',
    usage: { input_tokens: 0, output_tokens: 0, total_tokens: 0 },
    command: {
      name: 'usage',
      data: {
        description: 'Within each group, models share a weekly limit.',
        groups: [
          { name: 'Gemini Models', description: 'Gemini Flash, Gemini Pro', buckets: [{ id: 'gemini-weekly', name: 'Weekly Limit Remaining', window: 'weekly', remaining_fraction: gemini, reset_time: reset }] },
          { name: 'Claude and GPT models', description: 'Claude Opus, Claude Sonnet, GPT-OSS', buckets: [{ id: '3p-weekly', name: 'Weekly Limit Remaining', window: 'weekly', remaining_fraction: thirdParty, reset_time: reset }] },
        ],
      },
    },
  })

describe('antigravity usage', () => {
  const READ_AT = NOW - 60_000

  test('reads both weekly groups as used percent', () => {
    const p = parseAgyUsage(agyOutput(1, 0.25), NOW, READ_AT)!
    expect(p.id).toBe('gemini')
    expect(p.name).toBe('Gemini')
    expect(p.source).toBe('Antigravity')
    expect(p.plan).toBeNull()
    expect(p.windows).toEqual([
      { label: 'Gemini 7d', windowMinutes: 10080, pct: 0, resetsAt: '2030-01-15T20:26:10.000Z' },
      { label: 'Claude/GPT 7d', windowMinutes: 10080, pct: 75, resetsAt: '2030-01-15T20:26:10.000Z' },
    ])
    expect(p.readAt).toBe(READ_AT)
    expect(p.readNote).toBe('consultado a Antigravity')
    expect(p.health).toBe('ready')
  })

  test('skips log lines before the JSON, and a group with nothing left is at its cap', () => {
    const p = parseAgyUsage(`I1110 starting\n${agyOutput(0, 0.5)}\n`, NOW, READ_AT)!
    expect(p.windows[0]!.pct).toBe(100)
    expect(p.health).toBe('at-cap')
    const pretty = JSON.stringify(JSON.parse(agyOutput(0.5, 0.5)), null, 2)
    expect(parseAgyUsage(pretty, NOW, READ_AT)?.windows.map(w => w.pct)).toEqual([50, 50])
  })

  test('a past reset is unknown use; an old reading is stale', () => {
    expect(parseAgyUsage(agyOutput(0.5, 0.5, '2030-01-10T11:00:00Z'), NOW, READ_AT)!.windows.map(w => w.pct)).toEqual([null, null])
    expect(parseAgyUsage(agyOutput(1, 1), NOW, NOW - STALE_MS - 1)!.isStale).toBe(true)
  })

  test('nothing from a failed run, a non-usage answer or odd values', () => {
    expect(parseAgyUsage('', NOW, NOW)).toBeNull()
    expect(parseAgyUsage('not json', NOW, NOW)).toBeNull()
    expect(parseAgyUsage(JSON.stringify({ status: 'ERROR', command: { name: 'usage', data: { groups: [] } } }), NOW, NOW)).toBeNull()
    expect(parseAgyUsage(JSON.stringify({ status: 'SUCCESS', response: 'hola' }), NOW, NOW)).toBeNull()
    const odd = JSON.parse(agyOutput(1, 1))
    odd.command.data.groups[0].buckets[0].remaining_fraction = 'x'
    odd.command.data.groups[1].name = '<b>Some Very Long Group Name</b>'
    const p = parseAgyUsage(JSON.stringify(odd), NOW, NOW)!
    expect(p.windows).toHaveLength(1)
    expect(p.windows[0]!.label).toBe('bSomeVeryLon 7d')
  })

  test('status line and alerts name the group', () => {
    const p = parseAgyUsage(agyOutput(0.95, 0.04), NOW, READ_AT)!
    expect(providerStatus([p])).toEqual(['Gemini 96%'])
    const alerts = providerAlerts([p], NOW, () => '15 ene')
    expect(alerts.map(a => a.text)).toEqual(['Gemini: 96 % usado en la ventana de Claude/GPT 7d; se reinicia 15 ene'])
  })
})

describe('providers for the hub', () => {
  test('one line per provider with every window, its reset and the reading age', () => {
    const gpt = parseCodexRollout(event(goPlan), NOW)!
    const gem = parseAgyUsage(agyOutput(1, 0.25), NOW, NOW - 120_000)!
    expect(providerLines([gpt, gem], NOW)).toEqual([
      'ChatGPT (vía Codex, plan go): disponible · 30d 99% (reinicio 2030-01-25T16:18:25.000Z) · leído hace 1 h',
      'Gemini (vía Antigravity): disponible · Gemini 7d 0% (reinicio 2030-01-15T20:26:10.000Z) · Claude/GPT 7d 75% (reinicio 2030-01-15T20:26:10.000Z) · leído hace 2 min',
    ])
  })

  test('at the limit, unknown and stale readings say so', () => {
    const capped = parseCodexRollout(event({ ...goPlan, primary: { ...goPlan.primary, used_percent: 100 } }, new Date(NOW - STALE_MS - 60_000).toISOString()), NOW)!
    expect(providerLines([capped], NOW)[0]).toMatch(/^ChatGPT \(vía Codex, plan go\): en su límite · 30d 100% .* · leído hace 6 h \(antiguo\)$/)
    const unknown = parseAgyUsage(agyOutput(0.5, 0.5, '2030-01-10T11:00:00Z'), NOW, NOW)!
    expect(providerLines([unknown], NOW)[0]).toBe('Gemini (vía Antigravity): sin dato · Gemini 7d ? · Claude/GPT 7d ? · leído hace 0 min')
  })
})

describe('provider status and alerts', () => {
  const p = parseCodexRollout(event(goPlan), NOW)!

  test('status line part', () => {
    expect(providerStatus([p])).toEqual(['GPT 99%'])
    expect(providerStatus([{ ...p, windows: [] }])).toEqual(['GPT ?'])
  })

  test('warns once per window near or at the limit', () => {
    const alerts = providerAlerts([p], NOW, () => '25 nov')
    expect(alerts).toHaveLength(1)
    expect(alerts[0]!.text).toBe('ChatGPT: 99 % usado en la ventana de 30d; se reinicia 25 nov')
    expect(providerAlerts([{ ...p, windows: [{ ...p.windows[0]!, pct: 50 }] }], NOW, () => '')).toHaveLength(0)
  })
})

const snapshot = parseSnapshot(
  JSON.stringify({
    schema: 1,
    updatedAt: '2030-01-10T11:58:00Z',
    accounts: [
      {
        name: 'A',
        configDir: 'C:\\Users\\me\\.claude',
        auth: { status: 'LoggedIn', plan: 'max', tier: 'max_5x', expiresAt: '2030-02-20T00:00:00Z', loginCommand: 'claude auth login' },
        usage: { status: 'Known', fiveHourPercent: 44, resetsAt: '2030-01-10T15:00:00Z', weeklyPercent: 6, weeklyResetsAt: '2030-01-15T09:00:00Z' },
        caps: { fiveHour: 95, weekly: 98 },
        decision: 'Allow',
        reason: null,
        onboarding: 'Ready',
      },
    ],
  }),
)

const DECK: DeckView = { note: null, isNoteError: false, busy: null, confirmStop: null, confirmAt: null, isFormOpen: false }

const PANE = {
  plugin: 'switch-fleet',
  component: 'Pane',
  requestId: 'switch-fleet',
  props: { title: 'Fleet', isFocused: false, bodyColumns: 60, placement: 'dock', scroll: { offset: 0, bodyRows: 30 }, view: {} },
} as const

test('the ChatGPT card is drawn beside the accounts, on the desktop and in the terminal', async ($, on) => {
  const provider: ProviderView = parseCodexRollout(event(goPlan), NOW)!
  const view: FleetView = { ...buildFleet(snapshot, [], NOW, null), providers: [provider], hub: null, pipeline: null, isRefreshing: false, error: null }
  on('clock.now', () => ({ value: NOW }))
  on('state.get', (_$, e) =>
    e.key === 'fleet' ? { value: { value: { shape: 'fleet-7', value: view }, version: 1 } } : { value: { value: { shape: 'deck-2', value: DECK }, version: 1 } },
  )
  for (const surface of ['desktop', 'terminal'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })
    expect(await ui.find({ type: 'Text', text: /^ChatGPT$/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /vía Codex/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /99%/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /último uso de Codex/ })).toBeDefined()
    await ui.unmount()
  }
})

test('the Gemini card shows each group of models', async ($, on) => {
  const provider: ProviderView = parseAgyUsage(agyOutput(0.6, 1), NOW, NOW - 120_000)!
  const view: FleetView = { ...buildFleet(snapshot, [], NOW, null), providers: [provider], hub: null, pipeline: null, isRefreshing: false, error: null }
  on('clock.now', () => ({ value: NOW }))
  on('state.get', (_$, e) =>
    e.key === 'fleet' ? { value: { value: { shape: 'fleet-7', value: view }, version: 1 } } : { value: { value: { shape: 'deck-2', value: DECK }, version: 1 } },
  )
  for (const surface of ['desktop', 'terminal'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })
    expect(await ui.find({ type: 'Text', text: /^Gemini$/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /vía Antigravity/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /Claude\/GPT 7d/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /40%/ })).toBeDefined()
    expect(await ui.find({ type: 'Text', text: /consultado a Antigravity/ })).toBeDefined()
    await ui.unmount()
  }
})
