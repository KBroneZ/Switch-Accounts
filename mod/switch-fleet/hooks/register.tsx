// Fleet: every Claude Code account you own and every session running on each, in one pane.
//
// Two halves. The heartbeat: this session writes what it is doing to
// ~/.claude-switch/live/<sessionId>.json (state, tool, model, context, cost and the limits of
// its own account), so any other session with this mod sees it. The pane: it reads those
// heartbeats and status.json (written by `open-session.ps1 -List`), and runs -List again when
// status.json is older than `refreshMinutes`. Only local files; no network, no model calls.
import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { AccountView, Beat, FleetView, Meter, PipelineView, SessionView } from '../types'
import { alertsFor, buildFleet, parsePipeline, fmtSpan, fmtWhen, forecastText, gauge, healthChanges, limitsFrom, maskSecrets, parseBeat, parseSnapshot, shorten, statusText, toolDetail } from './core'
import { parseHistory } from './forecast'
import type { History } from './forecast'

const PANE = 'switch-fleet'
const TITLE = 'Fleet'
const POLL_MS = 5_000
const IDLE_BEAT_MS = 60_000
const REFRESH_TIMEOUT_MS = 180_000
const LOCK_MS = 4 * 60_000

const fleet = atom({ plugin: 'switch-fleet', key: 'fleet' } as const, null, { shape: 'fleet-3' })
/** Alerts already shown, kept across sessions so each one is toasted once. */
const ALERTED_KEY = 'alerted'
const MAX_ALERTED = 100

type Config = { scriptPath: string; refreshMs: number; openOnStart: boolean; statusLine: boolean }

function parseConfig(options: Record<string, unknown>): Config {
  const minutes = typeof options.refreshMinutes === 'number' ? options.refreshMinutes : 5
  return {
    scriptPath: typeof options.scriptPath === 'string' ? options.scriptPath.trim() : '',
    refreshMs: Math.min(60, Math.max(1, minutes)) * 60_000,
    openOnStart: options.openOnStart === true,
    statusLine: options.statusLine !== false,
  }
}

type Paths = { dir: string; live: string; status: string; history: string; pipeline: string; lock: string; defaultConfigDir: string; script: string }

async function pathsOf($: EngineInterface, cfg: Config): Promise<Paths> {
  const home = (await $.env.get('USERPROFILE')) ?? (await $.env.get('HOME')) ?? '.'
  const dir = `${home}/.claude-switch`
  return {
    dir,
    live: `${dir}/live`,
    status: `${dir}/status.json`,
    history: `${dir}/usage-history.jsonl`,
    pipeline: `${dir}/pipeline.json`,
    lock: `${dir}/refresh.lock`,
    defaultConfigDir: `${home}/.claude`,
    script: cfg.scriptPath || `${home}/.claude/skills/switch-account/scripts/open-session.ps1`,
  }
}

// Module state: the heartbeat being built and whether it needs writing. A reload starts it over,
// and the next event or the idle timer writes a fresh one.
const S: {
  cfg: Config
  paths: Paths | null
  beat: Beat | null
  isDirty: boolean
  isRefreshing: boolean
  hasTimers: boolean
  lastError: string | null
  history: History
  historyMtime: number
} = {
  cfg: parseConfig({}),
  paths: null,
  beat: null,
  isDirty: false,
  isRefreshing: false,
  hasTimers: false,
  lastError: null,
  history: new Map(),
  historyMtime: -1,
}

async function writeBeat($: EngineInterface) {
  if (!S.beat || !S.paths) return
  S.beat = { ...S.beat, updatedAt: await $.clock.now() }
  S.isDirty = false
  await $.fs.write(`${S.paths.live}/${S.beat.sessionId}.json`, JSON.stringify(S.beat)).catch(() => undefined)
}

async function setBeat($: EngineInterface, patch: Partial<Beat>, flush: boolean) {
  if (!S.beat) return
  const t = await $.clock.now()
  const next: Beat = { ...S.beat, ...patch }
  if (patch.state && patch.state !== S.beat.state) next.stateSince = t
  S.beat = next
  S.isDirty = true
  if (flush) await writeBeat($)
}

