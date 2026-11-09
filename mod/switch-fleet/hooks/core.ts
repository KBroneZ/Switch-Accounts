// Pure logic of the Fleet pane: parsing the files, merging them into a view, formatting.
// Nothing here touches `$`, so the tests call it directly.
import type { AccountHealth, AccountView, Beat, BeatLimits, FleetView, Meter, PipelineView, SessionView } from '../types'
import { FIVE_LOOKBACK_MS, forecast, samplesFromBeats, WEEK_LOOKBACK_MS } from './forecast'
import type { History } from './forecast'

/** A heartbeat older than this is drawn as quiet (the session may be gone). */
export const QUIET_MS = 3 * 60_000
/** A heartbeat older than this, or an ended one older than ENDED_MS, is not drawn. */
export const GONE_MS = 20 * 60_000
export const ENDED_MS = 60_000

export type SnapshotAccount = {
  name: string
  configDir: string
  auth: { status: string; plan: string | null; tier: string | null; expiresAt: string | null; loginCommand: string | null }
  usage: { status: string; fiveHourPercent: number | null; resetsAt: string | null; weeklyPercent: number | null; weeklyResetsAt: string | null }
  caps: { fiveHour: number | null; weekly: number | null }
  decision: string
  reason: string | null
  onboarding: string
}

export type Snapshot = { updatedAt: string | null; accounts: SnapshotAccount[] }

const isObj = (v: unknown): v is Record<string, unknown> => typeof v === 'object' && v !== null && !Array.isArray(v)
const str = (v: unknown): string | null => (typeof v === 'string' && v.length > 0 ? v : null)
const num = (v: unknown): number | null => (typeof v === 'number' && Number.isFinite(v) ? v : null)

/** Compares config dirs across spellings: case, slashes and a trailing separator. */
export const normPath = (p: string) => p.replace(/\\/g, '/').replace(/\/+$/, '').toLowerCase()

export const baseName = (p: string) => {
  const parts = p.replace(/\\/g, '/').replace(/\/+$/, '').split('/')
  return parts[parts.length - 1] || p
}

/** status.json written by open-session.ps1 -List (schema 1), or null when it is not that. */
export function parseSnapshot(text: string): Snapshot | null {
  let doc: unknown
  try {
    doc = JSON.parse(text)
  } catch {
    return null
  }
  if (!isObj(doc) || doc.schema !== 1 || !Array.isArray(doc.accounts)) return null
  const accounts: SnapshotAccount[] = []
  for (const a of doc.accounts) {
    if (!isObj(a) || !str(a.name) || !str(a.configDir)) continue
    const auth = isObj(a.auth) ? a.auth : {}
    const usage = isObj(a.usage) ? a.usage : {}
    const caps = isObj(a.caps) ? a.caps : {}
    accounts.push({
      name: str(a.name)!,
      configDir: str(a.configDir)!,
      auth: {
        status: str(auth.status) ?? 'Unknown',
        plan: str(auth.plan),
        tier: str(auth.tier),
        expiresAt: str(auth.expiresAt),
        loginCommand: str(auth.loginCommand),
      },
      usage: {
        status: str(usage.status) ?? 'Unknown',
        fiveHourPercent: num(usage.fiveHourPercent),
        resetsAt: str(usage.resetsAt),
        weeklyPercent: num(usage.weeklyPercent),
        weeklyResetsAt: str(usage.weeklyResetsAt),
      },
      caps: { fiveHour: num(caps.fiveHour), weekly: num(caps.weekly) },
      decision: str(a.decision) ?? 'Block',
      reason: str(a.reason),
      onboarding: str(a.onboarding) ?? 'Unknown',
    })
  }
  return { updatedAt: str(doc.updatedAt), accounts }
}

