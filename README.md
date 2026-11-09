# Switch-Accounts

Run two of your own Claude Code subscriptions as a small pipeline: **account A implements** a task
while **account B reviews** the pull request of the previous task. Each account works in its own
git worktree and branch, and each one stops at a cap you set on its **5-hour usage window**.

> **Unofficial.** Switch-Accounts is an independent PowerShell tool that works with the Claude Code
> CLI. It is not affiliated with Anthropic, and it is not made, endorsed or supported by Anthropic.

## Read this first: terms of use

- **Use only accounts that you own.** Anthropic's [Consumer Terms](https://www.anthropic.com/legal/consumer-terms)
  do not allow you to share your account or make it available to anyone else. Do not use this tool
  with someone else's account.
- Subscription usage limits are designed for ordinary individual use, and the Consumer Terms
  restrict automated access except where Anthropic allows it. Read the current terms (and, if you
  are in the EEA or Switzerland, the version that applies to you, including what it says about
  commercial use) and decide for yourself whether your use fits. This README is not legal advice.
- **Never rotate accounts to get around a limit.** Switch-Accounts gives each account a fixed role.
  When an account reaches its cap or its plan limit, its role waits for the window to reset; the
  other account never takes over that work.

## What it does

| Piece | What it does |
|-------|--------------|
| `Get-AccountUsage` | Reads one account's 5-hour and weekly usage by running `claude -p /usage` with that account's config dir. `/usage` is a local command: it does not make a model request. |
| `Test-UsageCap` | Allows a session only if usage is known **and** below your cap. Unknown usage blocks (unknown is never treated as 0). An optional `-MaxWeeklyPercent` adds a cap on the weekly (all models) usage. |
| `Initialize-SecondaryAccount` / `Test-SecondaryAccount` | Shares `rules`, `skills` and `agents` from your main config dir with the second one through directory links, and writes a `CLAUDE.md` that imports the main one. Credentials, account state, settings, projects and sessions are never read, copied or linked. |
| `Open-ClaudeSession` / `scripts/open-session.ps1` | Opens a Windows Terminal tab with Claude Code on one of your accounts (`auto` = least used below its cap), with model, effort, subagent model, Remote Control, a first prompt and an optional git worktree. See [Open a session](#open-a-session-on-one-of-your-accounts). |
| `Get-ClaudeAccountStatus` | Lists the accounts with login state, plan, 5-hour and weekly usage, caps, reset times and whether each can open a session in a folder. |
| `Get-AccountAuth` | Reads whether an account is logged in, its plan and when the login expires (`claude auth status --json`); keeps nothing else. |
| Fleet mod (`mod/switch-fleet`) | A live pane, like Flightdeck, with every account and every session running on each, usage forecasts, alerts, the pipeline and one-key session opening. See [Fleet](#fleet-every-account-and-session-in-one-pane). |
| `Get-UsageReport` / `scripts/usage-report.ps1` | Usage per account and day from the history `-List` keeps. |
| `Get-QueueTask` | Reads the task queue (one Markdown file per task). |
| `Invoke-AccountSession` | Runs one `claude -p` session for one account, inside its cap, with turn and time limits. |
| `Invoke-PipelineCycle` | One step of the pipeline: A implements task N+1 while B reviews task N. |
| `scripts/run-pipeline.ps1` | Repeats cycles until there is nothing to do, a limit is hit, or no role can run. |

What it does **not** do: it never merges pull requests, never pushes to the base branch, never
force-pushes, never uses `--dangerously-skip-permissions`, and never moves work from one account
to the other.

## Requirements

- PowerShell 7.4 or later (Windows, macOS or Linux).
- Claude Code CLI **2.1.259 or later** (`--permission-prompts` is needed), logged in once per
  account: `CLAUDE_CONFIG_DIR=<dir> claude auth login`. Account A can use the default config dir.
- `git` and the GitHub CLI `gh` (authenticated) for the pipeline.
- A Pro or Max plan on each account, so that `/usage` shows plan limits.

## Quick start

```powershell
Import-Module ./src/SwitchAccounts.psd1

# 1. Share rules, skills and agents with the second account (dry run first).
Initialize-SecondaryAccount -SourceConfigDir ~/.claude -TargetConfigDir ~/.claude-second -WhatIf
Initialize-SecondaryAccount -SourceConfigDir ~/.claude -TargetConfigDir ~/.claude-second
Test-SecondaryAccount -SourceConfigDir ~/.claude -TargetConfigDir ~/.claude-second

# 2. Check usage and the cap for each account.
$usage = Get-AccountUsage -ConfigDir ~/.claude-second
Test-UsageCap -Usage $usage -MaxFiveHourPercent 60

# 3. See what the pipeline would do, then run it.
./scripts/run-pipeline.ps1 -RepoPath ~/src/app -QueueDir ~/src/app/tasks `
    -AccountAConfigDir ~/.claude -AccountBConfigDir ~/.claude-second `
    -MaxFiveHourPercentA 70 -MaxFiveHourPercentB 60 -DryRun
```

## Open a session on one of your accounts

`Open-ClaudeSession` (and its wrapper `scripts/open-session.ps1`) opens a Windows Terminal tab with
Claude Code on one of your accounts, with the model, effort and Remote Control you ask for. It is
the engine of the `switch-account` skill (see below). It starts one interactive session; it does
not run work for you and it never moves work from one account to another.

```powershell
# The account with the lowest 5-hour usage that is below its cap and ready, Sonnet, high effort, /rc
./scripts/open-session.ps1 -Account auto -Model sonnet -Effort high -RemoteControl

# Account B, Haiku subagents, in a new worktree of the current repository, with a first prompt
./scripts/open-session.ps1 -Account B -Model opus -SubagentModel haiku -Worktree fix/login `
    -InitialPrompt 'Fix the failing login test'

# Three equal tabs ("Run #1" ... "Run #3"), each with its own Remote Control name
./scripts/open-session.ps1 -Account A -RemoteControl -SessionName Run -Count 3

# Show what would happen without opening anything
./scripts/open-session.ps1 -Account B -Model haiku -Effort low -PrintOnly

# Accounts with usage, caps, reset times and readiness; the config file
./scripts/open-session.ps1 -List
./scripts/open-session.ps1 -ShowConfig
```

The last output line says what was opened, for example
`Abierta: cuenta B · sonnet · effort high · subagentes haiku · RC «x» · C:\src\app`
(the line is in Spanish because the skill reads it to the user). `-Json` prints the whole result
object instead.

| Option | Meaning |
|--------|---------|
| `-Account <name\|auto>` | An account of `accounts.json`, or `auto` (default). `auto` picks the lowest 5-hour usage among the accounts that are below their caps, ready for the folder and (with `-RemoteControl`) allowed to use it. Unknown usage means not available. A named account at its cap still opens, with a warning. |
| `-Directory` | Folder of the session (default: the current one; it must exist). |
| `-Model` | `opus`, `sonnet`, `haiku`, `fable` or a `claude-…` id (optional `[1m]`). Default: the account's `defaultModel`, else the CLI's. |
| `-Effort` | `low`, `medium`, `high`, `xhigh` or `max`. |
| `-SubagentModel` | Sets `CLAUDE_CODE_SUBAGENT_MODEL` in the tab. |
| `-RemoteControl`, `-SessionName` | Starts with `--remote-control`. The name is always passed: `-SessionName`, else `-Title`, else `<folder> · <account>`. |
| `-InitialPrompt` | First message (up to 2000 characters, not starting with `-`). |
| `-Title` | Tab title: starts with a letter or digit, then letters, digits, spaces and `. _ - # ( ) · : + @` (a label that starts with `-` would read as an option). |
| `-Worktree <branch>` | Creates `<repo>\.claude\worktrees\<branch>` on a new branch from the remote's default branch (fetched first; if the fetch fails it uses the last known one and warns), and opens the session there. The folder is added to `.git/info/exclude`. With `-Count n` the branches are `<branch>-1` … `-n`. |
| `-Count n` | 1 to 8 equal tabs with numbered titles and Remote Control names. |
| `-PrintOnly`, `-WhatIf` | Validate, choose the account and print the plan; open nothing, create no worktree, change no account config. (`-PrintOnly` still creates `accounts.json` with defaults when it is missing; `-WhatIf` does not.) |
| `-TrustDirectory` | See below. |
| `-NoUsageCheck` | Skip the usage read for a named account. |

Exit codes of `scripts/open-session.ps1`:

| Code | Meaning |
|------|---------|
| 0 | Done (also `-List`, `-ShowConfig`, `-PrintOnly`) |
| 1 | Unexpected error |
| 2 | Invalid argument or config file |
| 3 | No account can start now (cap reached or usage unknown); the earliest reset is printed |
| 4 | The account is not ready (first start unfinished, or folder not trusted); the message says what is missing |
| 5 | Something the machine lacks: the CLI, Windows Terminal, git, or a worktree problem |

### The account file

`~/.claude-switch/accounts.json` is created with two default accounts the first time it is needed
(`A` = `~/.claude`, `B` = `~/.claude-account2`). It holds no credentials.

```json
{
  "claudePath": null,
  "accounts": [
    { "name": "A", "configDir": "~/.claude", "remoteControl": true, "maxFiveHourPercent": 80,
      "maxWeeklyPercent": null, "defaultModel": null, "defaultEffort": null, "defaultSubagentModel": null },
    { "name": "B", "configDir": "~/.claude-account2", "remoteControl": true, "maxFiveHourPercent": 80,
      "maxWeeklyPercent": 90, "defaultModel": "sonnet", "defaultEffort": "high", "defaultSubagentModel": "haiku" }
  ]
}
```

`~/.claude` is the default config dir: its tab gets no `CLAUDE_CONFIG_DIR`. For any other dir the
tab sets it. `maxWeeklyPercent` is optional. `claudePath` is optional (otherwise `claude` from
`PATH`, else the newest binary of the desktop app). It must not be a `.cmd` or `.bat` file (for
example an npm shim): `cmd.exe` would read the prompt again, so use `claude.exe`. An account cannot
be called `auto`. The wrapper ignores `-ConfigPath`/`-ClaudePath` unless
`SWITCH_ACCOUNTS_ALLOW_OVERRIDES=1` is set (the tests do), so that a caller of the script cannot
make it run another program.

### What a tab does and does not do

- It runs `pwsh -NoExit -EncodedCommand …` (Windows Terminal breaks on `;` and quotes in plain
  arguments). The script first removes the variables a Claude Code session leaves to its child
  processes (`CLAUDECODE`, `CLAUDE_*`, `ANTHROPIC_*`, `MCP_*`, `OTEL_*` and a few more) unless you
  stored them in the Windows user or machine environment, then sets the account and starts the CLI.
- Every value is checked before it reaches the command line (models, efforts, labels, branch
  names, the prompt) and quoted as a PowerShell literal, including typographic quotes.
- There is no option that skips permission checks, and none of them is ever passed.

### Readiness and `-TrustDirectory`

A new tab for an account that has not finished its first start (theme, login), or that does not
trust the folder yet, would wait at a question with nobody in front of it. So nothing starts and
the error says what is missing. Readiness reads two facts from the account's `.claude.json`
(`~/.claude.json` for the default dir): `hasCompletedOnboarding` and the folders marked as
trusted (a trusted parent folder counts). Nothing else is read, kept or printed.

`-TrustDirectory` is the only thing that edits an account's `.claude.json`: it marks the folder
(for `-Worktree`, the repository) as trusted. A trusted folder runs its own hooks, MCP servers
and settings, so use it only for code you trust. It refuses drive roots, the home folder and
config dirs (and the parents of the home folder, system folders and every `configDir` of
`accounts.json`), edits the file as a JSON tree so every other value stays as it was, replaces it
in one step and keeps the previous file as `.claude.json.switch-backup` (a full copy, so it holds
what the original holds: treat it the same way), and does not work for an account whose first start
is unfinished.

### Accounts with no use in the window

With CLI 2.1.295 an account with no activity in the current 5-hour window prints no
`Current session` line in `/usage`. That exact layout (the subscription header and the usage
breakdown, no `Current ...` line, no word that signals an error) reads as 0% with no reset time,
so `auto` can pick the account. Anything else without a `Current session` line is still unknown.
Its weekly usage stays unknown, so an account with a `maxWeeklyPercent` cap is not available
until it has a weekly line.

### Login state

Each account's login is read first with `claude auth status --json` (local, no model request).
Only five facts are kept: logged in or not, the method, the subscription type, the plan tier and
when the login expires; the email, organization and ids it also prints are dropped. A logged-out
account is not asked for `/usage` (whose answer would only be the API cost summary) and `-List`
says so with the exact line that logs it in again:

```text
B: not logged in (login expired?), not available. Log in again: $env:CLAUDE_CONFIG_DIR = '...'; claude auth login; Remove-Item Env:CLAUDE_CONFIG_DIR
```

When `auth status` cannot be read (an older CLI), `/usage` is read as before. Several accounts are
read side by side. `-List` also writes `~/.claude-switch/status.json` (schema 1: login, usage,
caps, decision and readiness per account; no email, ids or credentials), which the Fleet pane
reads.

## Fleet: every account and session in one pane

`mod/switch-fleet` is a Claude Code mod (CLI 2.1.287 or later) in the style of Flightdeck. Its
pane shows one card per account (login, 5-hour and weekly gauges against your caps, reset times,
login expiry) and, under each card, every Claude Code session running on that account: folder or
repository, model, what it is doing now (thinking, the tool it runs, waiting), context used, cost
and how long it has been in that state.

How it knows: each session that loads the mod writes a small heartbeat to
`~/.claude-switch/live/<session>.json` (its config dir, folder, model, state, current tool with
keys and tokens masked, the first 70 characters of the prompt it works on, context, cost and the
5-hour and weekly use of its own account). Every pane reads all heartbeats, so the mod has to be
loaded in each account's sessions to see them. A session's own reading of its limits is newer
than `status.json` and wins over it (marked "en vivo"). When `status.json` is older than
`refreshMinutes` (default 5), one pane runs `open-session.ps1 -List` again; a lock file keeps two
sessions from doing it at once. Nothing leaves the machine and the mod makes no model calls.

Install it in each account (this repository is its marketplace). At the prompt of a terminal session:

```
/plugin install switch-fleet --marketplace KBroneZ/Switch-Accounts
```

From a shell: `claude plugin install switch-fleet --marketplace KBroneZ/Switch-Accounts` (with
`CLAUDE_CONFIG_DIR` set for a second account). In the desktop app: + next to the prompt box, then
Plugins, Add marketplace with `KBroneZ/Switch-Accounts`, then Add plugin. While developing,
`claude --plugin-dir mod/switch-fleet` loads it for one session.

| Command | Does |
| --- | --- |
| `/fleet` | open the pane |
| `/fleet refresh` (or `r` in the pane) | read every account's login and usage again |
| `/fleet report` | usage per account and day (`scripts/usage-report.ps1`) |
| `/fleet close` | close it |
| `1`, `2`, ... in the pane | open a Claude Code tab on that account, in this session's folder |

Options (`/config`): `scriptPath`, `refreshMinutes`, `openOnStart`, `statusLine`, `rolloverPercent`,
`hubAccount`. Its tests run
with `claude plugin test mod/switch-fleet`.

**Forecast.** `-List` appends each account's 5-hour and weekly use to
`~/.claude-switch/usage-history.jsonl` (8 days kept). The pane fits a straight line through the
readings of the current window (the last 90 minutes for 5 hours, the last day for the week, plus
the sessions' own readings) and shows the pace: `ritmo 12%/h → tope ~16:40` when the cap comes
before the reset, `ritmo 5%/h → ~70% al reinicio` otherwise. It needs two readings ten minutes
apart; with less it shows nothing rather than guess.

**Alerts.** A toast, once across sessions: a 5-hour cap the pace reaches within 45 minutes, a
weekly cap within a day, a login that expires within 3 days, an account that turns logged out
or reaches its cap, and one that is available again.

**Pipeline.** `run-pipeline.ps1` writes `~/.claude-switch/pipeline.json` (`-StatusPath` to
change it) after every cycle: repository, cycle, state (running, waiting for a reset, done,
stopped), each role's task and outcome, and the retry time. The pane draws it as a PIPELINE box
while it is less than 12 hours old.

**Open from the pane.** A ready account's card has `+ abrir sesión en <name> aquí`: it runs
`open-session.ps1 -Account <name> -Directory <this session's folder>` with the account's
defaults, so the same cap and readiness checks apply. Accounts at a cap or logged out have no
button: the pane never offers another account to get around a limit.

### Hub mode: one account coordinates, the others work

For the way of working where one account is the hub (it plans, opens sessions and checks on
them, spending little) and the other accounts do the work. The hub is the account named
`hubAccount` (default `A`); every other account can carry workers.

1. In a session of the hub account, ask for a worker in your own words ("abre un worker en B para
   el issue 123 en D:\Horizon\horizon, con este encargo: ..."). The hub calls
   `fleet_open_worker`: it saves the brief to `~/.claude-switch/workers/<name>.brief.md` and opens
   a terminal tab on that account (through `open-session.ps1 -WorkerName`, so caps, login and
   folder trust are checked as always). A new worktree is optional.
2. The worker shows in `/fleet` as `[w1]`. The hub reads everything with `fleet_status` (one
   short line per account and session) and talks to a worker with `fleet_send`: the message
   reaches the worker as a prompt as soon as it is idle.
3. **Hand-over.** When a worker's context passes `rolloverPercent` (default 40 %), its own mod
   asks it to finish the step and write `workers/<name>.handover.md`. The hub then opens the next
   generation of that worker **on the same account**, which reads the brief and the hand-over and
   goes on. Messages not yet taken go to the new one.
4. **Limits.** When a worker's account reaches its limit, the worker waits and, a minute and a
   half after that account's own reset, tells itself to go on. A hand-over due while its account
   is at a limit waits too. The hub never opens a worker on the hub account and never moves a
   worker to another account to get around a limit: that would be rotating accounts, which this
   tool does not do.
5. `fleet_stop_worker` asks a worker to finish its step, write its hand-over and stop, with no
   successor.

Everything stays in local files under `~/.claude-switch/` (`workers/`, `inbox/`, `live/`). Run one
hub session at a time: two hub sessions could each open the same successor.

### Fleet Deck: the pane in the desktop app

In the Claude Code desktop app (and the editor extension) `/fleet` draws the **Deck** instead of
the text pane; the terminal keeps the text pane.

- **Accounts:** a card per account with SVG bars for the 5-hour and weekly windows: the use so
  far, a fainter stretch to where the recent pace takes it by the reset, and a tick at the cap.
  Login, plan, reset times, the forecast line and the open-session button stay as they were.
- **HUB:** a lane per worker: account, hand-over generation, phase (working with its tool,
  waiting for its account's reset, writing its hand-over, successor pending, finished, stopped),
  a context bar with a tick at `rolloverPercent`, its last answer and its folder.
- **Controls, in sessions of the hub account only:** a field to message each worker, a stop
  button that asks for a second press, and `+ nuevo worker` (account, name, folder, brief, model,
  effort). They go through the same checks as the `fleet_*` tools: never the hub account, never
  `auto`, only an account that is ready. Sessions of other accounts see the lanes without controls.

### Usage report

```powershell
./scripts/usage-report.ps1 -Days 7     # one line per day and account: highest 5-hour use, weekly use, readings
./scripts/usage-report.ps1 -Json
```

### The `switch-account` skill

`skills/switch-account/SKILL.md` is the single source of the Claude Code skill. If you do not say
the account, model, effort or Remote Control, it asks them in one question and then runs the
script. Triggers: `/switch-account`, "cambiar de cuenta", "abre otra sesión", "abre con /rc",
"me quedé sin tokens". Install (or update) it with:

```powershell
./scripts/install-skill.ps1 -WhatIf   # see where it goes
./scripts/install-skill.ps1           # copies SKILL.md, the wrapper and the module to ~/.claude/skills/switch-account
```

The previous skill is moved to `~/.claude/backups/switch-account-<time>` first. A second account
whose `skills` folder is linked to the first by `Initialize-SecondaryAccount` gets the skill
through that link. Run the installer again after pulling a new version.

## The task queue

One file per task, named `NNN-slug.md`, with a small YAML header:

```markdown
---
status: ready     # only "ready" tasks run
tier: R1          # free text; "R3" never runs automatically
auto: true        # false = only by hand
gates: []         # any entry (e.g. [publish]) keeps the task for a human
---

Add input validation to the signup form and cover it with tests.
```

The next task is the eligible one with the lowest number. Pipeline progress (branch, PR,
review rounds, status) lives in `state.json` in the state folder, not in your task files.

## How a cycle works

1. **A implements** the next task in `worktrees/implementer`, on branch `auto/NNN-slug`, and commits.
   A is told not to push, open PRs or switch branches, and deny rules for `git push` and `gh` are
   added. Shell rules are best effort, so the real guarantee is step 2: only the pipeline pushes.
2. The pipeline checks A's work: still on the task branch, no uncommitted changes, at least one
   commit, no more than `MaxChangedFiles` files, no **protected path** (`.claude/`, `.mcp.json`,
   `.github/`, `.githooks/`, `.gitmodules`, `.gitattributes`) and no credential file or
   token-like line in the added code. Then it pushes the branch (never force) and opens the PR.
3. **B reviews** that PR in `worktrees/reviewer`. B has no shell and cannot edit: the pipeline
   puts the diff in its prompt (up to `MaxReviewDiffBytes`) and B can only read files in its
   worktree. Its final message starts with `VERDICT: APPROVED` or `VERDICT: CHANGES_REQUESTED`;
   if it contains nothing that looks like a token, the pipeline posts it as a PR comment.
4. Requested changes go back to A on the same branch. After `MaxReviewRounds` (default 2) the
   task is **blocked** for you. Approved PRs stay open: **you merge them**.

Steps 1 and 3 run at the same time for different tasks. Any surprise (no commits, branch
switched, no verdict, a session that failed or timed out, `NEEDS_USER:` from A) stops that task
with a written reason in `state.json` (`blocked` or `waiting-user`). To retry a task, edit or
remove its entry in `state.json`.

## Usage cap: how it is enforced and how much it can overshoot

- **Before every session** the account's usage is read; the session does not start at or above
  the cap, or when usage is unknown.
- **During a session**, a `PreToolUse` hook (`scripts/usage-guard.ps1`, passed with `--settings`
  for that session only; your settings files are not edited) re-reads usage at most every
  5 minutes and returns `{"continue": false}` when the cap is reached or usage is unknown.
  When you run the hook yourself (for example from your own settings), pass `-MaxWeeklyPercent`
  to stop at a weekly cap too; the pipeline does not set a weekly cap yet. It reads usage again after each interval
  even when it has stopped, so a session that is resumed after the window resets can go on;
  sessions of the same account can share one state file.
- A `rate_limit_event` with status `rejected`, or an API retry caused by a rate limit, kills the
  session at once.
- **Overshoot:** usage is only re-read between tool calls and at most every 5 minutes, so a session
  can go past the cap by what it spends in one interval plus the current turn. `--max-turns` and
  `-TimeoutMinutes` bound every session as well.

### Accuracy of the usage reader

`/usage` reports the plan usage that the service returns, so the percentage is the real one, not
an estimate. Its text is not a documented, stable format, so the parser is strict: if the output
does not contain exactly one line like `Current session: 23% used · resets Oct 2, 6:59am (Europe/Madrid)`,
if it says the data is **last-known** (it can be up to 60 minutes old) or that the usage endpoint
is rate limited, the result is `Unknown` and the account does not start. The reset time is read
when it is shown; if it cannot be parsed, the role still waits but without a known reset time.

The weekly usage (`WeeklyPercent`, `WeeklyResetsAt`) comes from the `Current week (all models)`
line. If that line is missing or cannot be read, the weekly usage is unknown (`$null`) and the
5-hour result does not change; only a caller that sets `-MaxWeeklyPercent` is blocked by it.
An account with no use in the current 5-hour window reads as 0% with no reset time (CLI 2.1.284
printed `0% used`; CLI 2.1.295 prints no limit line, which is recognised only in its exact layout);
right after its first message the reset time took a few minutes to appear.

Checked with Claude Code CLI 2.1.284 on two Pro accounts: the percentage matched the usage shown
by the Claude desktop app for the same account at the same moment. The reset time is printed to
the minute (seconds are cut off), so `ResetsAt` can be up to one minute early; a role that wakes
up then simply reads usage again. If a future CLI version changes the `/usage` text, you will see
`Unknown` (safe), not a wrong number.

## Limits and defaults

| Setting | Default |
|---------|---------|
| `MaxTurnsA` / `MaxTurnsB` | 80 / 30 |
| `TimeoutMinutes` (per session) | 60 |
| `MaxTasksPerDay` (new tasks) | 2 |
| `MaxReviewRounds` | 2 |
| `MaxChangedFiles` | 40 |
| Branch prefix | `auto/` |
| `MaxReviewDiffBytes` | 200000 (a larger diff blocks the task for a human review) |
| Implementer | `acceptEdits` (edits only inside its worktree), allowed `git add/commit/status` |
| Reviewer | `dontAsk`, no shell, `Edit`/`Write` denied |
| Both | `--permission-prompts none`, `--setting-sources user`, `--strict-mcp-config` |

The implementer gets **no general shell** by default. Add only the commands your tasks need,
for example `-ExtraImplementerTools 'Bash(npm test *)', 'Bash(pwsh -File ./build.ps1 *)'`
(appended to the defaults; `-ImplementerTools` on `Invoke-PipelineCycle` replaces them).
Every command you allow runs code from the repository, so allow only what you trust.

## Security model

Task files, repository content and therefore model output are treated as untrusted:

- Sessions ignore project settings and MCP servers committed in the worktree
  (`--setting-sources user`, `--strict-mcp-config`), so a branch cannot add hooks or permissions.
- Each session's settings deny `Read` and `Edit` of **both** config dirs (where credentials live)
  and block reads outside the working directories.
- Only the pipeline pushes, after the checks above. It never force-pushes, never pushes the base
  branch and never merges.
- Review text is checked for token-like strings before it is posted.

Residual risk: Claude Code's built-in read-only commands (for example read-only `git` forms) and
any shell rule you add are outside this tool's control. For stronger isolation, run the pipeline
under a separate operating-system user or in a container that has only the repository and the two
config dirs.

## Exit codes of `run-pipeline.ps1`

| Code | Meaning |
|------|---------|
| 0 | Nothing left to do, or `MaxCycles` reached |
| 3 | No role could run: cap reached or usage unknown (the earliest reset time is printed) |

## Tests

The tests never call the real CLI or GitHub: `-ClaudePath` and `-GhPath` point to PowerShell
fakes in `tests/fakes/`, and git runs against a local bare repository.

```powershell
Invoke-Pester tests
claude plugin test mod/switch-fleet   # the Fleet mod
```

CI runs the Pester tests on Ubuntu and Windows.

## License

[MIT](LICENSE).
