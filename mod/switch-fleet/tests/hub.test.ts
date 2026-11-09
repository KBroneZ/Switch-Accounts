import { describe, expect, test } from 'claude-code/testing'

import type { Beat } from '../types'
import {
  appendInbox,
  compactStatus,
  inboxPrompt,
  lastInboxSeq,
  limitStop,
  needsSuccessor,
  parseInbox,
  parseWorker,
  pendingMessages,
  resumeAt,
  RESUME_GRACE_MS,
  rolloverPrompt,
  shouldRollover,
  workerStartPrompt,
  isWorkerAccount,
} from '../hooks/hub-core'
import type { WorkerRecord } from '../hooks/hub-core'

const NOW = Date.parse('2030-01-01T12:00:00Z')

const beat = (over: Partial<Beat>): Beat => ({
  schema: 1,
  sessionId: 's1',
  configDir: 'C:/Users/me/.claude-account3',
  cwd: 'C:/src/app',
  repo: 'app',
  model: null,
  state: 'idle',
  tool: null,
  detail: null,
  prompt: null,
  ctxPct: 20,
  costUsd: null,
  limits: null,
  limitsAt: null,
  worker: 'w1',
  rollover: 'none',
  rolloverAt: null,
  waitingUntil: null,
  lastReply: null,
  finished: false,
  turns: 1,
  startedAt: NOW,
  stateSince: NOW,
  updatedAt: NOW,
  ...over,
})

const record = (over: Partial<WorkerRecord>): WorkerRecord => ({
  schema: 1,
  name: 'w1',
  account: 'B',
  directory: 'C:/src/app',
  model: null,
  effort: null,
  generation: 1,
  state: 'active',
  openedAt: NOW - 60_000,
  claimedBy: null,
  mailFrom: 0,
  createdAt: NOW,
  updatedAt: NOW,
  ...over,
})

describe('worker records', () => {
  test('reads a record and refuses odd names', () => {
    expect(parseWorker(JSON.stringify(record({})))?.account).toBe('B')
    expect(parseWorker(JSON.stringify(record({ name: '-x' })))).toBeNull()
    expect(parseWorker(JSON.stringify(record({ account: 'B; rm' })))).toBeNull()
    expect(parseWorker(JSON.stringify(record({ account: 'auto' })))).toBeNull()
    expect(parseWorker(JSON.stringify(record({ directory: 'relative/dir' })))).toBeNull()
    expect(parseWorker(JSON.stringify(record({ model: '-bad' })))).toBeNull()
    expect(parseWorker('nope')).toBeNull()
  })
})

describe('mailbox', () => {
  test('numbers messages on from the highest and hands out only the new ones', () => {
    let box = appendInbox('', 'hub', 'first', NOW)
    expect(box.seq).toBe(1)
    box = appendInbox(box.text, 'hub', 'second', NOW + 1)
    expect(box.seq).toBe(2)
    const all = parseInbox(`${box.text}garbage\n`)
    expect(all.map(m => m.text)).toEqual(['first', 'second'])
    expect(pendingMessages(all, 1).map(m => m.seq)).toEqual([2])
    expect(inboxPrompt(pendingMessages(all, 0))).toContain('(2) second')
  })

  test('a reopened worker skips mail left for its earlier run', () => {
    let box = appendInbox('', 'hub', 'stop please', NOW)
    const mailFrom = lastInboxSeq(box.text)
    expect(mailFrom).toBe(1)
    expect(parseWorker(JSON.stringify(record({ mailFrom })))?.mailFrom).toBe(1)
    expect(parseWorker(JSON.stringify({ ...record({}), mailFrom: undefined }))?.mailFrom).toBe(0)
    box = appendInbox(box.text, 'hub', 'new task', NOW + 1)
    expect(pendingMessages(parseInbox(box.text), Math.max(0, mailFrom)).map(m => m.text)).toEqual(['new task'])
  })
})

