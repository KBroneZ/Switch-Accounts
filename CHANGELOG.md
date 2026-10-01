# Changelog

## 0.1.0 — unreleased

- `Get-AccountUsage` and `Test-UsageCap`: 5-hour usage per account from `claude -p /usage`, fail-closed cap.
- `Initialize-SecondaryAccount` and `Test-SecondaryAccount`: share rules, skills and agents with a second config dir through directory links, plus a `CLAUDE.md` import; credentials and account state untouched.
- `Get-QueueTask`: Markdown task queue with a YAML header.
- `Invoke-AccountSession`: capped `claude -p` session with turn and time limits, a per-session usage guard hook, and a kill on rate-limit rejection.
- `Invoke-PipelineCycle` and `scripts/run-pipeline.ps1`: A implements while B reviews, separate worktrees and branches, review rounds, JSON Lines run log, `-DryRun`.
