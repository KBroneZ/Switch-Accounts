// Pure pieces of the Deck (the desktop pane): the hub workers as it draws them, and its SVG gauges.
// No engine calls here, so the tests reach every branch.
import type { Beat, Meter, WorkerPhase, WorkerView } from '../types'
import { isShown } from './core'
import { owesSuccessor } from './hub-core'
import type { WorkerRecord } from './hub-core'

/** A worker with no session yet is "starting" this long after its open, then "gone". */
export const STARTING_MS = 5 * 60_000

/** The latest shown heartbeat of the worker's current generation, if any. */
export function currentBeat(record: WorkerRecord, beats: Beat[], now: number): Beat | null {
  const mine = beats.filter(b => b.worker === record.name && b.startedAt >= record.openedAt && isShown(b, now))
  return mine.sort((a, b) => b.startedAt - a.startedAt)[0] ?? null
}

/** The latest heartbeat of the current generation, shown or not (a closed tab's last word). */
export function lastBeat(record: WorkerRecord, beats: Beat[]): Beat | null {
  const mine = beats.filter(b => b.worker === record.name && b.startedAt >= record.openedAt)
  return mine.sort((a, b) => b.updatedAt - a.updatedAt)[0] ?? null
}

export function workerPhase(record: WorkerRecord, beat: Beat | null, hubAccount: string, now: number, last: Beat | null = null): WorkerPhase {
  if (record.state === 'stopped') return 'stopped'
  if (owesSuccessor(record, hubAccount)) return 'successor'
  // A worker that finished and closed its tab is done, not gone.
  if (!beat && last?.finished) return 'finished'
  if (!beat) return now - record.openedAt < STARTING_MS ? 'starting' : 'gone'
  if (beat.finished) return 'finished'
  if (beat.waitingUntil) return 'waiting'
  if (beat.rollover !== 'none') return 'handover'
  if (beat.state === 'ended') return 'gone'
  return beat.state === 'working' ? 'working' : 'idle'
}

const PHASE_ORDER: Record<WorkerPhase, number> = {
  working: 0,
  handover: 1,
  successor: 2,
  starting: 3,
  waiting: 4,
  idle: 5,
  finished: 6,
  gone: 7,
  stopped: 8,
}

const PRIORITY_ORDER: Record<WorkerView['priority'], number> = { alta: 0, media: 1, baja: 2 }
const isOpenPhase = (p: WorkerPhase) => p !== 'finished' && p !== 'stopped' && p !== 'gone'

