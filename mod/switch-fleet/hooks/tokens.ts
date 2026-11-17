// Token counts in the Fleet pane: ~/.claude-switch/tokens.json, written by token-ledger.ps1 from
// an append-only ledger of every Claude message and Codex session, summed here per account for
// today, this week (from Monday), this month and all time, with what they would cost at API
// prices. Pure logic; register.tsx runs the script and reads the file.
import type { FleetView, TokenCounts, TokenPeriods, TokenSource, TokensView } from '../types'
import { fmtSpan } from './core'

/** USD per million tokens. A null cache-write price leaves those tokens unpriced, never $0. */
export type Price = { input: number; cacheWrite5m: number | null; cacheWrite1h: number | null; cacheRead: number; output: number }

const p = (input: number, cacheWrite5m: number | null, cacheWrite1h: number | null, cacheRead: number, output: number): Price => ({ input, cacheWrite5m, cacheWrite1h, cacheRead, output })

/**
 * API prices, standard tier, for comparison only (the accounts are subscriptions).
 *
 * Anthropic: https://platform.claude.com/docs/en/about-claude/pricing, read 2026-11-17. Fast mode
 * (`@fast`) is its own base price with the same caching multipliers on top; Haiku 5.5 over 100,000
 * prompt tokens (`@long`) has its own row. US-only inference (1.1x) is not applied: the
 * transcripts read `global` or `not_available`.
 *
 * OpenAI (Codex): https://developers.openai.com/api/docs/pricing, read 2026-11-17, short context
 * (Codex's 258K window stays under the 272K threshold). Codex does not say which cache window a
 * write used: priced as a 30-minute write.
 */
export const PRICES: Readonly<Record<string, Price>> = {
  'claude-fable-5-2': p(8, 10, 16, 0.2, 40),
  'claude-mythos-5-2': p(8, 10, 16, 0.2, 40),
  'claude-fable-5-2@fast': p(16, 20, 32, 0.4, 80),
  'claude-mythos-5-2@fast': p(16, 20, 32, 0.4, 80),
  'claude-fable-5-1': p(10, 12.5, 20, 0.25, 50),
  'claude-mythos-5-1': p(10, 12.5, 20, 0.25, 50),
  'claude-fable-5': p(10, 12.5, 20, 1, 50),
  'claude-mythos-5': p(10, 12.5, 20, 1, 50),
  'claude-opus-5-5': p(4, 5, 8, 0.2, 20),
  'claude-opus-5-5@fast': p(8, 10, 16, 0.4, 40),
  'claude-opus-5': p(5, 6.25, 10, 0.5, 25),
  'claude-opus-5@fast': p(10, 12.5, 20, 1, 50),
  'claude-opus-4-8': p(5, 6.25, 10, 0.5, 25),
  'claude-opus-4-8@fast': p(10, 12.5, 20, 1, 50),
  'claude-opus-4-7': p(5, 6.25, 10, 0.5, 25),
  'claude-opus-4-6': p(5, 6.25, 10, 0.5, 25),
  'claude-opus-4-5': p(5, 6.25, 10, 0.5, 25),
  'claude-opus-4-1': p(15, 18.75, 30, 1.5, 75),
  'claude-opus-4': p(15, 18.75, 30, 1.5, 75),
  'claude-sonnet-5-5': p(2, 2.5, 4, 0.1, 10),
  'claude-sonnet-5': p(2, 2.5, 4, 0.2, 10),
  'claude-sonnet-4-6': p(3, 3.75, 6, 0.3, 15),
  'claude-sonnet-4-5': p(3, 3.75, 6, 0.3, 15),
  'claude-sonnet-4': p(3, 3.75, 6, 0.3, 15),
  'claude-haiku-5-5': p(0.1, 0.125, 0.2, 0.01, 0.5),
  'claude-haiku-5-5@long': p(0.5, 0.625, 1, 0.05, 2.5),
  'claude-haiku-4-5': p(1, 1.25, 2, 0.1, 5),
  'gpt-6-astra': p(10, 12.5, null, 1, 50),
  'gpt-6-sol': p(2, 2.5, null, 0.2, 10),
  'gpt-6-luna': p(0.1, 0.125, null, 0.01, 0.5),
  'gpt-6.1-sol': p(2, 2.5, null, 0.1, 10),
  'gpt-6.1-terra': p(1, 1.25, null, 0.05, 5),
  'gpt-5.5': p(5, null, null, 0.5, 30),
  'gpt-5.3-codex': p(1.75, null, null, 0.175, 14),
  'gpt-5': p(1.25, null, null, 0.125, 10),
}

