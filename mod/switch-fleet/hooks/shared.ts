// State and helpers the hooks module's files share: the options, the paths under
// ~/.claude-switch, and this session's heartbeat. Module state starts over on a reload.
import type { EngineInterface } from 'claude-code'

import type { Beat } from '../types'
import { limitsFrom } from './core'
import type { History } from './forecast'

export type Config = {
  scriptPath: string
  refreshMs: number
  openOnStart: boolean
  statusLine: boolean
  /** A worker hands over to a fresh session of its account at this much context. */
  rolloverPercent: number
  /** The account whose sessions act as the hub: they open successors and serve the hub tools. */
  hubAccount: string
}

export function parseConfig(options: Record<string, unknown>): Config {
  const minutes = typeof options.refreshMinutes === 'number' ? options.refreshMinutes : 5
  const rollover = typeof options.rolloverPercent === 'number' ? options.rolloverPercent : 40
  const hub = typeof options.hubAccount === 'string' && /^[A-Za-z0-9._-]{1,30}$/.test(options.hubAccount.trim()) ? options.hubAccount.trim() : 'A'
  return {
    scriptPath: typeof options.scriptPath === 'string' ? options.scriptPath.trim() : '',
    refreshMs: Math.min(60, Math.max(1, minutes)) * 60_000,
    openOnStart: options.openOnStart === true,
    statusLine: options.statusLine !== false,
    rolloverPercent: Math.min(90, Math.max(10, rollover)),
    hubAccount: hub,
  }
}

export type Paths = {
  dir: string
  live: string
  status: string
  history: string
  pipeline: string
  lock: string
  workers: string
  inbox: string
  defaultConfigDir: string
  script: string
}

export async function pathsOf($: EngineInterface, cfg: Config): Promise<Paths> {
  const home = (await $.env.get('USERPROFILE')) ?? (await $.env.get('HOME')) ?? '.'
  const dir = `${home}/.claude-switch`
  return {
    dir,
    live: `${dir}/live`,
    status: `${dir}/status.json`,
    history: `${dir}/usage-history.jsonl`,
    pipeline: `${dir}/pipeline.json`,
    lock: `${dir}/refresh.lock`,
    workers: `${dir}/workers`,
    inbox: `${dir}/inbox`,
    defaultConfigDir: `${home}/.claude`,
    script: cfg.scriptPath || `${home}/.claude/skills/switch-account/scripts/open-session.ps1`,
  }
}

export const S: {
  cfg: Config
  paths: Paths | null
  beat: Beat | null
  isDirty: boolean
  isRefreshing: boolean
  hasTimers: boolean
  lastError: string | null
  history: History
  historyMtime: number
  /** This session's account name, once status.json names its config dir. */
  account: string | null
  /** Successors this hub session opened, by worker, so a tick never opens two. */
  opening: Set<string>
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
  account: null,
  opening: new Set(),
}

export async function writeBeat($: EngineInterface) {
  if (!S.beat || !S.paths) return
  S.beat = { ...S.beat, updatedAt: await $.clock.now() }
  S.isDirty = false
  await $.fs.write(`${S.paths.live}/${S.beat.sessionId}.json`, JSON.stringify(S.beat)).catch(() => undefined)
}

export async function setBeat($: EngineInterface, patch: Partial<Beat>, flush: boolean) {
  if (!S.beat) return
  const t = await $.clock.now()
  const next: Beat = { ...S.beat, ...patch }
  if (patch.state && patch.state !== S.beat.state) next.stateSince = t
  S.beat = next
  S.isDirty = true
  if (flush) await writeBeat($)
}

export async function readUsage($: EngineInterface): Promise<Partial<Beat>> {
  const u = await $.session.usage().catch(() => null)
  if (!u) return {}
  const limits = limitsFrom(u.rateLimits)
  return {
    ctxPct: u.context.percent ?? null,
    costUsd: u.cost?.usd ?? null,
    ...(limits ? { limits, limitsAt: await $.clock.now() } : {}),
  }
}

/** Runs the switch-account script with arguments; never a shell. */
export async function runScript($: EngineInterface, args: string[], timeoutMs: number) {
  if (!S.paths) throw new Error('Fleet has not started')
  return $.process.run(['pwsh', '-NoProfile', '-NonInteractive', '-File', S.paths.script, ...args], { timeoutMs })
}
