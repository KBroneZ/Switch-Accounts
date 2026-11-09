// The Deck: the Fleet pane as the desktop app (and the editor) draws it, laid out like Flightdeck.
// Account cards side by side with SVG gauges, a board of tasks (the hub's workers) ranked by
// priority with their controls, the pipeline, and the live sessions. The terminal keeps the text pane.
import type { Elements } from 'claude-code'

import type { AccountView, DeckView, FleetView, Forecast, Meter, PipelineView, ProviderView, SessionView, WorkerView } from '../types'
import { fmtSpan, fmtWhen, forecastText, shorten } from './core'
import { contextSvg, meterSvg, phaseLabel } from './deck-view'
import { PRIORITIES, PRIORITY_LABEL } from './hub-core'

/** What the Deck's controls do; register.tsx wires them to the engine. */
export type DeckActions = {
  refresh: () => void
  openSession: (account: string) => void
  send: (worker: string, text: string) => void
  askStop: (worker: string) => void
  stop: (worker: string) => void
  setPriority: (worker: string, priority: string) => void
  toggleForm: () => void
  openWorker: (draft: WorkerDraft) => void
  dismissNote: () => void
}

export type WorkerDraft = { account: string; name: string; directory: string; brief: string; model: string; effort: string; priority: string }

/** Text typed into the Deck's fields. Kept here, not in state: typing need not redraw the pane. */
export const drafts: { messages: Record<string, string>; sent: Record<string, number>; worker: WorkerDraft } = {
  messages: {},
  sent: {},
  worker: { account: '', name: '', directory: '', brief: '', model: '', effort: '', priority: 'media' },
}

export const EMPTY_DECK: DeckView = { note: null, isNoteError: false, busy: null, confirmStop: null, confirmAt: null, isFormOpen: false }

/** A first press of a stop button stays armed this long. */
export const CONFIRM_MS = 10_000

/** The elements the Deck draws with: the editor's table, which the desktop's contains. */
export type DeckElements = Elements['vscode']

const C = { main: 'claude', ok: 'success', warn: 'warning', bad: 'error', dim: 'inactive', faint: 'subtle', text: 'text', info: 'suggestion' } as const

/** Section colours, as Flightdeck's legend: accounts, tasks, sessions. */
const SECTION = { accounts: C.main, tasks: C.info, sessions: C.ok } as const

const MODELS = [
  { value: '', label: 'default model' },
  { value: 'opus', label: 'opus' },
  { value: 'sonnet', label: 'sonnet' },
  { value: 'haiku', label: 'haiku' },
  { value: 'fable', label: 'fable' },
]
const EFFORTS = [
  { value: '', label: 'default effort' },
  { value: 'low', label: 'low' },
  { value: 'medium', label: 'medium' },
  { value: 'high', label: 'high' },
  { value: 'xhigh', label: 'xhigh' },
  { value: 'max', label: 'max' },
]
// Option values are the stored priorities (alta/media/baja); only the labels are words.
const PRIORITY_MARK: Record<WorkerView['priority'], string> = { alta: '▲', media: '■', baja: '▼' }
const PRIORITY_OPTIONS = PRIORITIES.map(p => ({ value: p, label: `${PRIORITY_MARK[p]} ${PRIORITY_LABEL[p]}` }))
const PRIORITY_STYLE: Record<WorkerView['priority'], { mark: string; color: string }> = {
  alta: { mark: `${PRIORITY_MARK.alta} ${PRIORITY_LABEL.alta}`, color: C.bad },
  media: { mark: `${PRIORITY_MARK.media} ${PRIORITY_LABEL.media}`, color: C.warn },
  baja: { mark: `${PRIORITY_MARK.baja} ${PRIORITY_LABEL.baja}`, color: C.dim },
}

const PHASE_COLOR: Record<WorkerView['phase'], string> = {
  working: C.main,
  idle: C.dim,
  waiting: C.warn,
  handover: C.info,
  successor: C.info,
  starting: C.info,
  finished: C.ok,
  stopped: C.faint,
  gone: C.faint,
}