/** One row of tokens.json: one local day, account and model. */
export type TokenDay = { d: string; a: string; m: string; i: number; o: number; w5: number; w1: number; r: number }

export type TokenSummary = { updatedAt: string | null; isComplete: boolean; sources: TokenSource[]; days: TokenDay[]; notes: string[] }

const isObj = (v: unknown): v is Record<string, unknown> => typeof v === 'object' && v !== null && !Array.isArray(v)
const count = (v: unknown) => (typeof v === 'number' && Number.isFinite(v) && v >= 0 ? Math.floor(v) : null)
const DAY = /^\d{4}-\d{2}-\d{2}$/
/** What the ledger writes for an account or model name; anything else is not drawn. */
const NAME = /^[A-Za-z0-9 ._@:/-]{1,80}$/
/** Control characters (ESC included) never reach the terminal. */
export const plainText = (text: string, max = 200) => text.replace(/[\u0000-\u001f\u007f-\u009f]+/g, ' ').trim().slice(0, max)

/** tokens.json (schema 1), or null when it is not that. Rows that do not parse are skipped. */
export function parseTokens(text: string): TokenSummary | null {
  let doc: unknown
  try {
    doc = JSON.parse(text)
  } catch {
    return null
  }
  if (!isObj(doc) || doc.schema !== 1 || !Array.isArray(doc.days)) return null
  const days: TokenDay[] = []
  for (const r of doc.days) {
    if (!isObj(r) || typeof r.d !== 'string' || !DAY.test(r.d) || typeof r.a !== 'string' || !NAME.test(r.a) || typeof r.m !== 'string' || !NAME.test(r.m)) continue
    const [i, o, w5, w1, rd] = [count(r.i), count(r.o), count(r.w5), count(r.w1), count(r.r)]
    if (i === null || o === null || w5 === null || w1 === null || rd === null) continue
    days.push({ d: r.d, a: r.a, m: r.m, i, o, w5, w1, r: rd })
  }
  const sources = (Array.isArray(doc.sources) ? doc.sources : [])
    .filter(isObj)
    .filter(s => typeof s.account === 'string' && NAME.test(s.account))
    .map(s => ({ account: String(s.account), kind: s.kind === 'codex' ? ('codex' as const) : ('claude' as const) }))
  return {
    updatedAt: typeof doc.updatedAt === 'string' ? doc.updatedAt : null,
    isComplete: doc.isComplete === true,
    sources,
    days,
    notes: (Array.isArray(doc.notes) ? doc.notes : []).filter((n): n is string => typeof n === 'string').map(n => plainText(n)).filter(Boolean),
  }
}

/** The price of a model id: a date suffix (`-20251001`) dropped, `@fast`/`@long` kept. */
export function priceOf(model: string): Price | null {
  const [base, tier] = model.split('@')
  const id = (base ?? '').replace(/-\d{8}$/, '')
  return PRICES[tier ? `${id}@${tier}` : id] ?? null
}

/** What one row would cost at API prices, or null when its model (or one of its token kinds) has no price. */
export function costOf(day: Pick<TokenDay, 'm' | 'i' | 'o' | 'w5' | 'w1' | 'r'>): number | null {
  const price = priceOf(day.m)
  if (!price) return null
  if ((day.w5 > 0 && price.cacheWrite5m === null) || (day.w1 > 0 && price.cacheWrite1h === null)) return null
  const perToken = (n: number, usd: number | null) => (n === 0 ? 0 : (n * (usd ?? 0)) / 1_000_000)
  return perToken(day.i, price.input) + perToken(day.o, price.output) + perToken(day.w5, price.cacheWrite5m) + perToken(day.w1, price.cacheWrite1h) + perToken(day.r, price.cacheRead)
}