async function readUsage($: EngineInterface): Promise<Partial<Beat>> {
  const u = await $.session.usage().catch(() => null)
  if (!u) return {}
  const limits = limitsFrom(u.rateLimits)
  return {
    ctxPct: u.context.percent ?? null,
    costUsd: u.cost?.usd ?? null,
    ...(limits ? { limits, limitsAt: await $.clock.now() } : {}),
  }
}

async function readBeats($: EngineInterface): Promise<Beat[]> {
  if (!S.paths) return []
  const entries = await $.fs.list(S.paths.live).catch(() => [])
  const files = entries.filter(f => f.kind === 'file' && f.name.endsWith('.json'))
  const beats = await Promise.all(
    files.map(f => $.fs.read(`${S.paths!.live}/${f.name}`).then(t => parseBeat(String(t)), () => null)),
  )
  return beats.filter((b): b is Beat => b !== null)
}

/** usage-history.jsonl, read again only when it changed (it grows with every -List). */
async function readHistory($: EngineInterface): Promise<History> {
  if (!S.paths) return S.history
  const stat = await $.fs.stat(S.paths.history).catch(() => null)
  if (!stat || stat.mtimeMs === S.historyMtime) return S.history
  const text = await $.fs.read(S.paths.history).then(String, () => null)
  if (text !== null) {
    S.history = parseHistory(text)
    S.historyMtime = stat.mtimeMs
  }
  return S.history
}

/** Toasts each warning once across sessions (the ids are kept in $.store). */
async function raiseAlerts($: EngineInterface, accounts: AccountView[], now: number) {
  const alerts = alertsFor(accounts, now, new Date(now).getTimezoneOffset())
  if (alerts.length === 0) return
  const stored = await $.store.get(ALERTED_KEY).catch(() => null)
  const seen = Array.isArray(stored) ? stored.filter((x): x is string => typeof x === 'string') : []
  const fresh = alerts.filter(a => !seen.includes(a.id))
  if (fresh.length === 0) return
  await $.store.set(ALERTED_KEY, [...seen, ...fresh.map(a => a.id)].slice(-MAX_ALERTED))
  for (const a of fresh) await $.ui.toast(a.text, { timeoutMs: 10_000 })
}

async function rebuild($: EngineInterface) {
  if (!S.paths) return
  const [text, beats, history, pipelineText, t] = await Promise.all([
    $.fs.read(S.paths.status).then(String, () => null),
    readBeats($),
    readHistory($),
    $.fs.read(S.paths.pipeline).then(String, () => null),
    $.clock.now(),
  ])
  const snapshot = text ? parseSnapshot(text) : null
  const built = buildFleet(snapshot, beats, t, S.beat?.sessionId ?? null, history)
  const before = await read($, fleet)
  const pipeline = pipelineText ? parsePipeline(pipelineText, t) : null
  const view: FleetView = { ...built, pipeline, isRefreshing: S.isRefreshing, error: S.lastError }
  // Redraw only when something a reader sees changed (builtAt alone does not count).
  const same = before && JSON.stringify({ ...before, builtAt: 0 }) === JSON.stringify({ ...view, builtAt: 0 })
  if (!same) await update($, fleet, () => view)
  for (const msg of healthChanges(before, built)) await $.ui.toast(msg)
  await raiseAlerts($, built.accounts, t)
  if (S.cfg.statusLine) await $.ui.status(statusText(built))
  return snapshot
}

/** Runs `open-session.ps1 -List` when status.json is older than refreshMinutes (or when forced). */
async function maybeRefresh($: EngineInterface, force: boolean) {
  if (!S.paths || S.isRefreshing) return
  const t = await $.clock.now()
  if (!force) {
    const stat = await $.fs.stat(S.paths.status).catch(() => null)
    if (stat && t - stat.mtimeMs < S.cfg.refreshMs) return
    // Another session may be refreshing: one -List at a time across sessions.
    const lock = await $.fs.read(S.paths.lock).then(s => Number(String(s)), () => 0)
    if (lock && t - lock < LOCK_MS) return
  }
  if (!(await $.fs.exists(S.paths.script))) {
    S.lastError = `No encuentro ${S.paths.script}. Instala la skill switch-account o pon scriptPath.`
    await rebuild($)
    return
  }
  S.isRefreshing = true
  S.lastError = null
  try {
    await $.fs.write(S.paths.lock, String(t)).catch(() => undefined)
    await rebuild($)
    const r = await $.process.run(['pwsh', '-NoProfile', '-NonInteractive', '-File', S.paths.script, '-List'], { timeoutMs: REFRESH_TIMEOUT_MS })
    if (r.exitCode !== 0) S.lastError = shorten(`-List falló (${r.exitCode}): ${(r.stderr || r.stdout).trim()}`, 200)
  } catch (err) {
    S.lastError = shorten(`No pude ejecutar pwsh: ${String(err)}`, 200)
  } finally {
    S.isRefreshing = false
  }
  await rebuild($)
}

