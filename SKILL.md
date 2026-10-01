---
name: switch-accounts
description: Run two of the user's own Claude Code subscriptions as an implement/review pipeline (account A implements task N+1 while account B reviews the pull request of task N), each in its own git worktree, each stopping at a user-set cap on its 5-hour usage window. Use when the user asks to set up a second account's config, check an account's 5-hour usage against a cap, or run or dry-run the two-account pipeline.
---

# Switch-Accounts

Unofficial tool; not affiliated with Anthropic. Only for accounts the user owns.

## Rules

- Never rotate accounts: if one account is at its cap or its usage is unknown, its role waits.
  Do not run the other account's role, and do not suggest using a different account to keep going.
- Unknown usage means "do not start", never 0%.
- Never merge pull requests, push to the base branch, force-push, or pass
  `--dangerously-skip-permissions`. The user merges.
- Do not read, copy or print anything from a config dir other than through these commands
  (credentials live there).

## Commands

Import the module first: `Import-Module <skill-dir>/src/SwitchAccounts.psd1`.

| Need | Command |
|------|---------|
| Share rules/skills/agents with the second config dir | `Initialize-SecondaryAccount -SourceConfigDir <main> -TargetConfigDir <second> -WhatIf`, then without `-WhatIf` |
| Verify that setup | `Test-SecondaryAccount -SourceConfigDir <main> -TargetConfigDir <second>` |
| 5-hour usage of one account | `Get-AccountUsage -ConfigDir <dir>` |
| Would this account be allowed to start? | `Test-UsageCap -Usage (Get-AccountUsage -ConfigDir <dir>) -MaxFiveHourPercent <n>` |
| Inspect the queue | `Get-QueueTask -QueueDir <dir>` |
| Plan without running | `<skill-dir>/scripts/run-pipeline.ps1 ... -DryRun` |
| Run the pipeline | `<skill-dir>/scripts/run-pipeline.ps1 -RepoPath <repo> -QueueDir <dir> -AccountAConfigDir <a> -AccountBConfigDir <b> -MaxFiveHourPercentA <n> -MaxFiveHourPercentB <n>` |

Ask the user for both caps before running; do not pick them yourself. Running the pipeline
starts real sessions that spend subscription usage, so confirm with the user first and show the
`-DryRun` plan.

Exit code 3 from `run-pipeline.ps1` means no role could run (cap reached or usage unknown):
report the printed reason and reset time; do not retry with another account.

Details, limits and how the cap can overshoot: `README.md`.
