// The Deck: the Fleet pane as the desktop app (and the editor) draws it. SVG gauges per account,
// a lane per hub worker with its controls, and the live sessions. The terminal keeps the text pane.
import type { Elements } from 'claude-code'

import type { AccountView, DeckView, FleetView, Forecast, Meter, PipelineView, SessionView, WorkerView } from '../types'
import { fmtSpan, fmtWhen, forecastText, shorten } from './core'
import { contextSvg, meterSvg, phaseLabel } from './deck-view'

/** What the Deck's controls do; register.tsx wires them to the engine. */
export type DeckActions = {
  refresh: () => void
  openSession: (account: string) => void
  send: (worker: string, text: string) => void
  askStop: (worker: string) => void
  stop: (worker: string) => void
  toggleForm: () => void
  openWorker: (draft: WorkerDraft) => void
  dismissNote: () => void
}

export type WorkerDraft = { account: string; name: string; directory: string; brief: string; model: string; effort: string }

/** Text typed into the Deck's fields. Kept here, not in state: typing need not redraw the pane. */
export const drafts: { messages: Record<string, string>; worker: WorkerDraft } = {
  messages: {},
  worker: { account: '', name: '', directory: '', brief: '', model: '', effort: '' },
}

export const EMPTY_DECK: DeckView = { note: null, isNoteError: false, busy: null, confirmStop: null, isFormOpen: false }

const C = { main: 'claude', ok: 'success', warn: 'warning', bad: 'error', dim: 'inactive', faint: 'subtle', text: 'text', info: 'suggestion' } as const

const MODELS = [
  { value: '', label: 'modelo por defecto' },
  { value: 'opus', label: 'opus' },
  { value: 'sonnet', label: 'sonnet' },
  { value: 'haiku', label: 'haiku' },
  { value: 'fable', label: 'fable' },
]
const EFFORTS = [
  { value: '', label: 'esfuerzo por defecto' },
  { value: 'low', label: 'low' },
  { value: 'medium', label: 'medium' },
  { value: 'high', label: 'high' },
  { value: 'xhigh', label: 'xhigh' },
  { value: 'max', label: 'max' },
]

const projectedOf = (m: Meter, f: Forecast | null) => (f?.capAt ? (m.cap ?? 100) : (f?.atReset ?? null))

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

/** The elements the Deck draws with: the editor's table, which the desktop's contains. */
export type DeckElements = Elements['vscode']