describe('limits and hand-over', () => {
  test('a window at its limit stops the worker until the later reset', () => {
    const limits = { fiveHour: 100, fiveHourResetsAt: '2030-01-01T15:00:00Z', weekly: 100, weeklyResetsAt: '2030-01-03T09:00:00Z' }
    const fresh = { limitsAt: NOW - 1_000 }
    expect(limitStop(beat({ limits, ...fresh }), NOW)).toBe('2030-01-03T09:00:00Z')
    expect(limitStop(beat({ limits: { ...limits, weekly: 40 }, ...fresh }), NOW)).toBe('2030-01-01T15:00:00Z')
    expect(limitStop(beat({ limits: { ...limits, fiveHour: 99, weekly: 40 }, ...fresh }), NOW)).toBeNull()
  })

  test('a stale reading or a reset already past never makes a worker wait (no resume loop)', () => {
    const limits = { fiveHour: 100, fiveHourResetsAt: '2030-01-01T11:00:00Z', weekly: 10, weeklyResetsAt: null }
    expect(limitStop(beat({ limits, limitsAt: NOW - 1_000 }), NOW)).toBeNull()
    const future = { ...limits, fiveHourResetsAt: '2030-01-01T15:00:00Z' }
    expect(limitStop(beat({ limits: future, limitsAt: NOW - 10 * 60_000 }), NOW)).toBeNull()
    expect(limitStop(beat({ limits: future, limitsAt: null }), NOW)).toBeNull()
    expect(resumeAt('2030-01-01T15:00:00Z')).toBe(Date.parse('2030-01-01T15:00:00Z') + RESUME_GRACE_MS)
  })

  test('asks for a hand-over once, at the threshold', () => {
    expect(shouldRollover(39, 40, 'none')).toBe(false)
    expect(shouldRollover(40, 40, 'none')).toBe(true)
    expect(shouldRollover(55, 40, 'requested')).toBe(false)
    expect(shouldRollover(null, 40, 'none')).toBe(false)
    expect(rolloverPrompt(41, 'D:/w', 'w1')).toContain('D:/w/w1.handover.md')
  })

  test('a successor is due for a ready worker of the current generation only', () => {
    const ready = beat({ rollover: 'ready' })
    expect(needsSuccessor(ready, record({}), 'A')).toBe(true)
    // Its successor was opened after it started: this old heartbeat never asks again.
    expect(needsSuccessor(ready, record({ generation: 2, openedAt: NOW + 1 }), 'A')).toBe(false)
    expect(needsSuccessor(ready, record({ state: 'stopped' }), 'A')).toBe(false)
    expect(needsSuccessor(beat({ rollover: 'ready', state: 'working' }), record({}), 'A')).toBe(false)
    expect(needsSuccessor(beat({ rollover: 'requested' }), record({}), 'A')).toBe(false)
    expect(needsSuccessor(beat({ rollover: 'requested', state: 'ended' }), record({}), 'A')).toBe(true)
    expect(needsSuccessor(ready, null, 'A')).toBe(false)
  })

  test('two old generations still on disk never ask for more successors (no duplicates)', () => {
    // gen1 started at NOW, gen2 was opened at NOW + 10 min and is now the current generation.
    const gen1 = beat({ sessionId: 'g1', rollover: 'ready', startedAt: NOW })
    const gen2 = beat({ sessionId: 'g2', rollover: 'ready', startedAt: NOW + 11 * 60_000 })
    const current = record({ generation: 2, openedAt: NOW + 10 * 60_000 })
    expect([gen1, gen2].filter(b => needsSuccessor(b, current, 'A')).map(b => b.sessionId)).toEqual(['g2'])
  })

  test('never on the hub account or auto, whatever the record says', () => {
    const ready = beat({ rollover: 'ready' })
    expect(needsSuccessor(ready, record({ account: 'A' }), 'A')).toBe(false)
    expect(needsSuccessor(ready, record({ account: 'a' }), 'A')).toBe(false)
    expect(isWorkerAccount('auto', 'A')).toBe(false)
    expect(isWorkerAccount('B', 'A')).toBe(true)
  })

  test('a successor is told to read the hand-over first', () => {
    expect(workerStartPrompt('w1', 'B', 'D:/w', 1)).not.toContain('handover')
    expect(workerStartPrompt('w1', 'B', 'D:/w', 2)).toContain('D:/w/w1.handover.md')
    expect(workerStartPrompt('w1', 'B', 'D:/w', 2)).toContain('D:/w/w1.brief.md')
  })
})

describe('hub status', () => {
  test('one line per account and per session, with the hub-mode state', () => {
    const text = compactStatus(
      [{ name: 'B', health: 'ready', reason: null, fiveHour: { pct: 30, cap: 100, resetsAt: '2030-01-01T15:00:00Z' }, weekly: { pct: 5 } }],
      [beat({ state: 'working', tool: 'Bash', detail: 'npm test', ctxPct: 41, rollover: 'requested', updatedAt: NOW - 3_000 })],
      () => 'B',
      NOW,
    )
    expect(text.split('\n')).toEqual([
      'cuenta B: ready · 5h 30%/100 · semana 5% reinicio 2030-01-01T15:00:00Z',
      'worker w1 · [B] · app · working · Bash: npm test · ctx 41% · relevo requested · hace 3s',
    ])
  })
})
