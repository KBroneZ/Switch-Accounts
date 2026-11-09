# What each executor can and cannot do

Read this before planning. A task that no executor can finish, or that hides a step only the user
can do, is not planned as if it could run: it is split, rewritten, or listed under "lo que tienes
que hacer tú". When a fact here and `fleet_status` disagree, `fleet_status` wins (it is live).

## The hub (this session)

- A Claude Code session on the hub account. Its own work spends that account's quota: keep it for
  planning, design, hard problems and checking results; hand long implementation to workers.
- Only hub sessions have `fleet_status`, `fleet_open_worker`, `fleet_send`, `fleet_stop_worker`.
- Runs with its own model and effort; the plan cannot change them mid-session.

## Claude workers (`fleet_open_worker`)

- Open a new Windows Terminal tab with Claude Code on another account from `accounts.json` (never
  the hub's, never `auto`), in a folder or a new git worktree of a repository. Windows only.
- The account must be ready: logged in and below its caps. A folder the account has never trusted
  stops the open (the script says so); the user trusts it by opening `claude` there once.
- The worker knows **only its brief**. It cannot see this conversation, the hub's files outside its
  folder, or other workers' work unless the brief points at them.
- It runs under that account's own permission settings. A permission prompt in its tab waits for the
  user; plan tasks that need risky commands (deletes, pushes, installs) as "needs the user".
- At `rolloverPercent` of context (40 % by default) it writes a hand-over and a fresh session of the
  same account carries on. At its account's limit it stops and waits for that account's own reset.
- The hub talks to it with `fleet_send` (delivered when it is idle) and stops it with
  `fleet_stop_worker`. Its state, last reply and context show in `fleet_status`.
- Model: one the account's plan includes. Check the plan in `fleet_status`; on `pro`, plan `sonnet`
  unless you know the plan includes the model you want.
- Two writers never touch the same files: tasks that edit the same files run one after the other,
  or in separate worktrees whose branches the hub merges later, with the user's approval.

## ChatGPT (`ask-chatgpt` skill, Codex CLI)

- Read-only. In `research`, `copy` and `general` it works in an empty folder and sees only the
  prompt. On this machine Codex's sandbox blocks every shell command, so even `review` cannot read
  the repository: put the diff, the file text or the data in the prompt.
- `research` searches the web and can take many minutes: run it in the background.
- No memory between calls; no images; ChatGPT app features (Deep Research, image generation) stay
  manual. Needs `codex login` done by the user.
- Its quota is a ChatGPT plan window (see `fleet_status`); a window near 100 % means no ChatGPT.

## Gemini (`scripts/ask-gemini.ps1`, Antigravity CLI)

- Read-only: plan mode with the sandbox. It reads the `-Directory` folder (or nothing), and its
  writes and commands are refused, so it cannot run tests, git or builds. It does not change files.
- Folders with secret-looking files (`.env`, keys, credentials) are refused: point it at a
  subfolder or put the content in the prompt.
- Models from `agy models`. On the user's plan: Gemini Flash (low, medium, high), Claude Opus 4.6
  and Sonnet 4.6, GPT-OSS 120B. Gemini Pro is not on the list. Two weekly limits: one shared by the
  Gemini models, one shared by the Claude and GPT models.
- Every call costs at least ~50 K input tokens (its own system prompt) and ~20 s, however small the
  task: batch small questions into one call. No memory between calls.
- Web access in this mode is not checked: send web research to ChatGPT.
- Needs Antigravity's sign-in done by the user.

## What no executor does

- Sign-ins, two-factor codes, passwords, payments, accepting terms: the user does them.
- Merging pull requests, force pushes, deleting branches or data: only with the user's yes.
- Anything on another machine, in a GUI app or a browser session of the user's.
- Moving work from one Claude account to the other because of a limit.

## A brief that gets finished

Every brief (worker) and every prompt (ChatGPT, Gemini) stands on its own. It says:

1. **Goal** in one sentence, and what "done" means (tests pass, file written, PR open, answer in a
   given format).
2. **Where**: the absolute folder, the branch or worktree, the files or area to work on.
3. **What is already decided** and what must not change (APIs, files to leave alone, the project's
   rules in `CLAUDE.md` the worker must follow).
4. **How to check it**: the exact commands (tests, build, lint) and what their output should be.
5. **What to deliver and where**: the branch and commit, the PR, or the answer file path; and a
   last line saying it is finished, so `fleet_status` shows it.
6. **What to do when stuck**: stop and say why in its last reply, rather than guess.
7. For ChatGPT and Gemini: all the text they need (they cannot open the repository), the answer
   format, and that their answer will be checked.