export function renderDeck(els: DeckElements, view: FleetView | null, deck: DeckView, t: number, act: DeckActions) {
  const { Box, Text, Button, Input, Select, Svg } = els
  const offset = new Date(t).getTimezoneOffset()
  const when = (iso: string) => `${fmtWhen(iso, t, offset)} (${fmtSpan(Date.parse(iso) - t)})`

  const header = (
    <Box justifyContent="space-between" columnGap={1}>
      <Text color={C.main} bold>
        FLEET DECK
      </Text>
      <Box flexShrink={0} columnGap={1}>
        <Text color={C.dim}>
          {view?.isRefreshing ? 'leyendo uso…' : view?.snapshotAt ? `uso hace ${fmtSpan(t - Date.parse(view.snapshotAt))}` : 'sin datos de uso'}
        </Text>
        <Button key="refresh" hotkey="r" label="actualizar" onPress={act.refresh} />
      </Box>
    </Box>
  )
  if (!view) {
    return (
      <Box flexDirection="column">
        {header}
        <Text color={C.dim}>Cargando…</Text>
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

  const meter = (label: string, m: Meter, f: Forecast | null) => {
    if (m.pct === null) return <Text color={C.dim}>{label} · sin dato</Text>
    const line = forecastText(f, t, offset)
    const reset = m.resetsAt ? `↻ ${when(m.resetsAt)}` : ''
    return (
      <Box flexDirection="column">
        <Box justifyContent="space-between" columnGap={1}>
          <Text color={C.dim}>{label}</Text>
          <Text>
            <Text bold>{`${Math.round(m.pct)}%`}</Text>
            <Text color={C.dim}>{m.cap !== null ? ` / tope ${Math.round(m.cap)}%` : ''}</Text>
            <Text color={C.dim}>{reset ? `  ${reset}` : ''}</Text>
          </Text>
        </Box>
        <Svg source={meterSvg(m, projectedOf(m, f))} alt={`${label}: ${Math.round(m.pct)}%${m.cap !== null ? ` de un tope de ${Math.round(m.cap)}%` : ''}`} />
        {line ? <Text color={line.isWarning ? C.warn : C.dim}>{line.text}</Text> : null}
      </Box>
    )
  }

  const healthChip = (a: AccountView) => {
    switch (a.health) {
      case 'ready':
        return <Text color={C.ok}>● lista</Text>
      case 'at-cap':
        return <Text color={C.warn}>◐ {a.reason}</Text>
      case 'logged-out':
        return <Text color={C.bad}>✗ login caducado</Text>
      case 'not-ready':
        return <Text color={C.warn}>◌ {a.reason}</Text>
      default:
        return <Text color={C.dim}>? desconocido</Text>
    }
  }

  const session = (s: SessionView) => {
    const isWorking = s.state === 'working'
    const dot = s.liveness === 'quiet' ? '◌' : isWorking ? '●' : s.state === 'ended' ? '✕' : '○'
    const what = isWorking ? (s.tool ? `${s.tool}${s.detail ? `: ${s.detail}` : ''}` : 'pensando') : s.state === 'ended' ? 'cerrada' : s.lastReply ? `en espera · «${s.lastReply}»` : 'en espera'
    const meta = [s.model ? s.model.replace(/^claude-/, '').replace(/-\d{8}$/, '') : null, s.ctxPct !== null ? `ctx ${Math.round(s.ctxPct)}%` : null, s.costUsd ? `$${s.costUsd.toFixed(2)}` : null, fmtSpan(t - s.stateSince)]
      .filter(Boolean)
      .join(' · ')
    return (
      <Box key={`ses-${s.id}`} flexDirection="column">
        <Box justifyContent="space-between" columnGap={1}>
          <Text color={isWorking ? C.main : C.dim} bold={isWorking} wrap="truncate">
            {dot} {s.worker ? `[${s.worker}] ` : ''}
            {s.place}
            {s.isSelf ? ' (esta)' : ''}
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

  const card = (a: AccountView, index: number) => {
    const border = a.health === 'logged-out' ? C.bad : a.health === 'at-cap' ? C.warn : a.health === 'ready' ? C.main : C.faint
    const working = a.sessions.filter(s => s.state === 'working').length
    const days = a.loginExpiresAt ? (Date.parse(a.loginExpiresAt) - t) / 86_400_000 : null
    return (
      <Box key={`acct-${a.name}`} flexDirection="column" borderStyle="round" borderColor={border} paddingX={1} rowGap={0}>
        <Box justifyContent="space-between" columnGap={1}>
          <Text bold>
            <Text color={C.main}>{a.name}</Text>
            <Text color={C.dim}>{a.plan ? ` · ${a.plan}` : ''}</Text>
            <Text color={C.dim}>{a.sessions.length ? ` · ${a.sessions.length} ses.${working ? `, ${working} activa${working > 1 ? 's' : ''}` : ''}` : ''}</Text>
          </Text>
          {healthChip(a)}
        </Box>
        {a.health === 'logged-out' ? (
          <Box flexDirection="column">
            <Text color={C.bad}>Inicia sesión otra vez en una terminal:</Text>
            <Text color={C.text}>{a.loginCommand ?? 'claude auth login'}</Text>
          </Box>
        ) : (
          <Box flexDirection="column">
            {meter('5 h', a.fiveHour, a.fiveHourForecast)}
            {meter('semana', a.weekly, a.weeklyForecast)}
            {days !== null && days < 7 ? <Text color={days < 2 ? C.bad : C.warn}>login caduca en {fmtSpan(Date.parse(a.loginExpiresAt!) - t)}</Text> : null}
          </Box>
        )}
        {a.health === 'ready' ? (
          <Box>
            <Button key={`open-${a.name}`} plain {...(index < 9 ? { hotkey: String(index + 1) } : {})} label={`+ abrir sesión en ${a.name} aquí`} onPress={() => act.openSession(a.name)} />
          </Box>
        ) : null}
        {a.sessions.slice(0, 6).map(session)}
        {a.sessions.length > 6 ? <Text color={C.dim}>+{a.sessions.length - 6} más</Text> : null}
      </Box>
    )
  }

  const lane = (w: WorkerView, threshold: number, canAct: boolean) => {
    const isLive = w.phase !== 'stopped' && w.phase !== 'gone'
    const confirming = deck.confirmStop === w.name
    return (
      <Box key={`lane-${w.name}`} flexDirection="column" borderStyle="single" borderColor={PHASE_COLOR[w.phase]} paddingX={1}>
        <Box justifyContent="space-between" columnGap={1}>
          <Text bold wrap="truncate">
            <Text color={C.main}>{w.name}</Text>
            <Text color={C.dim}>{` · cuenta ${w.account} · relevo ${w.generation}${w.model ? ` · ${w.model}` : ''}`}</Text>
          </Text>
          <Text color={C.dim}>{[w.ctxPct !== null ? `ctx ${Math.round(w.ctxPct)}%` : null, w.costUsd ? `$${w.costUsd.toFixed(2)}` : null, fmtSpan(t - w.since)].filter(Boolean).join(' · ')}</Text>
        </Box>
        <Text color={PHASE_COLOR[w.phase]} wrap="truncate">
          {phaseLabel(w, when)}
        </Text>
        {w.ctxPct !== null && isLive ? <Svg source={contextSvg(w.ctxPct, threshold)} alt={`contexto ${Math.round(w.ctxPct)}%, relevo al ${threshold}%`} /> : null}
        {w.lastReply ? (
          <Text color={C.dim} wrap="truncate">
            «{w.lastReply}»
          </Text>
        ) : null}
        <Text color={C.faint} wrap="truncate">
          {shorten(w.directory, 80)}
        </Text>
        {canAct && w.phase !== 'stopped' ? (
          <Box flexDirection="column">
            <Input
              key={`msg-${w.name}`}
              placeholder={`mensaje para ${w.name}`}
              submitLabel="enviar"
              value={drafts.messages[w.name] ?? ''}
              onInput={(v: string) => {
                drafts.messages[w.name] = v
              }}
              onSubmit={(v: string) => act.send(w.name, v)}
            />
            <Box columnGap={1}>
              <Button key={`stop-${w.name}`} plain label={confirming ? `¿parar ${w.name}? pulsa otra vez` : 'parar'} onPress={() => (confirming ? act.stop(w.name) : act.askStop(w.name))} />
            </Box>
          </Box>
        ) : null}
      </Box>
    )
  }

  const form = (accounts: string[]) => {
    const d = drafts.worker
    if (!d.account && accounts[0]) d.account = accounts[0]
    if (!d.directory && view.hub?.cwd) d.directory = view.hub.cwd
    return (
      <Box key="new-worker" flexDirection="column" borderStyle="round" borderColor={C.info} paddingX={1} rowGap={0}>
        <Text bold color={C.info}>
          Nuevo worker
        </Text>
        {accounts.length === 0 ? (
          <Text color={C.warn}>No hay cuentas de trabajo: todas son la del hub.</Text>
        ) : (
          <Box flexDirection="column">
            <Select key="nw-account" label="cuenta" options={accounts.map(a => ({ value: a, label: a }))} value={d.account} onSelect={(v: string) => (d.account = v)} />
            <Input key="nw-name" label="nombre" placeholder="w1" value={d.name} onInput={(v: string) => (d.name = v)} onSubmit={(v: string) => (d.name = v)} />
            <Input key="nw-dir" label="carpeta" value={d.directory} onInput={(v: string) => (d.directory = v)} onSubmit={(v: string) => (d.directory = v)} />
            <Input key="nw-brief" label="encargo" rows={4} placeholder="Qué tiene que hacer, hasta dónde, y cómo sabe que ha terminado" value={d.brief} onInput={(v: string) => (d.brief = v)} onSubmit={(v: string) => (d.brief = v)} />
            <Box columnGap={1}>
              <Select key="nw-model" options={MODELS} value={d.model} onSelect={(v: string) => (d.model = v)} />
              <Select key="nw-effort" options={EFFORTS} value={d.effort} onSelect={(v: string) => (d.effort = v)} />
            </Box>
            <Box columnGap={1}>
              <Button key="nw-open" label={deck.busy === 'open' ? 'abriendo…' : 'abrir worker'} onPress={() => (deck.busy ? undefined : act.openWorker({ ...d }))} />
              <Button key="nw-cancel" plain label="cancelar" onPress={act.toggleForm} />
            </Box>
            <Text color={C.faint}>Se abre en una pestaña de terminal de esa cuenta. Nunca en la del hub ni en auto.</Text>
          </Box>
        )}
      </Box>
    )
  }

  const hubSection = () => {
    const hub = view.hub
    if (!hub) return null
    if (!hub.isHub && hub.workers.length === 0) return null
    const workAccounts = view.accounts.map(a => a.name).filter(n => n.toLowerCase() !== hub.hubAccount.toLowerCase())
    const active = hub.workers.filter(w => w.phase !== 'stopped' && w.phase !== 'gone').length
    return (
      <Box key="hub" flexDirection="column" rowGap={0}>
        <Box justifyContent="space-between" columnGap={1}>
          <Text bold>
            <Text color={C.main}>HUB</Text>
            <Text color={C.dim}>{` · cuenta ${hub.hubAccount} · ${hub.workers.length} worker${hub.workers.length === 1 ? '' : 's'}, ${active} activo${active === 1 ? '' : 's'}`}</Text>
          </Text>
          {hub.isHub && !deck.isFormOpen ? <Button key="nw-toggle" label="+ nuevo worker" onPress={act.toggleForm} /> : null}
        </Box>
        {hub.isHub ? null : <Text color={C.dim}>Los controles están en las sesiones de la cuenta {hub.hubAccount}.</Text>}
        {hub.isHub && deck.isFormOpen ? form(workAccounts) : null}
        {hub.workers.map(w => lane(w, hub.rolloverPercent, hub.isHub))}
      </Box>
    )
  }

  const pipeline = (p: PipelineView) => {
    const color = p.state === 'running' ? C.main : p.state === 'waiting' ? C.warn : p.state === 'stopped' ? C.bad : C.dim
    const label = { running: '● en marcha', waiting: '◐ esperando reinicio', done: '✓ terminado', stopped: '✗ parado' }[p.state]
    return (
      <Box key="pipeline" flexDirection="column" borderStyle="single" borderColor={color} paddingX={1}>
        <Box justifyContent="space-between" columnGap={1}>
          <Text bold>
            <Text color={C.main}>PIPELINE</Text>
            <Text color={C.dim}>{` · ${p.repo} · ciclo ${p.cycle}/${p.maxCycles}`}</Text>
          </Text>
          <Text color={color}>{label}</Text>
        </Box>
        {p.roles.map(role => (
          <Text key={`role-${role.role}`} color={C.text} wrap="truncate">
            {role.role === 'implementer' ? 'A implementa' : 'B revisa'}
            <Text color={C.dim}>{` · tarea ${role.task ?? '—'} · ${[role.outcome, role.status].filter(Boolean).join(' ')}`}</Text>
          </Text>
        ))}
        {p.waitUntil ? <Text color={C.warn}>reintenta {fmtWhen(p.waitUntil, t, offset)}</Text> : null}
        {p.message ? <Text color={C.dim}>{p.message}</Text> : null}
      </Box>
    )
  }

  const total = view.accounts.reduce((n, a) => n + a.sessions.length, 0)
  const busy = view.accounts.reduce((n, a) => n + a.sessions.filter(s => s.state === 'working').length, 0)
  return (
    <Box flexDirection="column" rowGap={1}>
      {header}
      <Text color={C.dim}>
        {view.accounts.length} cuenta{view.accounts.length === 1 ? '' : 's'} · {total} sesi{total === 1 ? 'ón' : 'ones'} · {busy} trabajando
      </Text>
      {note}
      {view.error ? (
        <Text color={C.bad} wrap="wrap">
          {view.error}
        </Text>
      ) : null}
      {hubSection()}
      {view.pipeline ? pipeline(view.pipeline) : null}
      {view.accounts.length === 0 ? <Text color={C.dim}>Sin cuentas. Pulsa actualizar o ejecuta /fleet refresh.</Text> : null}
      {view.accounts.map(card)}
    </Box>
  )
}
