// Hub mode, worker side: what a session started with SWITCH_FLEET_WORKER does on its own.
// Every prompt it gives itself waits for an idle session and goes out from the poll timer,
// never from inside a turn's own hook. State moves on only once a prompt has gone out.
import type { EngineInterface } from 'claude-code'

import type { Beat } from '../types'
import { maskSecrets, shorten } from './core'
import {
  handoverPath,
  inboxPrompt,
  isDoneReply,
  isHandoverReply,
  limitStop,
  parseInbox,
  parseWorker,
  pendingMessages,
  RESUME_PROMPT,
  resumeAt,
  rolloverPrompt,
  shouldRollover,
  WORKER_NAME,
} from './hub-core'
import { S, setBeat } from './shared'

const lastSeqKey = (name: string) => `inbox:${name}`

/** A prompt the worker owes itself (the hand-over request), and whether one is on its way. */
const W: { pending: string | null; isSubmitting: boolean } = { pending: null, isSubmitting: false }

/** The worker name of this session, from the tab that started it; null for any other session. */
export async function workerName($: EngineInterface): Promise<string | null> {
  const raw = ((await $.env.get('SWITCH_FLEET_WORKER')) ?? '').trim()
  return WORKER_NAME.test(raw) ? raw : null
}

/**
 * What a reload keeps: the heartbeat this session wrote before carries its start time and the
 * worker's hand-over and wait, which module state loses. A pending hand-over prompt is owed again.
 */
export function carryOver(previous: Beat | null, fresh: Beat): Beat {
  if (!previous || previous.sessionId !== fresh.sessionId) return fresh
  const kept: Beat = {
    ...fresh,
    startedAt: previous.startedAt,
    turns: previous.turns,
    rollover: previous.rollover,
    rolloverAt: previous.rolloverAt,
    waitingUntil: previous.waitingUntil,
    lastReply: previous.lastReply,
    finished: previous.finished,
  }
  if (kept.worker && kept.rollover === 'requested' && S.paths && kept.ctxPct !== null) {
    W.pending = rolloverPrompt(kept.ctxPct, S.paths.workers, kept.worker)
  }
  return kept
}

/** After a main-loop turn: note the reply, then a finished task, a limit stop, or a hand-over. */
export async function workerTurnDone($: EngineInterface, reply: string) {
  const beat = S.beat
  if (!beat?.worker || !S.paths) return
  const now = await $.clock.now()
  const firstLine = reply.trim().split(/\r?\n/)[0] ?? ''
  const lastReply = firstLine ? shorten(maskSecrets(firstLine), 140) : beat.lastReply
  if (isDoneReply(reply)) {
    // Done: no hand-over, no resume. It still takes the hub's mail, which may bring more work.
    await setBeat($, { lastReply, finished: true, waitingUntil: null }, true)
    return
  }
  const stop = limitStop(beat, now)
  if (stop) {
    // The account is at its limit: this worker waits for its own reset, then goes on.
    await setBeat($, { lastReply, waitingUntil: stop, finished: false }, true)
    return
  }
  if (beat.rollover === 'requested') {
    // Ready only once the hand-over is written: its file is newer than the request, or the
    // worker said so in the words it was asked to use.
    const stat = await $.fs.stat(handoverPath(S.paths.workers, beat.worker)).catch(() => null)
    const written = (stat !== null && beat.rolloverAt !== null && stat.mtimeMs >= beat.rolloverAt) || isHandoverReply(reply)
    await setBeat($, written ? { lastReply, rollover: 'ready' } : { lastReply }, true)
    return
  }
  if (shouldRollover(beat.ctxPct, S.cfg.rolloverPercent, beat.rollover)) {
    W.pending = rolloverPrompt(beat.ctxPct ?? S.cfg.rolloverPercent, S.paths.workers, beat.worker)
    await setBeat($, { lastReply, rollover: 'requested', rolloverAt: now, finished: false }, true)
    return
  }
  await setBeat($, { lastReply, finished: false }, false)
}

/** One poll of an idle worker: resume after a reset, then its own pending prompt, then the hub's mail. */
export async function workerTick($: EngineInterface) {
  const beat = S.beat
  if (!beat?.worker || !S.paths || beat.state !== 'idle' || W.isSubmitting) return
  const now = await $.clock.now()
  if (beat.waitingUntil) {
    if (now < resumeAt(beat.waitingUntil)) return
    // A hand-over asked for before the stop is still owed: ask for it again, not for more work.
    const owed = beat.rollover === 'requested' && beat.ctxPct !== null ? rolloverPrompt(beat.ctxPct, S.paths.workers, beat.worker) : null
    if (await submit($, owed ?? RESUME_PROMPT)) {
      W.pending = null
      await setBeat($, { waitingUntil: null }, true)
    }
    return
  }
  if (W.pending) {
    const text = W.pending
    if (await submit($, text)) W.pending = null
    return
  }
  // Once it asked for a successor, the mail is the successor's.
  if (beat.rollover !== 'none') return
  const text = await $.fs.read(`${S.paths.inbox}/${beat.worker}.jsonl`).then(String, () => null)
  if (!text) return
  const stored = await $.store.get(lastSeqKey(beat.worker)).catch(() => 0)
  const record = await $.fs.read(`${S.paths.workers}/${beat.worker}.json`).then(String, () => '')
  const mailFrom = parseWorker(record)?.mailFrom ?? 0
  const lastSeq = Math.max(typeof stored === 'number' ? stored : 0, mailFrom)
  const fresh = pendingMessages(parseInbox(text), lastSeq)
  if (fresh.length === 0) return
  if (await submit($, inboxPrompt(fresh))) {
    await $.store.set(lastSeqKey(beat.worker), fresh[fresh.length - 1]!.seq)
    if (beat.finished) await setBeat($, { finished: false }, false)
  }
}

/** True once the prompt is queued; false (and nothing changed) when the engine refused it. */
async function submit($: EngineInterface, text: string): Promise<boolean> {
  W.isSubmitting = true
  try {
    await $.prompt.submit({ text })
    return true
  } catch (err) {
    S.lastError = shorten(`Fleet worker: could not send the prompt (${String(err)})`, 200)
    return false
  } finally {
    W.isSubmitting = false
  }
}