const PHASE_MARK: Record<WorkerView['phase'], string> = {
  working: '●',
  idle: '○',
  waiting: '◐',
  handover: '↻',
  successor: '↻',
  starting: '…',
  finished: '✓',
  stopped: '■',
  gone: '✕',
}

const projectedOf = (m: Meter, f: Forecast | null) => (f?.capAt ? (m.cap ?? 100) : (f?.atReset ?? null))
const isOpenTask = (w: WorkerView) => w.phase !== 'finished' && w.phase !== 'stopped' && w.phase !== 'gone'
const RULE = '─'.repeat(160)
/** Cards of a row: two side by side where the pane is wide enough. */
const HALF = '49%'

export function renderDeck(els: DeckElements, view: FleetView | null, deck: DeckView, t: number, act: DeckActions) {
  const { Box, Text, Button, Input, Select, Svg } = els
  const offset = new Date(t).getTimezoneOffset()
  const until = (iso: string) => fmtSpan(Date.parse(iso) - t)
  const when = (iso: string) => `${fmtWhen(iso, t, offset)} (${until(iso)})`
  const hub = view?.hub ?? null

  const rule = (key: string) => (
    <Text key={key} color={C.faint} wrap="truncate">
      {RULE}
    </Text>
  )

  const title = (
    <Box key="title" flexDirection="column" alignItems="center">
      <Text bold>
        <Text>FLEET DECK</Text>
        <Text color={C.dim}> · </Text>
        <Text color={C.main}>{hub ? `HUB ${hub.hubAccount}` : 'accounts'}</Text>
        {hub && !hub.isHub ? <Text color={C.dim}> (view only)</Text> : null}
      </Text>
      <Box columnGap={2}>
        <Text color={SECTION.accounts}>■ accounts</Text>
        <Text color={SECTION.tasks}>■ tasks</Text>
        <Text color={SECTION.sessions}>■ sessions</Text>
      </Box>
      <Box columnGap={1}>
        <Text color={C.dim}>
          {view?.isRefreshing ? 'reading usage…' : view?.snapshotAt ? `usage read ${fmtSpan(t - Date.parse(view.snapshotAt))} ago` : 'no usage data'}
        </Text>
        <Button key="refresh" plain hotkey="r" label="↻ refresh" onPress={act.refresh} />
      </Box>
    </Box>
  )
  if (!view) {
    return (
      <Box flexDirection="column" rowGap={1}>
        {title}
        <Text color={C.dim}>Loading…</Text>
      </Box>
    )
  }

  const note = deck.note ? (
    <Box key="note" justifyContent="space-between" columnGap={1} borderStyle="round" borderColor={deck.isNoteError ? C.bad : C.info} paddingX={1}>
      <Text color={deck.isNoteError ? C.bad : C.text} wrap="wrap">
        {deck.note}
      </Text>
      <Button key="note-close" plain label="✕" onPress={act.dismissNote} />
    </Box>
  ) : null

  // ------------------------------------------------------------ accounts

  const gauge = (label: string, m: Meter, f: Forecast | null) => {
    if (m.pct === null) {
      return (
        <Text color={C.dim}>
          {label.padEnd(3)} no data
        </Text>
      )
    }
    const line = forecastText(f, t, offset)
    return (
      <Box flexDirection="column">
        <Text>
          <Text color={C.dim}>{label.padEnd(3)} </Text>
          <Text bold>{`${Math.round(m.pct)}%`}</Text>
          <Text color={C.dim}>{m.cap !== null ? ` / ${Math.round(m.cap)}` : ''}</Text>
          <Text color={C.dim}>{m.resetsAt ? `  ↻${until(m.resetsAt)}` : ''}</Text>
          <Text color={C.faint}>{m.isLive ? '  live' : ''}</Text>
        </Text>
        <Svg source={meterSvg(m, projectedOf(m, f), 260, 10)} alt={`${label}: ${Math.round(m.pct)}%${m.cap !== null ? ` of a ${Math.round(m.cap)}% cap` : ''}`} />
        {line ? <Text color={line.isWarning ? C.warn : C.faint}>{line.text}</Text> : null}
      </Box>
    )
  }

  const chip = (a: AccountView) => {
    switch (a.health) {
      case 'ready':
        return <Text color={C.ok}>● ready</Text>
      case 'at-cap':
        return <Text color={C.warn}>◐ {a.reason}</Text>
      case 'logged-out':
        return <Text color={C.bad}>✗ login expired</Text>
      case 'not-ready':
        return <Text color={C.warn}>◌ {a.reason}</Text>
      default:
        return <Text color={C.dim}>? unknown</Text>
    }
  }

  const accountCard = (a: AccountView, index: number) => {
    const border = a.health === 'logged-out' ? C.bad : a.health === 'at-cap' ? C.warn : a.health === 'ready' ? SECTION.accounts : C.faint
    const working = a.sessions.filter(s => s.state === 'working').length
    const tasks = hub ? hub.workers.filter(w => w.account.toLowerCase() === a.name.toLowerCase() && isOpenTask(w)).length : 0
    const days = a.loginExpiresAt ? (Date.parse(a.loginExpiresAt) - t) / 86_400_000 : null
    const isHubAccount = hub !== null && hub.hubAccount.toLowerCase() === a.name.toLowerCase()
    return (
      <Box key={`acct-${a.name}`} flexDirection="column" borderStyle="round" borderColor={border} paddingX={1} width={HALF} flexGrow={1}>
        <Box justifyContent="space-between" columnGap={1}>
          <Text bold>
            <Text color={SECTION.accounts}>{a.name}</Text>
            <Text color={C.dim}>{a.plan ? ` · ${a.plan}` : ''}</Text>
            <Text color={C.dim}>{isHubAccount ? ' · hub' : ''}</Text>
          </Text>
          {chip(a)}
        </Box>
        {a.health === 'logged-out' ? (
          <Box flexDirection="column">
            <Text color={C.bad}>Sign in again in a terminal:</Text>
            <Text color={C.text}>{a.loginCommand ?? 'claude auth login'}</Text>
          </Box>
        ) : (
          <Box flexDirection="column">
            {gauge('5h', a.fiveHour, a.fiveHourForecast)}
            {gauge('7d', a.weekly, a.weeklyForecast)}
            {days !== null && days < 7 ? <Text color={days < 2 ? C.bad : C.warn}>login expires in {fmtSpan(Date.parse(a.loginExpiresAt!) - t)}</Text> : null}
          </Box>
        )}
        <Text color={C.dim}>
          {a.sessions.length} ses. · {working} working{hub ? ` · ${tasks} task${tasks === 1 ? '' : 's'}` : ''}
        </Text>
        {a.health === 'ready' ? (
          <Box>
            <Button key={`open-${a.name}`} plain {...(index < 9 ? { hotkey: String(index + 1) } : {})} label={`+ open session on ${a.name} here`} onPress={() => act.openSession(a.name)} />
          </Box>
        ) : null}
      </Box>
    )
  }

  const providerCard = (p: ProviderView) => {
    const border = p.health === 'at-cap' ? C.bad : p.isStale ? C.faint : C.info
    return (
      <Box key={`prov-${p.id}`} flexDirection="column" borderStyle="round" borderColor={border} paddingX={1} width={HALF} flexGrow={1}>
        <Box justifyContent="space-between" columnGap={1}>
          <Text bold>
            <Text color={C.info}>{p.name}</Text>
            <Text color={C.dim}>{p.plan ? ` · ${p.plan}` : ''}</Text>
            <Text color={C.dim}>{` · via ${p.source}`}</Text>
          </Text>
          {p.health === 'at-cap' ? <Text color={C.bad}>✗ limit</Text> : p.health === 'ready' ? <Text color={C.ok}>● available</Text> : <Text color={C.dim}>? no data</Text>}
        </Box>
        {p.windows.map(w =>
          w.pct === null ? (
            <Text key={`pw-${p.id}-${w.label}`} color={C.dim}>
              {w.label.padEnd(3)} reset, no new data
            </Text>
          ) : (
            <Box key={`pw-${p.id}-${w.label}`} flexDirection="column">
              <Text>
                <Text color={C.dim}>{w.label.padEnd(3)} </Text>
                <Text bold color={w.pct >= 100 ? C.bad : w.pct >= 90 ? C.warn : C.text}>{`${Math.round(w.pct)}%`}</Text>
                <Text color={C.dim}>{w.resetsAt ? `  ↻${until(w.resetsAt)} (${fmtWhen(w.resetsAt, t, offset)})` : ''}</Text>
              </Text>
              <Svg source={meterSvg({ pct: w.pct, cap: null, resetsAt: w.resetsAt, isLive: false }, null, 260, 10)} alt={`${p.name} ${w.label}: ${Math.round(w.pct)}%`} />
            </Box>
          ),
        )}
        <Text color={p.isStale ? C.warn : C.faint}>{p.readAt ? `read ${fmtSpan(t - p.readAt)} ago (${p.readNote})` : 'no read time'}</Text>
      </Box>
    )
  }

  // ------------------------------------------------------------ tasks

  const taskCard = (w: WorkerView, n: number, threshold: number, canAct: boolean) => {
    const confirming = deck.confirmStop === w.name && deck.confirmAt !== null && t - deck.confirmAt < CONFIRM_MS
    const sent = drafts.sent[w.name] ?? 0
    const prio = PRIORITY_STYLE[w.priority]
    const isOpen = isOpenTask(w)
    return (
      <Box key={`lane-${w.name}`} flexDirection="column" borderStyle="round" borderColor={isOpen ? SECTION.tasks : C.faint} paddingX={1} width={HALF} flexGrow={1}>
        <Box justifyContent="space-between" columnGap={1}>
          <Text bold wrap="truncate">
            <Text color={C.dim}>{` ${n} `}</Text>
            <Text color={isOpen ? C.text : C.dim}>{w.title ?? w.name}</Text>
          </Text>
          <Text color={prio.color}>{prio.mark}</Text>
        </Box>
        <Text color={C.dim} wrap="truncate">
          {[w.name, `account ${w.account}`, w.model, w.effort, `gen ${w.generation}`].filter(Boolean).join(' · ')}
        </Text>
        {w.ctxPct !== null && isOpen ? (
          <Box columnGap={1} alignItems="center">
            <Svg source={contextSvg(w.ctxPct, threshold, 140, 6)} alt={`context ${Math.round(w.ctxPct)}%, hand-over at ${threshold}%`} />
            <Text color={C.dim}>ctx {Math.round(w.ctxPct)}%</Text>
          </Box>
        ) : null}
        <Text color={PHASE_COLOR[w.phase]} wrap="truncate">
          {PHASE_MARK[w.phase]} {phaseLabel(w, when)}
          <Text color={C.dim}>{`  ${fmtSpan(t - w.since)}`}</Text>
          <Text color={C.dim}>{w.costUsd ? `  $${w.costUsd.toFixed(2)}` : ''}</Text>
        </Text>
        {w.lastReply ? (
          <Text color={C.faint} wrap="truncate">
            “{w.lastReply}”
          </Text>
        ) : null}
        {canAct && w.phase !== 'stopped' ? (
          <Box flexDirection="column">
            <Input
              // A new key after each send draws an empty field, whatever the field kept.
              key={sent ? `msg-${w.name}-${sent}` : `msg-${w.name}`}
              placeholder={`message for ${w.name}`}
              submitLabel="send"
              value={drafts.messages[w.name] ?? ''}
              onInput={(v: string) => {
                drafts.messages[w.name] = v
              }}
              onSubmit={(v: string) => act.send(w.name, v)}
            />
            <Box columnGap={1} justifyContent="space-between">
              <Select key={`prio-${w.name}`} options={PRIORITY_OPTIONS} value={w.priority} onSelect={(v: string) => act.setPriority(w.name, v)} />
              <Button key={`stop-${w.name}`} plain label={confirming ? `stop ${w.name}? press again` : 'stop'} onPress={() => (confirming ? act.stop(w.name) : act.askStop(w.name))} />
            </Box>
          </Box>
        ) : null}
      </Box>
    )
  }

  const form = (accounts: string[]) => {
    const d = drafts.worker
    // An account that left the list (or became the hub's) is never sent.
    if (!accounts.includes(d.account)) d.account = accounts[0] ?? ''
    if (!d.directory && hub?.cwd) d.directory = hub.cwd
    return (
      <Box key="new-worker" flexDirection="column" borderStyle="round" borderColor={SECTION.tasks} paddingX={1}>
        <Text bold color={SECTION.tasks}>
          New task
        </Text>
        {accounts.length === 0 ? (
          <Text color={C.warn}>No work accounts: they are all the hub's.</Text>
        ) : (
          <Box flexDirection="column">
            <Box columnGap={1}>
              <Select key="nw-account" label="account" options={accounts.map(a => ({ value: a, label: a }))} value={d.account} onSelect={(v: string) => (d.account = v)} />
              <Select key="nw-priority" label="priority" options={PRIORITY_OPTIONS} value={d.priority} onSelect={(v: string) => (d.priority = v)} />
            </Box>
            <Input key="nw-name" label="name" placeholder="w1" value={d.name} onInput={(v: string) => (d.name = v)} onSubmit={(v: string) => (d.name = v)} />
            <Input key="nw-dir" label="folder" value={d.directory} onInput={(v: string) => (d.directory = v)} onSubmit={(v: string) => (d.directory = v)} />
            <Input key="nw-brief" label="brief" rows={4} placeholder="First line: the title. Then: what to do, how far, and how it knows it is done" value={d.brief} onInput={(v: string) => (d.brief = v)} onSubmit={(v: string) => (d.brief = v)} />
            <Box columnGap={1}>
              <Select key="nw-model" options={MODELS} value={d.model} onSelect={(v: string) => (d.model = v)} />
              <Select key="nw-effort" options={EFFORTS} value={d.effort} onSelect={(v: string) => (d.effort = v)} />
            </Box>
            <Box columnGap={1}>
              <Button key="nw-open" label={deck.busy === 'open' ? 'opening…' : 'open worker'} onPress={() => act.openWorker({ ...d })} />
              <Button key="nw-cancel" plain label="cancel" onPress={act.toggleForm} />
            </Box>
            <Text color={C.faint}>Opens in a terminal tab of that account. Never the hub's, never auto.</Text>
          </Box>
        )}
      </Box>
    )
  }

  const tasksSection = () => {
    if (!hub) return null
    if (!hub.isHub && hub.workers.length === 0) return null
    const open = hub.workers.filter(isOpenTask).length
    const workAccounts = view.accounts.map(a => a.name).filter(n => n.toLowerCase() !== hub.hubAccount.toLowerCase())
    return (
      <Box key="tasks" flexDirection="column" rowGap={0}>
        <Box justifyContent="space-between" columnGap={1}>
          <Text bold>
            <Text color={SECTION.tasks}>tasks</Text>
            <Text color={C.dim}>{` · ${open} open · ${hub.workers.length} total`}</Text>
          </Text>
          {hub.isHub && !deck.isFormOpen ? <Button key="nw-toggle" plain label="+ new task" onPress={act.toggleForm} /> : null}
        </Box>
        {hub.isHub ? null : <Text color={C.dim}>The controls are in the sessions of account {hub.hubAccount}.</Text>}
        {hub.isHub && deck.isFormOpen ? form(workAccounts) : null}
        {hub.workers.length === 0 && hub.isHub ? <Text color={C.faint}>No tasks. Open one with “+ new task” or ask the hub in the chat.</Text> : null}
        <Box flexDirection="row" flexWrap="wrap" columnGap={1} rowGap={1}>
          {hub.workers.map((w, i) => taskCard(w, i + 1, hub.rolloverPercent, hub.isHub))}
        </Box>
      </Box>
    )
  }

  // ------------------------------------------------------------ pipeline and sessions

  const pipeline = (p: PipelineView) => {
    const color = p.state === 'running' ? C.main : p.state === 'waiting' ? C.warn : p.state === 'stopped' ? C.bad : C.dim
    const label = { running: '● running', waiting: '◐ waiting for reset', done: '✓ done', stopped: '✗ stopped' }[p.state]
    return (
      <Box key="pipeline" flexDirection="column" borderStyle="round" borderColor={color} paddingX={1}>
        <Box justifyContent="space-between" columnGap={1}>
          <Text bold>
            <Text color={C.main}>PIPELINE</Text>
            <Text color={C.dim}>{` · ${p.repo} · cycle ${p.cycle}/${p.maxCycles}`}</Text>
          </Text>
          <Text color={color}>{label}</Text>
        </Box>
        {p.roles.map(role => (
          <Text key={`role-${role.role}`} color={C.text} wrap="truncate">
            {role.role === 'implementer' ? 'A implements' : 'B reviews'}
            <Text color={C.dim}>{` · task ${role.task ?? '—'} · ${[role.outcome, role.status].filter(Boolean).join(' ')}`}</Text>
          </Text>
        ))}
        {p.waitUntil ? <Text color={C.warn}>retries {fmtWhen(p.waitUntil, t, offset)}</Text> : null}
        {p.message ? <Text color={C.dim}>{p.message}</Text> : null}
      </Box>
    )
  }

  const sessionRow = (s: SessionView, account: string) => {
    const isWorking = s.state === 'working'
    const dot = s.liveness === 'quiet' ? '◌' : isWorking ? '●' : s.state === 'ended' ? '✕' : '○'
    const what = isWorking ? (s.tool ? `${s.tool}${s.detail ? `: ${s.detail}` : ''}` : 'thinking') : s.state === 'ended' ? 'closed' : s.lastReply ? `idle · “${s.lastReply}”` : 'idle'
    const meta = [s.model ? s.model.replace(/^claude-/, '').replace(/-\d{8}$/, '') : null, s.ctxPct !== null ? `ctx ${Math.round(s.ctxPct)}%` : null, s.costUsd ? `$${s.costUsd.toFixed(2)}` : null, fmtSpan(t - s.stateSince)]
      .filter(Boolean)
      .join(' · ')
    return (
      <Box key={`ses-${s.id}`} flexDirection="column">
        <Box justifyContent="space-between" columnGap={1}>
          <Text color={isWorking ? SECTION.sessions : C.dim} bold={isWorking} wrap="truncate">
            {dot} <Text color={SECTION.accounts}>{account}</Text> {s.worker ? `[${s.worker}] ` : ''}
            {s.place}
            {s.isSelf ? ' (this)' : ''}
            {s.quotaAccount ? <Text color={C.warn}>{` · uses quota of ${s.quotaAccount}`}</Text> : null}
          </Text>
          <Text color={C.dim}>{meta}</Text>
        </Box>
        <Text color={isWorking ? C.text : C.dim} wrap="truncate">
          {'   '}
          {what}
        </Text>
      </Box>
    )
  }

  const sessionsSection = () => {
    const rows = view.accounts.flatMap(a => a.sessions.slice(0, 8).map(s => ({ s, account: a.name })))
    if (rows.length === 0) return null
    const busy = rows.filter(r => r.s.state === 'working').length
    return (
      <Box key="sessions" flexDirection="column" borderStyle="round" borderColor={SECTION.sessions} paddingX={1}>
        <Text bold>
          <Text color={SECTION.sessions}>sessions</Text>
          <Text color={C.dim}>{` · ${rows.length} live · ${busy} working`}</Text>
        </Text>
        {rows.map(r => sessionRow(r.s, r.account))}
      </Box>
    )
  }

  return (
    <Box flexDirection="column" rowGap={1}>
      {title}
      {note}
      {view.error ? (
        <Text color={C.bad} wrap="wrap">
          {view.error}
        </Text>
      ) : null}
      {view.accounts.length === 0 ? <Text color={C.dim}>No accounts. Press refresh or run /fleet refresh.</Text> : null}
      <Box key="accounts" flexDirection="row" flexWrap="wrap" columnGap={1} rowGap={1}>
        {view.accounts.map(accountCard)}
        {(view.providers ?? []).map(providerCard)}
      </Box>
      {rule('rule-1')}
      {tasksSection()}
      {view.pipeline ? pipeline(view.pipeline) : null}
      {rule('rule-2')}
      {sessionsSection()}
    </Box>
  )
}