/** One heartbeat file, or null when it is not one this version writes. */
export function parseBeat(text: string): Beat | null {
  let doc: unknown
  try {
    doc = JSON.parse(text)
  } catch {
    return null
  }
  if (!isObj(doc) || doc.schema !== 1 || !str(doc.sessionId) || !str(doc.configDir)) return null
  const state = doc.state === 'working' || doc.state === 'ended' ? doc.state : 'idle'
  const updatedAt = num(doc.updatedAt)
  if (updatedAt === null) return null
  const l = isObj(doc.limits) ? doc.limits : null
  return {
    schema: 1,
    sessionId: str(doc.sessionId)!,
    configDir: str(doc.configDir)!,
    cwd: str(doc.cwd) ?? '',
    repo: str(doc.repo),
    model: str(doc.model),
    state,
    tool: str(doc.tool),
    detail: str(doc.detail),
    prompt: str(doc.prompt),
    ctxPct: num(doc.ctxPct),
    costUsd: num(doc.costUsd),
    limits: l
      ? { fiveHour: num(l.fiveHour), fiveHourResetsAt: str(l.fiveHourResetsAt), weekly: num(l.weekly), weeklyResetsAt: str(l.weeklyResetsAt) }
      : null,
    limitsAt: l ? num(doc.limitsAt) : null,
    worker: str(doc.worker) && /^[A-Za-z0-9][A-Za-z0-9._-]{0,29}$/.test(String(doc.worker)) ? String(doc.worker) : null,
    rollover: doc.rollover === 'requested' || doc.rollover === 'ready' ? doc.rollover : 'none',
    rolloverAt: num(doc.rolloverAt),
    waitingUntil: str(doc.waitingUntil),
    lastReply: str(doc.lastReply),
    finished: doc.finished === true,
    turns: num(doc.turns) ?? 0,
    startedAt: num(doc.startedAt) ?? updatedAt,
    stateSince: num(doc.stateSince) ?? updatedAt,
    updatedAt,
  }
}

/** The session's own reading of its account's windows, from `$.session.usage().rateLimits`. */
export function limitsFrom(rateLimits: readonly { kind: string; percentUsed: number; resetsAt?: string }[] | undefined): BeatLimits | null {
  if (!rateLimits || rateLimits.length === 0) return null
  const five = rateLimits.find(r => r.kind === 'five_hour')
  const week = rateLimits.find(r => r.kind === 'seven_day')
  if (!five && !week) return null
  return {
    fiveHour: five ? five.percentUsed : null,
    fiveHourResetsAt: five?.resetsAt ?? null,
    weekly: week ? week.percentUsed : null,
    weeklyResetsAt: week?.resetsAt ?? null,
  }
}

/** A short, credential-free word on what a tool call touches. */
export function toolDetail(tool: string, input: Record<string, unknown>): string | null {
  const s = (k: string) => (typeof input[k] === 'string' ? (input[k] as string) : null)
  let raw: string | null = null
  if (tool === 'Bash' || tool === 'PowerShell') raw = s('command')
  else if (tool === 'Read' || tool === 'Edit' || tool === 'Write' || tool === 'NotebookEdit') raw = s('file_path') ? baseName(s('file_path')!) : null
  else if (tool === 'Grep' || tool === 'Glob') raw = s('pattern')
  else if (tool === 'Agent' || tool === 'Task') raw = s('description')
  else if (tool === 'WebFetch') raw = s('url')
  else if (tool === 'WebSearch') raw = s('query')
  if (!raw) return null
  return shorten(maskSecrets(raw.replace(/\s+/g, ' ').trim()), 48)
}

