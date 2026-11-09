// Hub mode, pure logic: worker records, the mailbox, and when a worker hands over or resumes.
// The hub (a session of the hub account) opens workers on other accounts; each worker keeps to
// its own account: it hands over to a fresh session of the same account when its context fills,
// and waits for its own account's reset when that account is at its limit. Work never moves to
// another account to get around a limit.
import type { Beat } from '../types'

export const WORKER_NAME = /^[A-Za-z0-9][A-Za-z0-9._-]{0,29}$/
export const ACCOUNT_NAME = /^[A-Za-z0-9][A-Za-z0-9._-]{0,29}$/
export const MODEL = /^(opus|sonnet|haiku|fable|claude-[a-z0-9.-]{1,60})$/
export const EFFORT = /^(low|medium|high|xhigh|max)$/
export const ABSOLUTE_PATH = /^([A-Za-z]:[\\/]|\/)/
/** A turn that ends with a window at or above this is read as stopped by the limit. */
export const LIMIT_PERCENT = 100
/** Resume a little after the reset, so the new window is really open. */
export const RESUME_GRACE_MS = 90_000
/** A limit reading older than this says nothing about the turn that just ended. */
export const FRESH_LIMITS_MS = 2 * 60_000
export const MAX_BRIEF = 20_000
export const MAX_MESSAGE = 4_000
export const DONE_MARK = 'ENCARGO TERMINADO'
export const HANDOVER_MARK = 'RELEVO LISTO'

export type WorkerRecord = {
  schema: 1
  name: string
  account: string
  directory: string
  model: string | null
  effort: string | null
  generation: number
  state: 'active' | 'stopped'
  /** When the current generation was opened: older sessions of this worker never ask again. */
  openedAt: number
  /** The hub session that last claimed this record, to settle two hubs racing. */
  claimedBy: string | null
  /** Inbox messages up to this sequence predate the worker's latest fresh open and are never delivered. */
  mailFrom: number
  createdAt: number
  updatedAt: number
}

export type InboxMessage = { seq: number; at: number; from: string; text: string }

const isObj = (v: unknown): v is Record<string, unknown> => typeof v === 'object' && v !== null && !Array.isArray(v)
const str = (v: unknown) => (typeof v === 'string' && v.length > 0 ? v : null)
const numOr = (v: unknown, d: number) => (typeof v === 'number' && Number.isFinite(v) ? v : d)

/** Whether an account may carry workers: a real name, never auto, never the hub's. */
export const isWorkerAccount = (account: string, hubAccount: string) =>
  ACCOUNT_NAME.test(account) && account.toLowerCase() !== 'auto' && account.toLowerCase() !== hubAccount.toLowerCase()

/** A record from disk, every field checked again: the file may have been edited by hand. */
export function parseWorker(text: string): WorkerRecord | null {
  let d: unknown
  try {
    d = JSON.parse(text)
  } catch {
    return null
  }
  if (!isObj(d) || d.schema !== 1) return null
  const name = str(d.name)
  const account = str(d.account)
  const directory = str(d.directory)
  const model = str(d.model)
  const effort = str(d.effort)
  if (!name || !WORKER_NAME.test(name) || !account || !ACCOUNT_NAME.test(account) || account.toLowerCase() === 'auto') return null
  if (!directory || !ABSOLUTE_PATH.test(directory) || /[\r\n]/.test(directory)) return null
  if ((model && !MODEL.test(model)) || (effort && !EFFORT.test(effort))) return null
  return {
    schema: 1,
    name,
    account,
    directory,
    model,
    effort,
    generation: Math.max(1, Math.floor(numOr(d.generation, 1))),
    state: d.state === 'stopped' ? 'stopped' : 'active',
    openedAt: numOr(d.openedAt, 0),
    claimedBy: str(d.claimedBy),
    mailFrom: Math.max(0, Math.floor(numOr(d.mailFrom, 0))),
    createdAt: numOr(d.createdAt, 0),
    updatedAt: numOr(d.updatedAt, 0),
  }
}

/** inbox/<worker>.jsonl, oldest first; lines that do not parse are skipped. */
export function parseInbox(text: string): InboxMessage[] {
  const out: InboxMessage[] = []
  for (const line of text.split(/\r?\n/)) {
    if (!line.trim()) continue
    try {
      const d: unknown = JSON.parse(line)
      if (isObj(d) && typeof d.seq === 'number' && typeof d.text === 'string') {
        out.push({ seq: d.seq, at: numOr(d.at, 0), from: str(d.from) ?? 'hub', text: d.text })
      }
    } catch {
      // skip
    }
  }
  return out.sort((a, b) => a.seq - b.seq)
}

/** The inbox with one more message; the sequence goes on from the highest one there. */
export function appendInbox(existing: string, from: string, text: string, at: number): { text: string; seq: number } {
  const seq = lastInboxSeq(existing) + 1
  const line = JSON.stringify({ seq, at, from, text })
  const body = existing.trim() ? `${existing.replace(/\s+$/, '')}\n${line}\n` : `${line}\n`
  return { text: body, seq }
}

/** The highest sequence in an inbox, 0 when empty. */
export const lastInboxSeq = (text: string) => parseInbox(text).reduce((m, x) => Math.max(m, x.seq), 0)

/** Messages a worker has not taken yet. */
export const pendingMessages = (inbox: InboxMessage[], lastSeq: number) => inbox.filter(m => m.seq > lastSeq)

/**
 * The reset this account waits for now, if a window is at its limit: the later of those resets.
 * Only a fresh reading counts, and only a reset still to come.
 */
