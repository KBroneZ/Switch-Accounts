import { describe, expect, test } from 'claude-code/testing'

import type { FleetView } from '../types'
import { buildFleet, parseSnapshot } from '../hooks/core'
import { buildTokens, codexNames, costOf, plainText, fmtTokens, fmtUsd, parseTokens, periodBounds, periodsOf, priceOf, tokenLines, tokenMarkdown, tokensOf } from '../hooks/tokens'
import type { TokenDay } from '../hooks/tokens'

/** Dollars to the millionth: float sums are not exact. */
const usd = (n: number | null | undefined) => (n === null || n === undefined ? n : Math.round(n * 1e6) / 1e6)

// Wednesday 2030-01-16, 12:00 UTC; the tests run in UTC (offset 0) and in UTC+1 (offset -60).
const NOW = Date.parse('2030-01-16T12:00:00Z')

const day = (over: Partial<TokenDay>): TokenDay => ({ d: '2030-01-16', a: 'A', m: 'claude-opus-5-5', i: 0, o: 0, w5: 0, w1: 0, r: 0, ...over })

const doc = (days: unknown[], extra: Record<string, unknown> = {}) =>
  JSON.stringify({ schema: 1, updatedAt: '2030-01-16T11:55:00Z', isComplete: true, sources: [{ account: 'A', kind: 'claude' }, { account: 'ChatGPT', kind: 'codex' }], days, notes: [], ...extra })

describe('cost', () => {
  test('prices each kind of token at the model rate per million', () => {
    // Opus 5.5: $4 in, $20 out, $5 5m write, $8 1h write, $0.20 cache read.
    expect(usd(costOf(day({ i: 1_000_000, o: 1_000_000, w5: 1_000_000, w1: 1_000_000, r: 1_000_000 })))).toBe(37.2)
    expect(usd(costOf(day({ m: 'claude-sonnet-5-5', r: 10_000_000 })))).toBe(1)
    expect(usd(costOf(day({ m: 'gpt-6-luna', i: 2_000_000, r: 9_000_000, o: 400_000 })))).toBe(0.49)
  })

  test('fast mode, Haiku long prompts and dated ids find their own prices', () => {
    expect(costOf(day({ m: 'claude-opus-5-5@fast', o: 1_000_000 }))).toBe(40)
    expect(costOf(day({ m: 'claude-haiku-5-5@long', i: 1_000_000 }))).toBe(0.5)
    expect(priceOf('claude-haiku-4-5-20251001')?.output).toBe(5)
  })

  test('an unknown model, or a cache write with no price, is unknown rather than $0', () => {
    expect(costOf(day({ m: 'claude-future-9', i: 10 }))).toBeNull()
    expect(costOf(day({ m: 'gpt-5.5', w5: 10 }))).toBeNull()
    expect(costOf(day({ m: 'gpt-5.5', i: 1_000_000 }))).toBe(5)
  })
})

describe('periods', () => {
  test('today, the week from Monday, the month and all time, in local days', () => {
    expect(periodBounds(NOW, 0)).toEqual({ today: '2030-01-16', weekStart: '2030-01-14', month: '2030-01' })
    // 23:30 UTC on Sunday the 20th is already Monday the 21st in UTC+1: a new week there.
    expect(periodBounds(Date.parse('2030-01-20T23:30:00Z'), -60).weekStart).toBe('2030-01-21')
    expect(periodBounds(Date.parse('2030-01-20T23:30:00Z'), 0).weekStart).toBe('2030-01-14')
    const p = periodsOf(
      [day({ i: 1 }), day({ d: '2030-01-14', i: 10 }), day({ d: '2030-01-13', i: 100 }), day({ d: '2029-12-31', i: 1000 })],
      NOW,
      0,
    )
    expect([p.today.input, p.week.input, p.month.input, p.all.input]).toEqual([1, 11, 111, 1111])
    expect(p.all.total).toBe(1111)
  })

  test('sums per account and in total, with unpriced tokens kept apart', () => {
    const s = parseTokens(doc([day({ o: 1_000_000 }), day({ a: 'ChatGPT', m: 'gpt-6', i: 500 }), day({ a: '.claude-account2', r: 5_000_000 })]))!
    const v = buildTokens(s, NOW, 0)
    expect(v.byAccount.map(a => a.name)).toEqual(['A', 'ChatGPT', '.claude-account2'])
    expect(tokensOf(v, 'chatgpt')?.kind).toBe('codex')
    expect(tokensOf(v, 'ChatGPT')?.periods.all.unpricedTokens).toBe(500)
    expect(v.total.all.total).toBe(6_000_500)
    expect(usd(v.total.all.usd)).toBe(21)
    expect(v.unknownModels).toEqual(['gpt-6'])
    expect(v.since).toBe('2030-01-16')
  })
})