/** Masks values that look like keys or tokens before anything is written. */
export function maskSecrets(text: string): string {
  return text
    .replace(/((?:Bearer|Basic)\s+)[^\s"']+/gi, '$1***')
    .replace(/(\/\/[^/\s:@]+:)[^@\s/]+@/g, '$1***@')
    .replace(/(--?(?:token|api-?key|secret|password|passwd|pwd)[=\s]+)[^\s"']+/gi, '$1***')
    .replace(/((?:token|key|secret|password|passwd|pwd|sig|signature|credential)["']?\s*[=:]\s*["']?)[^"'\s&,}]+/gi, '$1***')
    .replace(/\b(sk-[A-Za-z0-9_-]{8,}|gh[pousr]_[A-Za-z0-9]{12,}|xox[abpr]-[A-Za-z0-9-]{8,}|AKIA[0-9A-Z]{12,})/g, '***')
}

export const shorten = (text: string, max: number) => (text.length <= max ? text : `${text.slice(0, Math.max(1, max - 1))}…`)

const meter = (pct: number | null, cap: number | null, resetsAt: string | null, isLive: boolean): Meter => ({ pct, cap, resetsAt, isLive })

/** A window whose reset has passed no longer knows its use: unknown until read again, never 0. */
const expire = (m: Meter, now: number): Meter =>
  m.resetsAt && Date.parse(m.resetsAt) <= now ? { ...m, pct: null, resetsAt: null, isLive: false } : m

/** The freshest live reading of an account's windows among its sessions, if newer than `since`. */
function liveLimits(beats: Beat[], since: number): { limits: BeatLimits; at: number } | null {
  let best: { limits: BeatLimits; at: number } | null = null
  for (const b of beats) {
    const at = b.limitsAt
    if (b.limits && at !== null && at > since && (!best || at > best.at)) best = { limits: b.limits, at }
  }
  return best
}

function healthOf(a: SnapshotAccount | null, five: Meter, week: Meter): { health: AccountHealth; reason: string | null } {
  if (!a) return { health: 'unknown', reason: 'no está en accounts.json' }
  if (a.auth.status === 'LoggedOut') return { health: 'logged-out', reason: 'login caducado' }
  const over = (m: Meter) => m.pct !== null && m.cap !== null && m.pct >= m.cap
  if (over(five) || over(week)) return { health: 'at-cap', reason: over(five) ? 'tope de 5 h' : 'tope semanal' }
  if (five.pct === null) return { health: 'unknown', reason: a.reason ?? 'uso desconocido' }
  if (a.onboarding !== 'Ready' && a.onboarding !== 'Untrusted') return { health: 'not-ready', reason: `sin preparar (${a.onboarding})` }
  return { health: 'ready', reason: null }
}

function sessionView(b: Beat, now: number, selfId: string | null): SessionView {
  return {
    id: b.sessionId,
    worker: b.worker,
    rollover: b.rollover,
    waitingUntil: b.waitingUntil,
    lastReply: b.lastReply,
    isSelf: b.sessionId === selfId,
    liveness: now - b.updatedAt > QUIET_MS && b.sessionId !== selfId ? 'quiet' : 'live',
    state: b.state,
    place: b.repo ?? baseName(b.cwd),
    model: b.model,
    tool: b.tool,
    detail: b.detail,
    prompt: b.prompt,
    ctxPct: b.ctxPct,
    costUsd: b.costUsd,
    stateSince: b.stateSince,
    updatedAt: b.updatedAt,
  }
}

/** Whether a heartbeat is still drawn. */
export const isShown = (b: Beat, now: number) => (b.state === 'ended' ? now - b.updatedAt < ENDED_MS : now - b.updatedAt < GONE_MS)

/** Merges the account snapshot and the heartbeats into what the pane draws. */
export function buildFleet(
  snapshot: Snapshot | null,
  beats: Beat[],
  now: number,
  selfId: string | null,
  history: History = new Map(),
): Omit<FleetView, 'isRefreshing' | 'error' | 'pipeline'> {
  const shown = beats.filter(b => isShown(b, now))
  const byDir = new Map<string, Beat[]>()
  for (const b of shown) {
    const k = normPath(b.configDir)
    byDir.set(k, [...(byDir.get(k) ?? []), b])
  }
  const snapAt = snapshot?.updatedAt ? Date.parse(snapshot.updatedAt) : 0
  const accounts: AccountView[] = []
  const seen = new Set<string>()
  const order = (s: SessionView[]) =>
    [...s].sort((x, y) => Number(y.state === 'working') - Number(x.state === 'working') || y.updatedAt - x.updatedAt)

  for (const a of snapshot?.accounts ?? []) {
    const k = normPath(a.configDir)
    seen.add(k)
    const mine = byDir.get(k) ?? []
    const live = liveLimits(mine, Number.isNaN(snapAt) ? 0 : snapAt)
    const five = live && live.limits.fiveHour !== null
      ? meter(live.limits.fiveHour, a.caps.fiveHour, live.limits.fiveHourResetsAt, true)
      : meter(a.usage.fiveHourPercent, a.caps.fiveHour, a.usage.resetsAt, false)
    const week = live && live.limits.weekly !== null
      ? meter(live.limits.weekly, a.caps.weekly, live.limits.weeklyResetsAt, true)
      : meter(a.usage.weeklyPercent, a.caps.weekly, a.usage.weeklyResetsAt, false)
    // A session that read its own limits after the snapshot proves the login worked then.
    const account = live && a.auth.status === 'LoggedOut' ? { ...a, auth: { ...a.auth, status: 'LoggedIn' } } : a
    const fiveNow = expire(five, now)
    const weekNow = expire(week, now)
    const { health, reason } = healthOf(account, fiveNow, weekNow)
    const past = history.get(a.name)
    const seenLive = samplesFromBeats(mine)
    accounts.push({
      name: a.name,
      plan: a.auth.tier ?? a.auth.plan,
      health,
      reason,
      loginCommand: health === 'logged-out' ? a.auth.loginCommand : null,
      loginExpiresAt: a.auth.expiresAt,
      fiveHour: fiveNow,
      weekly: weekNow,
      fiveHourForecast: forecast([...(past?.five ?? []), ...seenLive.five], now, fiveNow.pct, fiveNow.cap, fiveNow.resetsAt, FIVE_LOOKBACK_MS),
      weeklyForecast: forecast([...(past?.week ?? []), ...seenLive.week], now, weekNow.pct, weekNow.cap, weekNow.resetsAt, WEEK_LOOKBACK_MS),
      sessions: order(mine.map(b => sessionView(b, now, selfId))),
    })
  }
  // Sessions of a config dir that accounts.json does not list.
  for (const [k, mine] of byDir) {
    if (seen.has(k)) continue
    const none = meter(null, null, null, false)
    accounts.push({
      name: baseName(mine[0]?.configDir ?? k),
      plan: null,
      health: 'unknown',
      reason: 'no está en accounts.json',
      loginCommand: null,
      loginExpiresAt: null,
      fiveHour: none,
      weekly: none,
      fiveHourForecast: null,
      weeklyForecast: null,
      sessions: order(mine.map(b => sessionView(b, now, selfId))),
    })
  }
  return { accounts, snapshotAt: snapshot?.updatedAt ?? null, builtAt: now }
}

/** A pipeline status this old is no longer drawn. */
export const PIPELINE_SHOWN_MS = 12 * 3_600_000

/** pipeline.json (schema 1) when it is recent enough to draw, else null. */
export function parsePipeline(text: string, now: number): PipelineView | null {
  let doc: unknown
  try {
    doc = JSON.parse(text)
  } catch {
    return null
  }
  if (!isObj(doc) || doc.schema !== 1) return null
  const updatedAt = str(doc.updatedAt)
  const at = updatedAt ? Date.parse(updatedAt) : NaN
  if (!updatedAt || Number.isNaN(at) || now - at > PIPELINE_SHOWN_MS) return null
  const state = doc.state === 'running' || doc.state === 'waiting' || doc.state === 'done' || doc.state === 'stopped' ? doc.state : null
  if (!state) return null
  const roles = (Array.isArray(doc.roles) ? doc.roles : []).filter(isObj).map(r => ({
    role: str(r.role) ?? '?',
    account: str(r.account),
    task: str(r.task),
    outcome: str(r.outcome),
    status: str(r.status),
    reason: str(r.reason),
  }))
  return {
    repo: str(doc.repo) ?? '?',
    state,
    cycle: num(doc.cycle) ?? 0,
    maxCycles: num(doc.maxCycles) ?? 0,
    updatedAt,
    waitUntil: str(doc.waitUntil),
    message: str(doc.message),
    roles,
  }
}

// ---------------------------------------------------------------- formatting

/** A gauge of `width` cells: ▰ filled, ▱ empty. */
export function gauge(pct: number, width: number) {
  const full = Math.max(0, Math.min(width, Math.round((pct / 100) * width)))
  return { on: '▰'.repeat(full), off: '▱'.repeat(width - full) }
}

/** "3h12m", "45m", "40s". */
export function fmtSpan(ms: number) {
  const s = Math.max(0, Math.round(ms / 1000))
  if (s < 60) return `${s}s`
  const m = Math.floor(s / 60)
  if (m < 60) return `${m}m`
  const h = Math.floor(m / 60)
  if (h < 48) return `${h}h${String(m % 60).padStart(2, '0')}m`
  return `${Math.floor(h / 24)}d`
}

const pad2 = (n: number) => String(n).padStart(2, '0')
const DAYS = ['dom', 'lun', 'mar', 'mié', 'jue', 'vie', 'sáb']

/** "22:20" today, "lun 18:00" within a week, "27/11" further; in the local zone of `offsetMin`. */
export function fmtWhen(iso: string, now: number, offsetMin: number) {
  const t = Date.parse(iso)
  if (Number.isNaN(t)) return '?'
  const local = new Date(t - offsetMin * 60_000)
  const today = new Date(now - offsetMin * 60_000)
  const hm = `${pad2(local.getUTCHours())}:${pad2(local.getUTCMinutes())}`
  if (local.toISOString().slice(0, 10) === today.toISOString().slice(0, 10)) return hm
  if (t - now < 6 * 86_400_000 && t > now) return `${DAYS[local.getUTCDay()]} ${hm}`
  return `${pad2(local.getUTCDate())}/${pad2(local.getUTCMonth() + 1)}`
}

/** "A 44% · B login!" for the status line. */
export function statusText(fleet: Pick<FleetView, 'accounts'>): string | undefined {
  const parts = fleet.accounts.map(a => {
    if (a.health === 'logged-out') return `${a.name} login!`
    if (a.fiveHour.pct === null) return `${a.name} ?`
    return `${a.name} ${Math.round(a.fiveHour.pct)}%${a.health === 'at-cap' ? ' tope' : ''}`
  })
  return parts.length ? `fleet ${parts.join(' · ')}` : undefined
}

/** Toasts for an account whose health got worse since `before`. */
export function healthChanges(before: FleetView | null, after: Pick<FleetView, 'accounts'>): string[] {
  if (!before) return []
  const was = new Map(before.accounts.map(a => [a.name, a.health]))
  const out: string[] = []
  for (const a of after.accounts) {
    const prev = was.get(a.name)
    if (!prev || prev === a.health) continue
    if (a.health === 'logged-out') out.push(`Cuenta ${a.name}: login caducado`)
    else if (a.health === 'at-cap') out.push(`Cuenta ${a.name}: llegó a su tope (${a.reason})`)
    else if (a.health === 'ready' && (prev === 'at-cap' || prev === 'logged-out')) out.push(`Cuenta ${a.name}: disponible de nuevo`)
  }
  return out
}

/** A warning worth one toast: `id` names it so it is shown once, whichever session sees it first. */
export type Alert = { id: string; text: string }

const CAP_SOON_MS = 45 * 60_000
const WEEK_CAP_SOON_MS = 24 * 3_600_000
const LOGIN_SOON_MS = 3 * 86_400_000

/** Warnings ahead of time: a cap the pace reaches soon, a login that expires soon. */
export function alertsFor(accounts: AccountView[], now: number, offsetMin: number): Alert[] {
  const out: Alert[] = []
  // Ids name the window by its reset rounded to 5 minutes: a session reads it to the
  // millisecond, /usage to the minute, and both must name the same window.
  const windowOf = (iso: string | null) => (iso ? String(Math.round(Date.parse(iso) / 300_000)) : 'none')
  for (const a of accounts) {
    const five = a.fiveHourForecast
    if (a.health === 'ready' && five?.capAt && five.capAt - now < CAP_SOON_MS) {
      out.push({ id: `${a.name}:cap5:${windowOf(a.fiveHour.resetsAt)}`, text: `Cuenta ${a.name}: a este ritmo (${five.ratePerHour}%/h) llega a su tope de 5 h hacia las ${fmtWhen(new Date(five.capAt).toISOString(), now, offsetMin)}` })
    }
    const week = a.weeklyForecast
    if (a.health === 'ready' && week?.capAt && week.capAt - now < WEEK_CAP_SOON_MS) {
      out.push({ id: `${a.name}:capw:${windowOf(a.weekly.resetsAt)}`, text: `Cuenta ${a.name}: a este ritmo llega a su tope semanal ${fmtWhen(new Date(week.capAt).toISOString(), now, offsetMin)}` })
    }
    const expires = a.loginExpiresAt ? Date.parse(a.loginExpiresAt) : NaN
    if (!Number.isNaN(expires) && expires > now && expires - now < LOGIN_SOON_MS) {
      out.push({ id: `${a.name}:login:${a.loginExpiresAt}`, text: `Cuenta ${a.name}: el login caduca en ${fmtSpan(expires - now)}. Renuévalo con claude auth login.` })
    }
  }
  return out
}

/** "ritmo 12%/h → tope ~16:40" or "ritmo 5%/h → ~70% al reinicio"; null when steady or unknown. */
export function forecastText(f: AccountView['fiveHourForecast'], now: number, offsetMin: number): { text: string; isWarning: boolean } | null {
  if (!f || f.ratePerHour < 0.5) return null
  if (f.capAt) return { text: `ritmo ${f.ratePerHour}%/h → tope ~${fmtWhen(new Date(f.capAt).toISOString(), now, offsetMin)}`, isWarning: true }
  return { text: `ritmo ${f.ratePerHour}%/h → ~${f.atReset}% al reinicio`, isWarning: false }
}
