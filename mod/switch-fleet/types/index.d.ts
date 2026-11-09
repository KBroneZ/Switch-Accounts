export type BeatState = 'idle' | 'working' | 'ended'

/** The account limits one session reads for its own account ($.session.usage().rateLimits). */
export type BeatLimits = {
  fiveHour: number | null
  fiveHourResetsAt: string | null
  weekly: number | null
  weeklyResetsAt: string | null
}

/** One session's heartbeat, written to ~/.claude-switch/live/<sessionId>.json. */
export type Beat = {
  schema: 1
  sessionId: string
  configDir: string
  cwd: string
  repo: string | null
  model: string | null
  state: BeatState
  tool: string | null
  detail: string | null
  prompt: string | null
  ctxPct: number | null
  costUsd: number | null
  limits: BeatLimits | null
  /** When `limits` was read; an idle rewrite of the heartbeat does not move it. */
  limitsAt: number | null
  /** Hub mode: the worker name this session was opened as (SWITCH_FLEET_WORKER). */
  worker: string | null
  /** Hub mode: none, requested (writing its hand-over) or ready (wants a successor). */
  rollover: 'none' | 'requested' | 'ready'
  rolloverAt: number | null
  /** Hub mode: the reset this worker waits for, when its account is at a limit. */
  waitingUntil: string | null
  /** The first line of the last answer, masked and cut short. */
  lastReply: string | null
  /** Hub mode: the worker answered ENCARGO TERMINADO and was given nothing since. */
  finished: boolean
  turns: number
  startedAt: number
  stateSince: number
  updatedAt: number
}

export type Meter = {
  pct: number | null
  cap: number | null
  resetsAt: string | null
  isLive: boolean
}

export type Liveness = 'live' | 'quiet'

export type SessionView = {
  id: string
  /**
   * The account whose quota the session spends, when its live limits show it is another account
   * than its config dir's (the desktop app signed in with another account, say); else null.
   */
  quotaAccount: string | null
  worker: string | null
  rollover: Beat['rollover']
  waitingUntil: string | null
  lastReply: string | null
  isSelf: boolean
  liveness: Liveness
  state: BeatState
  place: string
  model: string | null
  tool: string | null
  detail: string | null
  prompt: string | null
  ctxPct: number | null
  costUsd: number | null
  stateSince: number
  updatedAt: number
}

/** Where a window is heading at its recent pace. */
export type Forecast = {
  /** Percentage points per hour over the lookback. */
  ratePerHour: number
  /** When it reaches the cap at that pace, if before its reset. */
  capAt: number | null
  /** The use it would have at its reset, when the cap is not reached first. */
  atReset: number | null
}

export type AccountHealth = 'ready' | 'at-cap' | 'logged-out' | 'unknown' | 'not-ready'

export type AccountView = {
  name: string
  plan: string | null
  health: AccountHealth
  reason: string | null
  loginCommand: string | null
  loginExpiresAt: string | null
  fiveHour: Meter
  weekly: Meter
  fiveHourForecast: Forecast | null
  weeklyForecast: Forecast | null
  sessions: SessionView[]
}

/** One role of the two-account pipeline (run-pipeline.ps1). */
export type PipelineRole = {
  role: string
  account: string | null
  task: string | null
  outcome: string | null
  status: string | null
  reason: string | null
}

/** ~/.claude-switch/pipeline.json, when it is less than half a day old. */
export type PipelineView = {
  repo: string
  state: 'running' | 'waiting' | 'done' | 'stopped'
  cycle: number
  maxCycles: number
  updatedAt: string
  waitUntil: string | null
  message: string | null
  roles: PipelineRole[]
}

/** Where a hub worker is, read from its record and its current generation's heartbeat. */
export type WorkerPhase = 'starting' | 'working' | 'idle' | 'waiting' | 'handover' | 'successor' | 'finished' | 'stopped' | 'gone'

/** One hub worker as the Deck draws it. */
export type WorkerView = {
  name: string
  account: string
  directory: string
  model: string | null
  effort: string | null
  generation: number
  phase: WorkerPhase
  /** Since when it is in this phase (the heartbeat's state change, or the record's open). */
  since: number
  tool: string | null
  detail: string | null
  ctxPct: number | null
  costUsd: number | null
  waitingUntil: string | null
  lastReply: string | null
}

/** Hub mode as this session sees it. */
export type HubView = {
  hubAccount: string
  /** This session is on the hub account: the Deck's controls act. */
  isHub: boolean
  rolloverPercent: number
  /** The session's folder, offered for a new worker. */
  cwd: string | null
  workers: WorkerView[]
}

/** What the Deck's controls say back, and which control waits for a second press. */
export type DeckView = {
  note: string | null
  isNoteError: boolean
  /** A control still running (opening a worker can take minutes). */
  busy: string | null
  /** The worker whose stop button asks for a second press, and since when (it lapses). */
  confirmStop: string | null
  confirmAt: number | null
  isFormOpen: boolean
}

export type FleetView = {
  accounts: AccountView[]
  hub: HubView | null
  pipeline: PipelineView | null
  snapshotAt: string | null
  builtAt: number
  isRefreshing: boolean
  error: string | null
}

declare module 'claude-code' {
  interface PluginState {
    'switch-fleet': {
      fleet: Shaped<FleetView | null>
      deck: Shaped<DeckView>
    }
  }
}
