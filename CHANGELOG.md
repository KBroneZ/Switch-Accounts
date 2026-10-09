# Changelog

## 0.2.0 — unreleased

- `Open-ClaudeSession` and `scripts/open-session.ps1`: open a Windows Terminal tab with Claude Code on one of your accounts. `-Account <name|auto>` (auto = the account with the lowest 5-hour usage that is below its caps and ready), `-Model`, `-Effort`, `-SubagentModel`, `-RemoteControl` with `-SessionName` (the name is always passed explicitly), `-InitialPrompt`, `-Title`, `-Worktree <branch>` (a git worktree under `<repo>\.claude\worktrees` from the remote's default branch), `-Count`, `-PrintOnly` / `-WhatIf`. Documented exit codes 0-5. The tab drops variables inherited from the launching session, the script travels as `-EncodedCommand`, every value is validated first, and no option can skip permission checks.
- `~/.claude-switch/accounts.json` (created with defaults, `Get-SwitchAccountConfig`, `-ShowConfig`): per account the config dir, whether Remote Control is allowed, the 5-hour cap, an optional weekly cap and the default model, effort and subagent model. No credentials.
- `Get-ClaudeAccountStatus` (`open-session.ps1 -List`): usage (5 h and weekly), caps, reset time and readiness of every account. Unknown usage means not available.
- Readiness: a session does not start when the account has not finished its first start or does not trust the folder; the error says what is missing. Only `hasCompletedOnboarding` and the folder trust marks of `.claude.json` are read. `-TrustDirectory` (explicit) marks the folder as trusted, with a backup of the file.
- `skills/switch-account` and `scripts/install-skill.ps1`: the skill (one `AskUserQuestion` for account, model, effort and Remote Control) is installed from this repository, with a backup of the previous one.
- Hardening from the code and security reviews: labels cannot start with `-`; a `claude.cmd`/`.bat` CLI is refused; `-TrustDirectory` also refuses the parents of the home folder, system folders and configured config dirs and replaces the file atomically; worktrees refuse links and Windows device names; the wrapper only accepts `-ConfigPath`/`-ClaudePath` with `SWITCH_ACCOUNTS_ALLOW_OVERRIDES=1`; a missing git is exit code 5.
- Tests: the fake CLI writes UTF-8, so the usage tests also pass when the console code page is not UTF-8.

## 0.1.0 — unreleased

- `Get-AccountUsage` and `Test-UsageCap`: 5-hour usage per account from `claude -p /usage`, fail-closed cap. The parser follows the one-line `Current session: NN% used · resets ...` layout of CLI 2.1.284, checked against real output.
- `Initialize-SecondaryAccount` and `Test-SecondaryAccount`: share rules, skills and agents with a second config dir through directory links, plus a `CLAUDE.md` import; credentials and account state untouched.
- `Get-QueueTask`: Markdown task queue with a YAML header.
- `Invoke-AccountSession`: capped `claude -p` session with turn and time limits, a per-session usage guard hook, and a kill on rate-limit rejection.
- `Invoke-PipelineCycle` and `scripts/run-pipeline.ps1`: A implements while B reviews, separate worktrees and branches, review rounds, JSON Lines run log, `-DryRun`.
- Weekly usage: `ConvertFrom-UsageText` and `Get-AccountUsage` also return `WeeklyPercent` and `WeeklyResetsAt` from the `Current week (all models)` line (`$null` when missing; the 5-hour result does not change). `Test-UsageCap -MaxWeeklyPercent` adds an optional weekly cap; without it nothing changes.
- `scripts/usage-guard.ps1`: optional `-MaxWeeklyPercent`; it reads usage again after each interval even after it has stopped a session (a resumed session can go on once the window resets), and several sessions of one account can share a state file (atomic replace, retry on a busy file).
