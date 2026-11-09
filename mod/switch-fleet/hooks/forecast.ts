// Where each window is heading: a straight line through its recent samples. The samples come
// from usage-history.jsonl (one per `open-session.ps1 -List`) and from the sessions' own
// readings in their heartbeats. Only samples of the current window count (same reset time).
import type { Beat, Forecast } from '../types'

export type Sample = { at: number; pct: number; resetsAt: string | null }
export type WindowSamples = { five: Sample[]; week: Sample[] }
export type History = Map<string, WindowSamples>

export const FIVE_LOOKBACK_MS = 90 * 60_000
export const WEEK_LOOKBACK_MS = 24 * 3_600_000
/** A fit needs samples spread over at least this long. */
const MIN_SPAN_MS = 10 * 60_000
/** Two reset times this close are the same window (/usage prints minutes, the API milliseconds). */
const SAME_WINDOW_MS = 5 * 60_000
/** Below this pace the window is read as steady. */
export const STEADY_PER_HOUR = 0.5

const empty = (): WindowSamples => ({ five: [], week: [] })

/** usage-history.jsonl, by account name. Lines that do not parse are skipped. */
export function parseHistory(text: string): History {
  const out: History = new Map()
  for (const line of text.split(/\r?\n/)) {
    if (!line.trim()) continue
    let d: unknown
    try {
      d = JSON.parse(line)
    } catch {
      continue
    }
    if (typeof d !== 'object' || d === null) continue
    const r = d as Record<string, unknown>
    const at = typeof r.at === 'string' ? Date.parse(r.at) : NaN
    if (typeof r.name !== 'string' || Number.isNaN(at)) continue
    const slot = out.get(r.name) ?? empty()
    if (typeof r.fiveHour === 'number') slot.five.push({ at, pct: r.fiveHour, resetsAt: typeof r.fiveHourResetsAt === 'string' ? r.fiveHourResetsAt : null })
    if (typeof r.weekly === 'number') slot.week.push({ at, pct: r.weekly, resetsAt: typeof r.weeklyResetsAt === 'string' ? r.weeklyResetsAt : null })
    out.set(r.name, slot)
  }
  return out
}

/** The readings sessions made of their own account's windows. */
export function samplesFromBeats(beats: Beat[]): WindowSamples {
  const out = empty()
  for (const b of beats) {
    if (!b.limits || b.limitsAt === null) continue
    if (b.limits.fiveHour !== null) out.five.push({ at: b.limitsAt, pct: b.limits.fiveHour, resetsAt: b.limits.fiveHourResetsAt })
    if (b.limits.weekly !== null) out.week.push({ at: b.limitsAt, pct: b.limits.weekly, resetsAt: b.limits.weeklyResetsAt })
  }
  return out
}

const sameWindow = (a: string | null, b: string | null) => {
  if (!a || !b) return false
  const x = Date.parse(a)
  const y = Date.parse(b)
  return !Number.isNaN(x) && !Number.isNaN(y) && Math.abs(x - y) <= SAME_WINDOW_MS
}

/**
 * The pace of one window and where it leads, or null when there is too little to go on: fewer
 * than two samples of this window in the lookback, or ones spread over under ten minutes.
 */
export function forecast(samples: Sample[], now: number, pct: number | null, cap: number | null, resetsAt: string | null, lookbackMs: number): Forecast | null {
  if (pct === null || !resetsAt) return null
  const reset = Date.parse(resetsAt)
  if (Number.isNaN(reset) || reset <= now) return null
  const pts = samples.filter(s => s.at <= now && now - s.at <= lookbackMs && sameWindow(s.resetsAt, resetsAt))
  if (pts.length < 2) return null
  const t0 = Math.min(...pts.map(p => p.at))
  const span = Math.max(...pts.map(p => p.at)) - t0
  if (span < MIN_SPAN_MS) return null
  // Least squares, with time in hours from the first sample.
  const xs = pts.map(p => (p.at - t0) / 3_600_000)
  const ys = pts.map(p => p.pct)
  const mx = xs.reduce((a, b) => a + b, 0) / xs.length
  const my = ys.reduce((a, b) => a + b, 0) / ys.length
  let num = 0
  let den = 0
  xs.forEach((x, i) => {
    num += (x - mx) * ((ys[i] ?? my) - my)
    den += (x - mx) ** 2
  })
  if (den === 0) return null
  const rate = Math.max(0, num / den)
  const ratePerHour = Math.round(rate * 10) / 10
  const hoursLeft = (reset - now) / 3_600_000
  // Steady is judged on the rounded pace, the one the pane shows.
  if (ratePerHour < STEADY_PER_HOUR) return { ratePerHour, capAt: null, atReset: Math.min(100, Math.round(pct + rate * hoursLeft)) }
  if (cap !== null && pct < cap) {
    const capAt = now + ((cap - pct) / rate) * 3_600_000
    if (capAt < reset) return { ratePerHour, capAt, atReset: null }
  }
  return { ratePerHour, capAt: null, atReset: Math.min(100, Math.round(pct + rate * hoursLeft)) }
}