/** One poll: write the heartbeat when it changed (or every minute while idle), then redraw. */
async function tick($: EngineInterface) {
  if (S.beat && (S.isDirty || (await $.clock.now()) - S.beat.updatedAt > IDLE_BEAT_MS)) await writeBeat($)
  await rebuild($)
}

function noteError(err: unknown) {
  S.lastError = shorten(`Fleet: ${String(err)}`, 200)
}

/**
 * Opens a Claude Code tab on one account in this session's folder, through the same script the
 * switch-account skill runs (it checks caps and readiness itself). Answers a press, never a timer.
 */
async function openSessionOn($: EngineInterface, account: string) {
  if (!S.paths || !S.beat) return
  if (!/^[A-Za-z0-9._-]{1,40}$/.test(account)) return
  await $.ui.toast(`Abriendo una sesión en la cuenta ${account}…`)
  const r = await $.process.run(
    ['pwsh', '-NoProfile', '-NonInteractive', '-File', S.paths.script, '-Account', account, '-Directory', S.beat.cwd],
    { timeoutMs: REFRESH_TIMEOUT_MS },
  )
  const lines = (r.exitCode === 0 ? r.stdout : r.stderr || r.stdout).trim().split(/\r?\n/)
  const last = lines[lines.length - 1] ?? ''
  await $.ui.toast(r.exitCode === 0 ? last : `No se abrió (código ${r.exitCode}): ${shorten(last, 160)}`, { timeoutMs: 10_000 })
}

/** The per-day usage table of usage-report.ps1, which the skill installs beside open-session.ps1. */
async function usageReport($: EngineInterface): Promise<string> {
  if (!S.paths) return 'Fleet aún no ha arrancado.'
  // The sibling of the configured script by folder and a fixed name, never the script itself.
  const folder = S.paths.script.replace(/[\\/][^\\/]*$/, '')
  const script = `${folder}/usage-report.ps1`
  if (folder === S.paths.script || !(await $.fs.exists(script))) return `No encuentro ${script}. Reinstala la skill switch-account.`
  const r = await $.process.run(['pwsh', '-NoProfile', '-NonInteractive', '-File', script], { timeoutMs: 60_000 })
  const out = (r.exitCode === 0 ? r.stdout : r.stderr || r.stdout).trim()
  const fence = '```'
  return r.exitCode === 0 ? [fence, out, fence].join('\n') : `El informe falló (${r.exitCode}): ${shorten(out, 300)}`
}

async function openPane($: EngineInterface) {
  return $.ui.open({ id: PANE, title: TITLE, columns: 64, rows: 12 })
}

