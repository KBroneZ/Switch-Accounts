import { describe, expect, test } from 'claude-code/testing'

import type { AccountView } from '../types'
import { alertsFor, forecastText } from '../hooks/core'
import { FIVE_LOOKBACK_MS, forecast, parseHistory, samplesFromBeats } from '../hooks/forecast'

const NOW = Date.parse('2030-01-01T12:00:00Z')
const RESET = '2030-01-01T15:00:00Z'
const min = 60_000

describe('forecast', () => {
  test('a steady climb reaches the cap before the reset', () => {
    // 20% an hour: 40 at 11:00, 60 now; cap 80 -> one more hour.
    const s = [
      { at: NOW - 60 * min, pct: 40, resetsAt: RESET },
      { at: NOW - 30 * min, pct: 50, resetsAt: '2030-01-01T15:00:30Z' },
      { at: NOW, pct: 60, resetsAt: RESET },
    ]
    const f = forecast(s, NOW, 60, 80, RESET, FIVE_LOOKBACK_MS)
    expect(f?.ratePerHour).toBe(20)
    expect(f?.capAt).toBe(NOW + 60 * min)
    expect(f?.atReset).toBeNull()
  })

  test('a slow climb ends the window below the cap', () => {
    const s = [{ at: NOW - 60 * min, pct: 30, resetsAt: RESET }, { at: NOW, pct: 35, resetsAt: RESET }]
    const f = forecast(s, NOW, 35, 80, RESET, FIVE_LOOKBACK_MS)
    expect(f?.capAt).toBeNull()
    expect(f?.atReset).toBe(50)
  })

  test('needs two samples of this window spread over ten minutes', () => {
    const old = { at: NOW - 60 * min, pct: 90, resetsAt: '2030-01-01T10:00:00Z' }
    expect(forecast([old, { at: NOW, pct: 10, resetsAt: RESET }], NOW, 10, 80, RESET, FIVE_LOOKBACK_MS)).toBeNull()
    expect(forecast([{ at: NOW - 5 * min, pct: 9, resetsAt: RESET }, { at: NOW, pct: 10, resetsAt: RESET }], NOW, 10, 80, RESET, FIVE_LOOKBACK_MS)).toBeNull()
    expect(forecast([], NOW, null, 80, RESET, FIVE_LOOKBACK_MS)).toBeNull()
  })

  test('reads usage-history.jsonl and the sessions readings', () => {
    const h = parseHistory('{"at":"2030-01-01T11:00:00Z","name":"A","fiveHour":40,"fiveHourResetsAt":"2030-01-01T15:00:00Z","weekly":5}\nbad\n')
    expect(h.get('A')?.five).toEqual([{ at: NOW - 60 * min, pct: 40, resetsAt: RESET }])
    expect(h.get('A')?.week[0]?.pct).toBe(5)
    const live = samplesFromBeats([
      { limits: { fiveHour: 50, fiveHourResetsAt: RESET, weekly: null, weeklyResetsAt: null }, limitsAt: NOW } as never,
      { limits: null, limitsAt: null } as never,
    ])
    expect(live.five).toEqual([{ at: NOW, pct: 50, resetsAt: RESET }])
    expect(live.week).toEqual([])
  })
})

const account = (over: Partial<AccountView>): AccountView => ({
  name: 'A',
  plan: null,
  health: 'ready',
  reason: null,
  loginCommand: null,
  loginExpiresAt: null,
  fiveHour: { pct: 60, cap: 80, resetsAt: RESET, isLive: false },
  weekly: { pct: 5, cap: null, resetsAt: null, isLive: false },
  fiveHourForecast: null,
  weeklyForecast: null,
  sessions: [],
  ...over,
})

describe('alerts', () => {
  test('warns of a cap within 45 minutes and of a login that expires within 3 days', () => {
    const alerts = alertsFor(
      [account({ fiveHourForecast: { ratePerHour: 30, capAt: NOW + 40 * min, atReset: null }, loginExpiresAt: '2030-01-02T12:00:00Z' })],
      NOW,
      0,
    )
    expect(alerts.map(a => a.id)).toEqual([`A:cap5:${Math.round(Date.parse(RESET) / 300_000)}`, 'A:login:2030-01-02T12:00:00Z'])
    expect(alerts[0]?.text).toContain('12:40')
  })

  test('names a window the same from a session reading and from /usage', () => {
    const f = { ratePerHour: 30, capAt: NOW + 40 * min, atReset: null }
    const live = alertsFor([account({ fiveHourForecast: f, fiveHour: { pct: 60, cap: 80, resetsAt: '2030-01-01T15:00:00.000Z', isLive: true } })], NOW, 0)
    const snap = alertsFor([account({ fiveHourForecast: f, fiveHour: { pct: 60, cap: 80, resetsAt: '2030-01-01T15:00:00Z', isLive: false } })], NOW, 0)
    expect(live[0]?.id).toBe(snap[0]?.id)
  })

  test('does not warn of a cap for an account that cannot be used anyway', () => {
    const f = { ratePerHour: 30, capAt: NOW + 40 * min, atReset: null }
    expect(alertsFor([account({ health: 'logged-out', fiveHourForecast: f })], NOW, 0)).toEqual([])
  })

  test('stays quiet for a far cap, a far login and an expired one', () => {
    const alerts = alertsFor(
      [account({ fiveHourForecast: { ratePerHour: 5, capAt: NOW + 2 * 60 * min, atReset: null }, loginExpiresAt: '2029-12-31T00:00:00Z' })],
      NOW,
      0,
    )
    expect(alerts).toEqual([])
  })

  test('words the pace for the pane', () => {
    expect(forecastText({ ratePerHour: 20, capAt: NOW + 60 * min, atReset: null }, NOW, 0)).toEqual({ text: 'ritmo 20%/h → tope ~13:00', isWarning: true })
    expect(forecastText({ ratePerHour: 5, capAt: null, atReset: 50 }, NOW, 0)?.text).toBe('ritmo 5%/h → ~50% al reinicio')
    expect(forecastText({ ratePerHour: 0.2, capAt: null, atReset: 36 }, NOW, 0)).toBeNull()
  })
})