describe('Codex homes', () => {
  test('one home is ChatGPT; several are named by suffix, the main one A', () => {
    expect([...codexNames([{ account: '.codex', kind: 'codex' }])]).toEqual([['.codex', 'ChatGPT']])
    expect([...codexNames([{ account: 'A', kind: 'claude' }, { account: '.codex', kind: 'codex' }, { account: '.codex-b', kind: 'codex' }])]).toEqual([
      ['.codex', 'ChatGPT A'],
      ['.codex-b', 'ChatGPT B'],
    ])
    expect(codexNames([{ account: '.codex-x', kind: 'codex' }, { account: '.codex-b', kind: 'codex' }]).get('.codex-x')).toBe('ChatGPT X')
  })

  test('each home gets the tokens of its card', () => {
    const s = parseTokens(doc([day({ a: '.codex', m: 'gpt-6-luna', o: 10 }), day({ a: '.codex-b', m: 'gpt-6-luna', o: 5 })], { sources: [{ account: 'A', kind: 'claude' }, { account: '.codex', kind: 'codex' }, { account: '.codex-b', kind: 'codex' }] }))!
    const v = buildTokens(s, NOW, 0)
    expect(tokensOf(v, 'ChatGPT A')?.periods.all.output).toBe(10)
    expect(tokensOf(v, 'ChatGPT B')?.periods.all.output).toBe(5)
    expect(tokensOf(v, 'ChatGPT B')?.kind).toBe('codex')
    expect(v.total.all.output).toBe(15)
  })
})

describe('tokens.json', () => {
  test('reads schema 1 and skips rows that are not counts', () => {
    const s = parseTokens(doc([day({ i: 5 }), { d: 'yesterday', a: 'A', m: 'x', i: 1, o: 1, w5: 0, w1: 0, r: 0 }, { ...day({}), i: -3 }, 'junk']))!
    expect(s.days).toHaveLength(1)
    expect(s.isComplete).toBe(true)
    expect(parseTokens('{"schema":2,"days":[]}')).toBeNull()
    const odd = parseTokens(doc([day({ a: 'A\u001b[31m' }), day({ m: 'x'.repeat(81) }), day({ i: 2 })], { notes: ['bad\u001b[2Jnote\n', 7] }))!
    expect(odd.days).toHaveLength(1)
    expect(odd.notes).toEqual(['bad [2Jnote'])
    expect(plainText('a\u0007b\u009bc')).toBe('a b c')
    expect(parseTokens('nope')).toBeNull()
  })
})

describe('formatting', () => {
  test('compact token counts', () => {
    expect([0, 999, 1000, 1234, 12_345, 999_499, 999_600, 3_400_000, 123_456_789, 5_600_000_000, 11_792_048_794].map(fmtTokens)).toEqual([
      '0',
      '999',
      '1k',
      '1.2k',
      '12k',
      '999k',
      '1M',
      '3.4M',
      '123M',
      '5.6B',
      '12B',
    ])
  })

  test('dollars, and unknown cost marked as such', () => {
    expect(fmtUsd({ usd: 0.421, unpricedTokens: 0, total: 5 })).toBe('$0.42')
    expect(fmtUsd({ usd: 12.4, unpricedTokens: 0, total: 5 })).toBe('$12')
    expect(fmtUsd({ usd: 3456, unpricedTokens: 0, total: 5 })).toBe('$3.5k')
    expect(fmtUsd({ usd: 12, unpricedTokens: 3, total: 5 })).toBe('$12+?')
    expect(fmtUsd({ usd: 0, unpricedTokens: 5, total: 5 })).toBe('$?')
  })

  test('the table fits the pane: fixed-width lines and a Markdown table', () => {
    const v = buildTokens(parseTokens(doc([day({ i: 1200, o: 340_000, w1: 2_100_000, r: 45_000_000 })]))!, NOW, 0)
    const lines = tokenLines(v.total)
    expect(lines).toHaveLength(5)
    expect(lines[0]).toBe('tokens     in    out   c.wr   c.rd  total  API $')
    // 47.44M tokens; $0.0048 + $6.80 + $16.80 + $9.00 = $32.60.
    expect(lines[1]).toBe('today    1.2k   340k   2.1M    45M    47M    $33')
    expect(Math.max(...lines.map(l => l.length))).toBeLessThanOrEqual(48)
    const md = tokenMarkdown(v.total)
    expect(md.split('\n')).toHaveLength(6)
    expect(md).toContain('| all | 1.2k | 340k | 2.1M | 45M | 47M | $33 |')
  })
})