export const register: Register = (on, options) => {
  S.cfg = parseConfig(options)

  // ------------------------------------------------------------ heartbeat

  on('session.start', async ($, e, next) => {
    const done = await next(e)
    await $.command.register({
      name: 'fleet',
      description: 'Fleet: all your Claude Code accounts and their sessions in one pane',
      argumentHint: '[open|close|refresh|report]',
    })
    S.paths = await pathsOf($, S.cfg)
    const [id, cwd, model, repo, configDir, t] = await Promise.all([
      $.session.id(),
      $.session.cwd(),
      $.session.model().catch(() => null),
      $.session.repo().catch(() => null),
      $.env.get('CLAUDE_CONFIG_DIR'),
      $.clock.now(),
    ])
    S.beat = {
      schema: 1,
      sessionId: id,
      configDir: configDir || S.paths.defaultConfigDir,
      cwd,
      repo: repo?.name ?? null,
      model,
      state: 'idle',
      tool: null,
      detail: null,
      prompt: null,
      ctxPct: null,
      costUsd: null,
      limits: null,
      limitsAt: null,
      turns: 0,
      startedAt: t,
      stateSince: t,
      updatedAt: t,
    }
    await setBeat($, await readUsage($), true)
    if (!S.hasTimers) {
      // One set of timers per load, however often session.start fires.
      S.hasTimers = true
      $.clock.every(POLL_MS, () => void tick($).catch(err => noteError(err)))
      $.clock.every(60_000, () => void maybeRefresh($, false).catch(err => noteError(err)))
    }
    await rebuild($).catch(err => noteError(err))
    void maybeRefresh($, false).catch(err => noteError(err))
    if (S.cfg.openOnStart && e.isInteractive) {
      const surface = await $.session.surface()
      if (surface && surface !== 'mobile') void openPane($)
    }
    return done
  })

  on('turn.start', async ($, e, next) => {
    if (!e.agentId) {
      const prompt = e.text.trim() ? shorten(maskSecrets(e.text.replace(/\s+/g, ' ').trim()), 70) : null
      await setBeat($, { state: 'working', tool: null, detail: null, prompt, model: await $.session.model().catch(() => S.beat?.model ?? null) }, true)
    }
    return next(e)
  })

  on('tool.call', async ($, e, next) => {
    if (!e.agentId && S.beat) {
      const input = e as unknown as Record<string, unknown>
      await setBeat($, { tool: String(e.tool), detail: toolDetail(String(e.tool), input) }, false)
    }
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    const done = await next(e)
    if (!('agentId' in e && e.agentId) && S.beat) {
      await setBeat($, { state: 'idle', tool: null, detail: null, turns: S.beat.turns + 1, ...(await readUsage($)) }, true)
    }
    return done
  })

  on('session.end', async ($, e, next) => {
    await setBeat($, { state: 'ended', tool: null, detail: null }, true)
    return next(e)
  })

  // ------------------------------------------------------------ command

  on('command.run', { command: 'fleet' }, async ($, e) => {
    const verb = e.args.trim().split(/\s+/)[0] || 'open'
    if (verb === 'close') {
      await $.ui.close({ id: PANE })
      return { text: 'Fleet cerrado.' }
    }
    if (verb === 'report') {
      return { text: await usageReport($) }
    }
    if (verb === 'refresh') {
      void maybeRefresh($, true).catch(err => noteError(err))
      await openPane($)
      return { text: 'Fleet: leyendo el uso de todas las cuentas…' }
    }
    const opened = await openPane($)
    return { text: opened.isPlaced ? 'Fleet abierto. /fleet refresh vuelve a leer el uso.' : `Fleet aún no se muestra: ${opened.reason}` }
  })

  // ------------------------------------------------------------ pane

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const { Box, Text, Button } = $.ui.resolve(e)
    const [view, t] = await Promise.all([read($, fleet), $.clock.now()])
    const W = Math.max(28, e.props.bodyColumns)
    const offset = new Date(t).getTimezoneOffset()
    const C = { main: 'claude', ok: 'success', warn: 'warning', bad: 'error', dim: 'inactive', faint: 'subtle', text: 'text', info: 'suggestion' } as const

    const header = (
      <Box justifyContent="space-between" width={W}>
        <Text color={C.main} bold>
          FLEET
        </Text>
        <Box flexShrink={0} columnGap={1}>
          <Text color={C.dim}>
            {view?.isRefreshing ? 'leyendo uso…' : view?.snapshotAt ? `uso hace ${fmtSpan(t - Date.parse(view.snapshotAt))}` : 'sin datos de uso'}
          </Text>
          <Button key="refresh" hotkey="r" label="actualizar" onPress={() => void maybeRefresh($, true).catch(err => noteError(err))} />
        </Box>
      </Box>
    )
    if (!view) {
      return (
        <Box flexDirection="column" width={W}>
          {header}
          <Text color={C.dim}>Cargando…</Text>
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

    const meterRow = (label: string, m: Meter, inner: number) => {
      if (m.pct === null) {
        return (
          <Box>
            <Text color={C.dim}>{label.padEnd(4)}sin dato</Text>
          </Box>
        )
      }
      const gw = Math.max(6, Math.min(16, inner - 30))
      const g = gauge(m.pct, gw)
      const isOver = m.cap !== null && m.pct >= m.cap
      const isNear = m.cap !== null && m.pct >= m.cap - 10
      const color = isOver ? C.bad : isNear ? C.warn : C.ok
      const reset = m.resetsAt ? `↻ ${fmtWhen(m.resetsAt, t, offset)} (${fmtSpan(Date.parse(m.resetsAt) - t)})` : ''
      return (
        <Box columnGap={1} overflow="hidden">
          <Text color={C.dim}>{label.padEnd(3)}</Text>
          <Text>
            <Text color={color}>{g.on}</Text>
            <Text color={C.faint}>{g.off}</Text>
          </Text>
          <Text color={color} bold>
            {`${Math.round(m.pct)}%`.padStart(4)}
          </Text>
          <Text color={C.dim}>{m.cap !== null ? `/${Math.round(m.cap)}` : ''}</Text>
          <Text color={C.dim} wrap="truncate">
            {reset}
            {m.isLive ? ' ·en vivo' : ''}
          </Text>
        </Box>
      )
    }

    const forecastRow = (f: AccountView['fiveHourForecast']) => {
      const line = forecastText(f, t, offset)
      if (!line) return null
      return (
        <Text color={line.isWarning ? C.warn : C.dim} wrap="truncate">
          {'    '}
          {line.text}
        </Text>
      )
    }

    const sessionRow = (s: SessionView, inner: number) => {
      const isWorking = s.state === 'working'
      const dot = s.liveness === 'quiet' ? '◌' : isWorking ? '●' : s.state === 'ended' ? '✕' : '○'
      const color = s.liveness === 'quiet' || s.state === 'ended' ? C.faint : isWorking ? C.main : C.dim
      const what = isWorking ? (s.tool ? `${s.tool}${s.detail ? `: ${s.detail}` : ''}` : 'pensando') : s.state === 'ended' ? 'cerrada' : 'en espera'
      const meta = [s.model ? s.model.replace(/^claude-/, '').replace(/-\d{8}$/, '') : null, s.ctxPct !== null ? `ctx ${Math.round(s.ctxPct)}%` : null, s.costUsd ? `$${s.costUsd.toFixed(2)}` : null, fmtSpan(t - s.stateSince)]
        .filter(Boolean)
        .join(' · ')
      return (
        <Box flexDirection="column" width={inner}>
          <Box justifyContent="space-between" width={inner} overflow="hidden">
            <Text color={color} bold={isWorking} wrap="truncate">
              {dot} {s.place}
              {s.isSelf ? ' (esta)' : ''}
            </Text>
            <Box flexShrink={0}>
              <Text color={C.dim}>{meta}</Text>
            </Box>
          </Box>
          <Text color={isWorking ? C.text : C.dim} wrap="truncate">
            {'  '}
            {shorten(what, Math.max(10, inner - 2))}
          </Text>
          {s.prompt && isWorking ? (
            <Text color={C.faint} wrap="truncate">
              {'  “'}
              {shorten(s.prompt, Math.max(10, inner - 4))}”
            </Text>
          ) : null}
        </Box>
      )
    }

    const pipelineBox = (p: PipelineView) => {
      const inner = W - 4
      const color = p.state === 'running' ? C.main : p.state === 'waiting' ? C.warn : p.state === 'stopped' ? C.bad : C.dim
      const label = { running: '● en marcha', waiting: '◐ esperando reinicio', done: '✓ terminado', stopped: '✗ parado' }[p.state]
      return (
        <Box key="pipeline" flexDirection="column" borderStyle="single" borderColor={color} paddingX={1} width={W}>
          <Box justifyContent="space-between" width={inner}>
            <Text bold wrap="truncate">
              <Text color={C.main}>PIPELINE</Text>
              <Text color={C.dim}>{` · ${p.repo} · ciclo ${p.cycle}/${p.maxCycles}`}</Text>
            </Text>
            <Box flexShrink={0}>
              <Text color={color}>{label}</Text>
            </Box>
          </Box>
          {p.roles.map(role => (
            <Text color={C.text} wrap="truncate">
              {role.role === 'implementer' ? 'A implementa' : 'B revisa'}
              <Text color={C.dim}>{` · tarea ${role.task ?? '—'} · ${[role.outcome, role.status].filter(Boolean).join(' ')}`}</Text>
            </Text>
          ))}
          {p.waitUntil ? <Text color={C.warn}>reintenta {fmtWhen(p.waitUntil, t, offset)}</Text> : null}
          {p.message ? (
            <Text color={C.dim} wrap="truncate">
              {p.message}
            </Text>
          ) : null}
          <Text color={C.faint}>act. hace {fmtSpan(t - Date.parse(p.updatedAt))}</Text>
        </Box>
      )
    }

    const card = (a: AccountView, index: number) => {
      const inner = W - 4
      const border = a.health === 'logged-out' ? C.bad : a.health === 'at-cap' ? C.warn : a.health === 'ready' ? C.main : C.faint
      const working = a.sessions.filter(s => s.state === 'working').length
      const days = a.loginExpiresAt ? (Date.parse(a.loginExpiresAt) - t) / 86_400_000 : null
      return (
        <Box key={`acct-${a.name}`} flexDirection="column" borderStyle="round" borderColor={border} paddingX={1} width={W}>
          <Box justifyContent="space-between" width={inner}>
            <Text bold wrap="truncate">
              <Text color={C.main}>{a.name}</Text>
              <Text color={C.dim}>{a.plan ? ` · ${a.plan}` : ''}</Text>
              <Text color={C.dim}>{a.sessions.length ? ` · ${a.sessions.length} ses.${working ? `, ${working} activa${working > 1 ? 's' : ''}` : ''}` : ''}</Text>
            </Text>
            <Box flexShrink={0}>{healthChip(a)}</Box>
          </Box>
          {a.health === 'logged-out' ? (
            <Box flexDirection="column">
              <Text color={C.bad}>Inicia sesión otra vez en una terminal:</Text>
              <Text color={C.text}>{a.loginCommand ?? 'claude auth login'}</Text>
            </Box>
          ) : (
            <Box flexDirection="column">
              {meterRow('5h', a.fiveHour, inner)}
              {forecastRow(a.fiveHourForecast)}
              {meterRow('sem', a.weekly, inner)}
              {forecastRow(a.weeklyForecast)}
              {days !== null && days < 7 ? (
                <Text color={days < 2 ? C.bad : C.warn}>login caduca en {fmtSpan(Date.parse(a.loginExpiresAt!) - t)}</Text>
              ) : null}
            </Box>
          )}
          {a.health === 'ready' ? (
            <Box>
              <Button
                key={`open-${a.name}`}
                plain
                {...(index < 9 ? { hotkey: String(index + 1) } : {})}
                label={`+ abrir sesión en ${a.name} aquí`}
                onPress={() => void openSessionOn($, a.name).catch(err => noteError(err))}
              />
            </Box>
          ) : null}
          {a.sessions.length > 0 ? (
            <Box flexDirection="column" marginTop={0}>
              <Text color={C.faint}>{'─'.repeat(Math.max(1, inner))}</Text>
              {a.sessions.slice(0, 6).map(s => sessionRow(s, inner))}
              {a.sessions.length > 6 ? <Text color={C.dim}>+{a.sessions.length - 6} más</Text> : null}
            </Box>
          ) : null}
        </Box>
      )
    }

    const total = view.accounts.reduce((n, a) => n + a.sessions.length, 0)
    const busy = view.accounts.reduce((n, a) => n + a.sessions.filter(s => s.state === 'working').length, 0)
    return (
      <Box flexDirection="column" width={W}>
        {header}
        <Text color={C.dim}>
          {view.accounts.length} cuenta{view.accounts.length === 1 ? '' : 's'} · {total} sesi{total === 1 ? 'ón' : 'ones'} · {busy} trabajando
        </Text>
        {view.error ? (
          <Text color={C.bad} wrap="wrap">
            {view.error}
          </Text>
        ) : null}
        {view.accounts.length === 0 ? <Text color={C.dim}>Sin cuentas. Pulsa actualizar o ejecuta /fleet refresh.</Text> : null}
        {view.pipeline ? pipelineBox(view.pipeline) : null}
        {view.accounts.map(card)}
      </Box>
    )
  })
}