export const EMPTY_COUNTS: TokenCounts = { input: 0, output: 0, cacheWrite: 0, cacheRead: 0, total: 0, usd: 0, unpricedTokens: 0 }

function add(c: TokenCounts, d: TokenDay): TokenCounts {
  const total = d.i + d.o + d.w5 + d.w1 + d.r
  const usd = costOf(d)
  return {
    input: c.input + d.i,
    output: c.output + d.o,
    cacheWrite: c.cacheWrite + d.w5 + d.w1,
    cacheRead: c.cacheRead + d.r,
    total: c.total + total,
    usd: (c.usd ?? 0) + (usd ?? 0),
    unpricedTokens: c.unpricedTokens + (usd === null ? total : 0),
  }
}

/** The local day of `t` (yyyy-mm-dd), in the zone of `offsetMin` (Date#getTimezoneOffset). */
export function localDay(t: number, offsetMin: number): string {
  return new Date(t - offsetMin * 60_000).toISOString().slice(0, 10)
}

/** Today, the Monday that starts this week, and this month's prefix, as local days. */
export function periodBounds(now: number, offsetMin: number) {
  const today = localDay(now, offsetMin)
  const weekday = (new Date(`${today}T00:00:00Z`).getUTCDay() + 6) % 7
  return { today, weekStart: localDay(now - weekday * 86_400_000, offsetMin), month: today.slice(0, 7) }
}

export function periodsOf(days: TokenDay[], now: number, offsetMin: number): TokenPeriods {
  const b = periodBounds(now, offsetMin)
  let out: TokenPeriods = { today: EMPTY_COUNTS, week: EMPTY_COUNTS, month: EMPTY_COUNTS, all: EMPTY_COUNTS }
  for (const d of days) {
    out = {
      today: d.d === b.today ? add(out.today, d) : out.today,
      week: d.d >= b.weekStart && d.d <= b.today ? add(out.week, d) : out.week,
      month: d.d.startsWith(b.month) ? add(out.month, d) : out.month,
      all: add(out.all, d),
    }
  }
  return out
}

/** What the pane draws: per account (accounts.json's names, other config dirs, ChatGPT) and the total. */
export function buildTokens(summary: TokenSummary, now: number, offsetMin: number): TokensView {
  const names = [...new Set([...summary.sources.map(s => s.account), ...summary.days.map(d => d.a)])]
  const kindOf = new Map(summary.sources.map(s => [s.account, s.kind]))
  const firstDay = (rows: TokenDay[]) => rows.reduce<string | null>((min, d) => (min === null || d.d < min ? d.d : min), null)
  const byAccount = names.map(name => {
    const rows = summary.days.filter(d => d.a === name)
    return { name, kind: kindOf.get(name) ?? ('claude' as const), periods: periodsOf(rows, now, offsetMin), since: firstDay(rows) }
  })
  const unknownModels = [...new Set(summary.days.filter(d => costOf(d) === null).map(d => d.m))].sort()
  return {
    updatedAt: summary.updatedAt,
    isComplete: summary.isComplete,
    notes: summary.notes,
    byAccount,
    total: periodsOf(summary.days, now, offsetMin),
    since: firstDay(summary.days),
    unknownModels,
  }
}

// ---------------------------------------------------------------- formatting

const UNITS = ['', 'k', 'M', 'B', 'T'] as const

