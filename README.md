# Switch-Accounts

Run two of your own Claude Code subscriptions as a small pipeline: **account A implements** a task
while **account B reviews** the pull request of the previous task. Each account works in its own
git worktree and branch, and each one stops at a cap you set on its **5-hour usage window**.

> **Unofficial.** Switch-Accounts is an independent PowerShell tool that works with the Claude Code
> CLI. It is not made, endorsed or supported by Anthropic.

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
| `Get-AccountUsage` | Reads one account's 5-hour usage by running `claude -p /usage` with that account's config dir. `/usage` is a local command: it does not make a model request. |
| `Test-UsageCap` | Allows a session only if usage is known **and** below your cap. Unknown usage blocks (unknown is never treated as 0). |
| `Initialize-SecondaryAccount` / `Test-SecondaryAccount` | Shares `rules`, `skills` and `agents` from your main config dir with the second one through directory links, and writes a `CLAUDE.md` that imports the main one. Credentials, account state, settings, projects and sessions are never read, copied or linked. |
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
   A is told not to push, open PRs or switch branches, and `git push` / `gh` are denied to it.
2. The pipeline checks A's work: still on the task branch, no uncommitted changes, at least one
   commit, no more than `MaxChangedFiles` files. Then it pushes the branch and opens the PR.
3. **B reviews** that PR in `worktrees/reviewer` with read-only tools (`Read`, `Glob`, `Grep`,
   `git diff/log/show`; `Edit` and `Write` denied). Its final message starts with
   `VERDICT: APPROVED` or `VERDICT: CHANGES_REQUESTED`; the pipeline posts it as a PR comment.
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
- A `rate_limit_event` with status `rejected`, or an API retry caused by a rate limit, kills the
  session at once.
- **Overshoot:** usage is only re-read between tool calls and at most every 5 minutes, so a session
  can go past the cap by what it spends in one interval plus the current turn. `--max-turns` and
  `-TimeoutMinutes` bound every session as well.

### Accuracy of the usage reader

`/usage` reports the plan usage that the service returns, so the percentage is the real one, not
an estimate. Its text is not a documented, stable format, so the parser is strict: if the output
does not contain exactly one `Current session` block with an `NN% used` line, if it says the data
is **last-known** (it can be up to 60 minutes old) or that the usage endpoint is rate limited,
the result is `Unknown` and the account does not start. The reset time is read when it is shown;
if it cannot be parsed, the role still waits but without a known reset time.

> The parser was written against the documented behaviour and synthetic samples. If a future CLI
> version changes the `/usage` text, you will see `Unknown` (safe), not a wrong number.

## Limits and defaults

| Setting | Default |
|---------|---------|
| `MaxTurnsA` / `MaxTurnsB` | 80 / 30 |
| `TimeoutMinutes` (per session) | 60 |
| `MaxTasksPerDay` (new tasks) | 2 |
| `MaxReviewRounds` | 2 |
| `MaxChangedFiles` | 40 |
| Branch prefix | `auto/` |
| Permission mode | `dontAsk` with `--permission-prompts none` |

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
```

CI runs them on Ubuntu and Windows.

## License

[MIT](LICENSE).