const PANE = {
  plugin: 'switch-fleet',
  component: 'Pane',
  requestId: 'switch-fleet',
  props: { title: 'Fleet', isFocused: false, bodyColumns: 60, placement: 'dock', scroll: { offset: 0, bodyRows: 40 }, view: {} },
} as const

const snapshot = JSON.stringify({
  schema: 1,
  updatedAt: '2030-01-16T11:58:00Z',
  accounts: [
    {
      name: 'A',
      configDir: 'C:\Users\me\.claude',
      auth: { status: 'LoggedIn', plan: 'max', tier: 'max_5x', expiresAt: '2030-02-20T00:00:00Z', loginCommand: 'claude auth login' },
      usage: { status: 'Known', fiveHourPercent: 44, resetsAt: '2030-01-16T15:00:00Z', weeklyPercent: 6, weeklyResetsAt: '2030-01-19T09:00:00Z' },
      caps: { fiveHour: 95, weekly: 98 },
      decision: 'Allow',
      reason: null,
      onboarding: 'Ready',
    },
  ],
})

test('the pane draws each account its tokens and one total, on the terminal and the desktop', async ($, on) => {
  const tokens = buildTokens(parseTokens(doc([day({ o: 340_000, r: 45_000_000 }), day({ a: '.claude-account2', r: 1_000_000 })]))!, NOW, 0)
  const view: FleetView = { ...buildFleet(parseSnapshot(snapshot), [], NOW, null), hub: null, providers: [], pipeline: null, isRefreshing: false, error: null, tokens }
  on('clock.now', () => ({ value: NOW }))
  on('state.get', () => ({ value: { value: { shape: 'fleet-7', value: view }, version: 1 } }))
  const term = await $.ui.mount({ ...PANE, surface: 'terminal' })
  expect(await term.find({ type: 'Text', text: /^today +0 +340k +0 +45M +45M +\$16$/ })).toBeDefined()
  expect(await term.find({ type: 'Text', text: /TOKENS/ })).toBeDefined()
  expect(await term.find({ type: 'Text', text: /incl\. \.claude-account2: all 1M/ })).toBeDefined()
  await term.unmount()
  const desk = await $.ui.mount({ ...PANE, surface: 'desktop' })
  expect(await desk.find({ key: 'tok-A' })).toBeDefined()
  expect(await desk.find({ key: 'tok-total' })).toBeDefined()
  await desk.unmount()
})

test('before the first count the pane says why there are no tokens', async ($, on) => {
  const view: FleetView = { ...buildFleet(parseSnapshot(snapshot), [], NOW, null), hub: null, providers: [], pipeline: null, isRefreshing: false, error: null, tokens: null, tokensNote: 'counting every transcript; the first count can take a few minutes' }
  on('clock.now', () => ({ value: NOW }))
  on('state.get', () => ({ value: { value: { shape: 'fleet-7', value: view }, version: 1 } }))
  for (const surface of ['terminal', 'desktop'] as const) {
    const ui = await $.ui.mount({ ...PANE, surface })
    expect(await ui.find({ type: 'Text', text: /first count can take/ })).toBeDefined()
    await ui.unmount()
  }
})