/** 999, 1.2k, 12k, 3.4M, 120M, 5.6B: one decimal below 10 of a unit, none above. */
export function fmtTokens(n: number): string {
  if (!Number.isFinite(n) || n < 0) return '?'
  let unit = 0
  let v = n
  while (v >= 1000 && unit < UNITS.length - 1) {
    v /= 1000
    unit++
  }
  if (unit === 0) return String(Math.round(v))
  let text = v < 10 ? (Math.round(v * 10) / 10).toFixed(1).replace(/\.0$/, '') : String(Math.round(v))
  // 999.6k rounds to 1000k: that is 1M.
  if (Number(text) >= 1000 && unit < UNITS.length - 1) {
    unit++
    text = '1'
  }
  return `${text}${UNITS[unit]}`
}

/** $0.42, $12, $3.4k, $1.2M; `?` when nothing could be priced, a trailing `+?` when part was not. */
export function fmtUsd(c: Pick<TokenCounts, 'usd' | 'unpricedTokens' | 'total'>): string {
  if (c.total > 0 && c.unpricedTokens === c.total) return '$?'
  const usd = c.usd ?? 0
  const money = usd < 10 ? `$${usd.toFixed(2)}` : usd < 1000 ? `$${Math.round(usd)}` : `$${fmtTokens(usd)}`
  return c.unpricedTokens > 0 ? `${money}+?` : money
}

export const TOKEN_HEAD = ['in', 'out', 'c.wr', 'c.rd', 'total', 'API $'] as const
export const PERIOD_LABELS = [
  ['today', 'today'],
  ['week', 'week'],
  ['month', 'month'],
  ['all', 'all'],
] as const

/** The table's cells: one row per period, input, output, cache write, cache read, total and cost. */
export function tokenRows(p: TokenPeriods): { label: string; cells: string[] }[] {
  return PERIOD_LABELS.map(([key, label]) => {
    const c = p[key]
    return { label, cells: [fmtTokens(c.input), fmtTokens(c.output), fmtTokens(c.cacheWrite), fmtTokens(c.cacheRead), fmtTokens(c.total), fmtUsd(c)] }
  })
}

const LABEL_W = 6
const CELL_W = 6

/** The table as fixed-width lines for the terminal: a heading, then today, week, month, all. */
export function tokenLines(p: TokenPeriods): string[] {
  const line = (label: string, cells: readonly string[]) => [label.padEnd(LABEL_W), ...cells.map(c => c.padStart(CELL_W))].join(' ')
  return [line('tokens', TOKEN_HEAD), ...tokenRows(p).map(r => line(r.label, r.cells))]
}

/** The table as Markdown for the desktop and the editor. */
export function tokenMarkdown(p: TokenPeriods): string {
  const rows = tokenRows(p).map(r => `| ${r.label} | ${r.cells.join(' | ')} |`)
  return [`| tokens | ${TOKEN_HEAD.join(' | ')} |`, `|:--|${TOKEN_HEAD.map(() => '--:').join('|')}|`, ...rows].join('\n')
}

/** The account's tokens, matched by name ignoring case (ChatGPT's are its Codex sessions). */
export function tokensOf(view: TokensView | null | undefined, name: string) {
  return view?.byAccount.find(a => a.name.toLowerCase() === name.toLowerCase()) ?? null
}

/** Token sources with no card of their own (a config dir accounts.json no longer lists). */
export function otherTokenAccounts(v: TokensView, view: Pick<FleetView, 'accounts' | 'providers'>) {
  const carded = new Set([...view.accounts.map(a => a.name.toLowerCase()), ...(view.providers ?? []).map(p => p.name.toLowerCase())])
  return v.byAccount.filter(a => !carded.has(a.name.toLowerCase()))
}

/** "since 29/07/2026" from the first local day counted. */
export const sinceText = (day: string | null) => (day ? `since ${day.slice(8, 10)}/${day.slice(5, 7)}/${day.slice(0, 4)}` : '')

/** How old the count is, whether the first one has finished, and what the dollars are. */
export function tokensFooter(v: TokensView, t: number) {
  const age = v.updatedAt ? `counted ${fmtSpan(t - Date.parse(v.updatedAt))} ago` : 'not counted yet'
  return `${age}${v.isComplete ? '' : ' · first count still going'} · API $ for comparison only`
}