/** A brief's first line that says something, as the task's title. */
export function briefTitle(brief: string | null): string | null {
  const line = (brief ?? '').split(/\r?\n/).map(l => l.replace(/^[#>*\-\s]+/, '').trim()).find(Boolean)
  return line ? (line.length > 90 ? `${line.slice(0, 89)}…` : line) : null
}

/** Every worker record with its current session: open tasks first, then by priority, phase and name. */
export function buildWorkers(records: WorkerRecord[], beats: Beat[], hubAccount: string, now: number, briefs: Map<string, string> = new Map()): WorkerView[] {
  return records
    .map(record => {
      const beat = currentBeat(record, beats, now)
      const last = beat ?? lastBeat(record, beats)
      const phase = workerPhase(record, beat, hubAccount, now, last)
      const view: WorkerView = {
        name: record.name,
        title: briefTitle(briefs.get(record.name) ?? null),
        priority: record.priority,
        account: record.account,
        directory: record.directory,
        model: record.model,
        effort: record.effort,
        generation: record.generation,
        phase,
        since: beat ? beat.stateSince : (last?.updatedAt ?? record.openedAt),
        tool: beat?.tool ?? null,
        detail: beat?.detail ?? null,
        ctxPct: beat?.ctxPct ?? null,
        costUsd: beat?.costUsd ?? null,
        waitingUntil: beat?.waitingUntil ?? null,
        lastReply: last?.lastReply ?? null,
      }
      return view
    })
    .sort(
      (a, b) =>
        Number(isOpenPhase(b.phase)) - Number(isOpenPhase(a.phase)) ||
        PRIORITY_ORDER[a.priority] - PRIORITY_ORDER[b.priority] ||
        PHASE_ORDER[a.phase] - PHASE_ORDER[b.phase] ||
        a.name.localeCompare(b.name),
    )
}

// ------------------------------------------------------------ SVG

/** Mid-tone colours that read on the light and the dark theme alike (the SVG is drawn as an image). */
export const PALETTE = { ok: '#2ea043', warn: '#d29922', bad: '#e5534b', accent: '#d97757', track: '#8b949e', mark: '#8b949e' } as const

const clamp = (n: number) => Math.max(0, Math.min(100, n))
const fmt = (n: number) => (Math.round(n * 10) / 10).toString()

export function meterColor(pct: number, cap: number | null): string {
  if (cap !== null && pct >= cap) return PALETTE.bad
  if (cap !== null && pct >= cap - 10) return PALETTE.warn
  return PALETTE.ok
}

/**
 * A usage bar: the use so far, a fainter stretch to where the recent pace takes it by the reset
 * (`projected`), and a tick at the cap.
 */
export function meterSvg(m: Meter, projected: number | null, width = 320, height = 12): string {
  const pct = clamp(m.pct ?? 0)
  const x = (p: number) => fmt((clamp(p) / 100) * width)
  const color = meterColor(pct, m.cap)
  const r = height / 2
  const parts = [
    `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height + 4}" viewBox="0 0 ${width} ${height + 4}">`,
    `<rect x="0" y="2" width="${width}" height="${height}" rx="${r}" fill="${PALETTE.track}" fill-opacity="0.22"/>`,
  ]
  if (projected !== null && projected > pct) {
    const end = clamp(projected)
    parts.push(`<rect x="0" y="2" width="${x(end)}" height="${height}" rx="${r}" fill="${meterColor(end, m.cap)}" fill-opacity="0.3"/>`)
  }
  if (pct > 0) parts.push(`<rect x="0" y="2" width="${x(pct)}" height="${height}" rx="${r}" fill="${color}"/>`)
  if (m.cap !== null && m.cap < 100) parts.push(`<rect x="${x(m.cap)}" y="0" width="2" height="${height + 4}" fill="${PALETTE.mark}"/>`)
  parts.push('</svg>')
  return parts.join('')
}

/** A thin context bar with a tick at the hand-over threshold. */
export function contextSvg(ctxPct: number | null, threshold: number, width = 160, height = 6): string {
  const pct = clamp(ctxPct ?? 0)
  const x = (p: number) => fmt((clamp(p) / 100) * width)
  const color = pct >= threshold ? PALETTE.warn : PALETTE.accent
  return [
    `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height + 4}" viewBox="0 0 ${width} ${height + 4}">`,
    `<rect x="0" y="2" width="${width}" height="${height}" rx="${height / 2}" fill="${PALETTE.track}" fill-opacity="0.22"/>`,
    pct > 0 ? `<rect x="0" y="2" width="${x(pct)}" height="${height}" rx="${height / 2}" fill="${color}"/>` : '',
    `<rect x="${x(threshold)}" y="0" width="2" height="${height + 4}" fill="${PALETTE.mark}"/>`,
    '</svg>',
  ].join('')
}

/** The words of a phase, for the lane's chip. */
export function phaseLabel(w: WorkerView, when: (iso: string) => string): string {
  switch (w.phase) {
    case 'working':
      return w.tool ? `trabajando · ${w.tool}${w.detail ? `: ${w.detail}` : ''}` : 'pensando'
    case 'idle':
      return 'en espera'
    case 'waiting':
      return w.waitingUntil ? `esperando reinicio · ${when(w.waitingUntil)}` : 'esperando reinicio'
    case 'handover':
      return 'escribiendo relevo'
    case 'successor':
      return 'relevo pendiente: se abre cuando su cuenta esté lista'
    case 'starting':
      return 'abriendo…'
    case 'finished':
      return 'encargo terminado'
    case 'stopped':
      return 'parado'
    default:
      return 'sin sesión'
  }
}
