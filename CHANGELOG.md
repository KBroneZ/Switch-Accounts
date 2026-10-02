# Changelog

## 0.1.0 — unreleased

- `Get-AccountUsage` and `Test-UsageCap`: 5-hour usage per account from `claude -p /usage`, fail-closed cap. The parser follows the one-line `Current session: NN% used · resets ...` layout of CLI 2.1.284, checked against real output.
- `Initialize-SecondaryAccount` and `Test-SecondaryAccount`: share rules, skills and agents with a second config dir through directory links, plus a `CLAUDE.md` import; credentials and account state untouched.
- `Get-QueueTask`: Markdown task queue with a YAML header.
- `Invoke-AccountSession`: capped `claude -p` session with turn and time limits, a per-session usage guard hook, and a kill on rate-limit rejection.
- `Invoke-PipelineCycle` and `scripts/run-pipeline.ps1`: A implements while B reviews, separate worktrees and branches, review rounds, JSON Lines run log, `-DryRun`.
- Weekly usage: `ConvertFrom-UsageText` and `Get-AccountUsage` also return `WeeklyPercent` and `WeeklyResetsAt` from the `Current week (all models)` line (`$null` when missing; the 5-hour result does not change). `Test-UsageCap -MaxWeeklyPercent` adds an optional weekly cap; without it nothing changes.
- `scripts/usage-guard.ps1`: optional `-MaxWeeklyPercent`; it reads usage again after each interval even after it has stopped a session (a resumed session can go on once the window resets), and several sessions of one account can share a state file (atomic replace, retry on a busy file).
