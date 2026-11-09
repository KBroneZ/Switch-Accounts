// Other AI subscriptions in the Fleet pane. ChatGPT through Codex: every Codex session writes its
// rate limits into its rollout file (~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl, a `token_count`
// event with `payload.rate_limits`). Reading the newest one costs nothing and needs no credentials;
// it is as fresh as the last Codex turn. Pure parsing here; register.tsx finds and reads the file.
import type { ProviderView, ProviderWindow } from '../types'

/** A reading older than this is drawn as stale ("leído hace …"), still with its numbers. */
export const STALE_MS = 6 * 3_600_000
/** At or above this, a window is near its limit. */
export const NEAR_PERCENT = 90

const isObj = (v: unknown): v is Record<string, unknown> => typeof v === 'object' && v !== null && !Array.isArray(v)
const num = (v: unknown) => (typeof v === 'number' && Number.isFinite(v) ? v : null)

/** A window's name from its length: 5h, 7d, 30d. */
export function windowLabel(minutes: number | null): string {
  if (minutes === null || minutes <= 0) return '?'
  if (minutes % 1440 === 0) return `${minutes / 1440}d`
  if (minutes % 60 === 0) return `${minutes / 60}h`
  return `${minutes}m`
}

function windowOf(v: unknown, now: number): ProviderWindow | null {
  if (!isObj(v)) return null
  const pct = num(v.used_percent)
  const minutes = num(v.window_minutes)
  const resetsAtSec = num(v.resets_at)
  const resetsAt = resetsAtSec !== null ? new Date(resetsAtSec * 1000).toISOString() : null
  // A window whose reset has passed no longer knows its use: unknown until Codex reads it again.
  const isPast = resetsAtSec !== null && resetsAtSec * 1000 <= now
  if (pct === null && minutes === null) return null
  return { label: windowLabel(minutes), windowMinutes: minutes, pct: isPast ? null : pct === null ? null : Math.max(0, Math.min(100, pct)), resetsAt: isPast ? null : resetsAt }
}

/**
 * The rate limits of the newest `token_count` event in a rollout file's text, or null when it has
 * none (a session with no model turn). Lines that do not parse are skipped.
 */
export function parseCodexRollout(text: string, now: number): ProviderView | null {
  const lines = text.split(/\r?\n/)
  for (let i = lines.length - 1; i >= 0; i--) {
    const line = lines[i]!
    if (!line.includes('"rate_limits"')) continue
    let d: unknown
    try {
      d = JSON.parse(line)
    } catch {
      continue
    }
    if (!isObj(d) || !isObj(d.payload) || !isObj(d.payload.rate_limits)) continue
    const r = d.payload.rate_limits
    const at = typeof d.timestamp === 'string' ? Date.parse(d.timestamp) : NaN
    const windows = [windowOf(r.primary, now), windowOf(r.secondary, now)].filter((w): w is ProviderWindow => w !== null)
    if (windows.length === 0) continue
    const plan = typeof r.plan_type === 'string' && /^[a-z0-9_-]{1,20}$/i.test(r.plan_type) ? r.plan_type : null
    const reached = typeof r.rate_limit_reached_type === 'string' && r.rate_limit_reached_type.length > 0
    return providerView('chatgpt', 'ChatGPT', 'Codex', plan, windows, Number.isNaN(at) ? null : at, reached, now)
  }
  return null
}

export function providerView(id: string, name: string, source: string, plan: string | null, windows: ProviderWindow[], readAt: number | null, isReached: boolean, now: number): ProviderView {
  const known = windows.filter(w => w.pct !== null)
  const atLimit = isReached || known.some(w => (w.pct ?? 0) >= 100)
  const health: ProviderView['health'] = atLimit && windows.some(w => w.resetsAt !== null) ? 'at-cap' : known.length === 0 ? 'unknown' : 'ready'
  return { id, name, source, plan, windows, readAt, isStale: readAt === null || now - readAt > STALE_MS, health }
}

/** The part of the status line for each provider: `GPT 99%`. */
export function providerStatus(providers: ProviderView[]): string[] {
  return providers.map(p => {
    const top = p.windows.filter(w => w.pct !== null).sort((a, b) => (b.pct ?? 0) - (a.pct ?? 0))[0]
    const short = p.id === 'chatgpt' ? 'GPT' : p.name
    return top ? `${short} ${Math.round(top.pct!)}%${p.health === 'at-cap' ? ' tope' : ''}` : `${short} ?`
  })
}

/** Warnings toasted once per window: a window near or at its limit. */
export function providerAlerts(providers: ProviderView[], now: number, when: (iso: string) => string): { id: string; text: string }[] {
  const out: { id: string; text: string }[] = []
  for (const p of providers) {
    for (const w of p.windows) {
      if (w.pct === null || w.pct < NEAR_PERCENT || !w.resetsAt || Date.parse(w.resetsAt) <= now) continue
      const window = String(Math.round(Date.parse(w.resetsAt) / 300_000))
      const isAt = w.pct >= 100
      out.push({
        id: `${p.id}:${w.label}:${isAt ? 'at' : 'near'}:${window}`,
        text: `${p.name}: ${isAt ? 'límite alcanzado' : `${Math.round(w.pct)} % usado`} en la ventana de ${w.label}; se reinicia ${when(w.resetsAt)}`,
      })
    }
  }
  return out
}

/** Newest first among `YYYY`, `MM` or `DD` folder names. */
export const newestFirst = (names: string[]) => names.filter(n => /^\d{2,4}$/.test(n)).sort((a, b) => Number(b) - Number(a))