export function limitStop(beat: Pick<Beat, 'limits' | 'limitsAt'>, now: number): string | null {
  const l = beat.limits
  if (!l || beat.limitsAt === null || now - beat.limitsAt > FRESH_LIMITS_MS) return null
  const stops = [
    l.fiveHour !== null && l.fiveHour >= LIMIT_PERCENT ? l.fiveHourResetsAt : null,
    l.weekly !== null && l.weekly >= LIMIT_PERCENT ? l.weeklyResetsAt : null,
  ].filter((x): x is string => !!x && !Number.isNaN(Date.parse(x)) && Date.parse(x) > now)
  if (stops.length === 0) return null
  return stops.sort((a, b) => Date.parse(b) - Date.parse(a))[0] ?? null
}

/** When a waiting worker may go on: its reset plus a grace period. */
export const resumeAt = (waitingUntil: string) => Date.parse(waitingUntil) + RESUME_GRACE_MS

export const startsWithMark = (reply: string, mark: string) => reply.trim().toUpperCase().startsWith(mark)

export const shouldRollover = (ctxPct: number | null, rolloverPercent: number, rollover: Beat['rollover']) =>
  rollover === 'none' && ctxPct !== null && ctxPct >= rolloverPercent

/**
 * A worker's heartbeat that asks for a successor: ready (hand-over written), or closed while
 * writing it. Only a session of the current generation counts (started after it was opened),
 * so the heartbeats of earlier generations, which stay on disk, never ask again.
 */
export function needsSuccessor(beat: Beat, record: WorkerRecord | null, hubAccount: string): boolean {
  if (!beat.worker || !record || record.state !== 'active' || beat.worker !== record.name) return false
  if (!isWorkerAccount(record.account, hubAccount)) return false
  if (beat.startedAt < record.openedAt) return false
  const wantsIt = beat.rollover === 'ready' || (beat.rollover === 'requested' && beat.state === 'ended')
  return wantsIt && beat.state !== 'working'
}

export const briefPath = (workersDir: string, name: string) => `${workersDir}/${name}.brief.md`
export const handoverPath = (workersDir: string, name: string) => `${workersDir}/${name}.handover.md`

/** The first prompt of a worker session (the brief itself stays in its file). */
export function workerStartPrompt(name: string, account: string, workersDir: string, generation: number): string {
  const brief = briefPath(workersDir, name)
  const handover = handoverPath(workersDir, name)
  const first = `Eres el worker ${name} del hub de Fleet, en la cuenta ${account}. Lee tu encargo en ${brief} y trabaja en él hasta terminarlo.`
  const relay = generation > 1 ? ` Eres el relevo número ${generation}: si existe ${handover}, léelo primero (lo dejó tu predecesor) y sigue desde ahí.` : ''
  const rules = ` Los mensajes del hub te llegarán como prompts. Cuando el encargo esté terminado del todo, responde con una línea que empiece por ${DONE_MARK}.`
  return first + relay + rules
}

export function rolloverPrompt(ctxPct: number, workersDir: string, name: string): string {
  return (
    `Fleet: tu contexto va por el ${Math.round(ctxPct)} %. Termina el paso en curso sin empezar nada nuevo y escribe el relevo en ` +
    `${handoverPath(workersDir, name)}: qué hiciste, qué queda y en qué orden, ramas, PRs y comandos útiles, y decisiones abiertas. ` +
    `Cuando esté escrito, responde solo: ${HANDOVER_MARK}. Una sesión nueva de tu misma cuenta seguirá desde ese archivo.`
  )
}

export const RESUME_PROMPT = 'Fleet: la ventana de uso de tu cuenta se ha reiniciado. Sigue con tu encargo donde lo dejaste.'

export function inboxPrompt(messages: InboxMessage[]): string {
  const body = messages.map(m => (messages.length > 1 ? `(${m.seq}) ${m.text}` : m.text)).join('\n\n')
  return `Mensaje del hub de Fleet:\n\n${body}`
}

/** One line per account and session, short enough for the hub to read every few minutes. */
export function compactStatus(
  accounts: { name: string; health: string; reason: string | null; fiveHour: { pct: number | null; cap: number | null; resetsAt: string | null }; weekly: { pct: number | null } }[],
  beats: Beat[],
  accountOf: (configDir: string) => string,
  now: number,
): string {
  const lines: string[] = []
  for (const a of accounts) {
    const five = a.fiveHour.pct === null ? '?' : `${Math.round(a.fiveHour.pct)}%/${a.fiveHour.cap ?? '-'}`
    const reset = a.fiveHour.resetsAt ? ` reinicio ${a.fiveHour.resetsAt}` : ''
    lines.push(`cuenta ${a.name}: ${a.health}${a.reason ? ` (${a.reason})` : ''} · 5h ${five} · semana ${a.weekly.pct === null ? '?' : `${Math.round(a.weekly.pct)}%`}${reset}`)
  }
  for (const b of beats) {
    const age = Math.round((now - b.updatedAt) / 1000)
    const parts = [
      b.worker ? `worker ${b.worker}` : 'sesión',
      `[${accountOf(b.configDir)}]`,
      b.repo ?? b.cwd,
      b.finished ? 'encargo terminado' : b.state,
      b.tool ? `${b.tool}${b.detail ? `: ${b.detail}` : ''}` : null,
      b.ctxPct !== null ? `ctx ${Math.round(b.ctxPct)}%` : null,
      b.rollover !== 'none' ? `relevo ${b.rollover}` : null,
      b.waitingUntil ? `espera hasta ${b.waitingUntil}` : null,
      b.lastReply ? `última respuesta: «${b.lastReply}»` : null,
      `hace ${age}s`,
    ].filter(Boolean)
    lines.push(parts.join(' · '))
  }
  return lines.join('\n')
}
