---
name: switch-account
description: Open a new Windows Terminal tab with Claude Code on one of the user's own accounts, choosing the account (or auto = least used), model, effort, subagent model, Remote Control (/rc), folder and git worktree. Use for /switch-account, "cambiar de cuenta", "abre otra sesión", "abre otra conversación", "abre con /rc", "me quedé sin tokens", "open another session", "switch account".
---

# switch-account

Opens a tab in Windows Terminal with a fresh Claude Code session on another configured account.
The current session keeps running. Only accounts the user owns; accounts live in
`~/.claude-switch/accounts.json` (no credentials in it).

Script: `<skill-dir>/scripts/open-session.ps1` (run with `pwsh -NoProfile -File`; write Windows
paths with forward slashes in the Bash tool, or the backslashes are eaten).

## Rules

- Never pass `--dangerously-skip-permissions` or anything that skips permission checks; the script has no such option.
- Never read, copy or print anything from an account's config dir by hand (credentials live there). Use the script.
- If no account can start (exit code 3), report the reset time. Do not look for a way around the cap.
- Add `-TrustDirectory` only when the user asks for it, after exit code 4 told them the folder is not trusted.
- Talk to the user in their language. The script's last line is already worded for them; repeat it.

## Steps

1. **Collect what is missing.** Take account, model, effort, subagent model, Remote Control, folder,
   first prompt, worktree branch and number of tabs from what the user said. If account, model,
   effort or Remote Control is not stated, ask them all in ONE `AskUserQuestion` call (up to 4
   questions; skip the ones already answered). Learn the account names first with
   `pwsh -NoProfile -File <skill-dir>/scripts/open-session.ps1 -ShowConfig` (fast, reads no usage).

   | Question | Options |
   |----------|---------|
   | Cuenta | `auto (Recomendado)` = least 5-hour usage below its cap and ready; then up to 3 configured names |
   | Modelo | `por defecto de la cuenta`, `opus`, `sonnet`, `haiku` (`fable` or a `claude-…` id through "Other") |
   | Effort | `por defecto`, `low`, `high`, `max` (`medium`, `xhigh` through "Other") |
   | Remote Control | `Sí`, `No` |

   "por defecto" means: leave the flag out (the account's default from `accounts.json` applies).
   Do not ask about the subagent model; pass `-SubagentModel` only when the user mentions it.

2. **Run it** from the folder the user works in (that is the default `-Directory`):

   ```powershell
   pwsh -NoProfile -File <skill-dir>/scripts/open-session.ps1 -Account <name|auto> [-Model <m>] [-Effort <e>] [-SubagentModel <m>] [-RemoteControl [-SessionName <n>]] [-Directory <dir>] [-Title <t>] [-InitialPrompt <text>] [-Worktree <branch>] [-Count <n>]
   ```

   `-PrintOnly` (or `-WhatIf`) shows the plan without opening anything. `-List` shows every
   account with 5-hour and weekly usage, caps, reset time and readiness. `-Worktree <branch>`
   creates `<repo>/.claude/worktrees/<branch>` from the remote's default branch.

3. **Tell the user** the summary line the script prints, for example
   `Abierta: cuenta B · sonnet · effort high · subagentes haiku · RC «x» · C:\…`.

## Exit codes

| Code | Meaning | What to do |
|------|---------|------------|
| 0 | Opened (or listed / simulated) | Say the summary line |
| 2 | Invalid argument or config | Show the message, fix the value, retry |
| 3 | No account can start (cap reached or usage unknown) | Report the message and earliest reset; stop |
| 4 | Account not ready (first start unfinished or folder not trusted) | Say what is missing. Offer `-TrustDirectory` only for an untrusted folder, and only if the user agrees |
| 5 | Missing CLI, Windows Terminal, git or worktree problem | Show the message |
| 1 | Unexpected error | Show the message |

Unknown usage counts as "not available", never as 0%. An account with no activity in the current
5-hour window can read as unknown: name it explicitly (`-Account B`) to open it anyway.
