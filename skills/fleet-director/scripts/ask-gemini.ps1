<#
.SYNOPSIS
    Asks Gemini (Antigravity's CLI, `agy`) a read-only question and saves the answer for Claude to verify.
.DESCRIPTION
    Runs `agy -p` in plan mode with its sandbox on: the model can read the folder it runs in but
    cannot write files or run commands that change anything. Without -Directory it runs in an empty
    folder and sees only the prompt. A -Directory that holds secret-looking files (.env, keys,
    credentials) is refused: point it at a subfolder or put what it needs in the prompt.
    The answer goes to -Out with a header marking it unverified (status: UNVERIFIED). Uses the user's own Antigravity
    sign-in and Google AI plan quota.

    Several Google accounts: with ~/.claude-switch/gemini-accounts.json, -Account <name|auto> picks the
    Google account (an aisw profile) the call uses; the default is auto, the account with the most room
    for the model in its usage windows (unknown usage never counts as 0 %: an account whose usage is
    unknown or old is read first). Under gemini.lock the script switches with `aisw use antigravity
    <profile>`, checks the switch, runs agy, reads that account's usage again and puts the default
    account back. An account that is unavailable (aisw or its profile missing, a switch that does not
    check out) stops the call; it is never replaced by another account. Without the file, agy runs with
    whatever account is live and -Account is refused.

    Exit codes: 0 saved, 1 bad arguments, 2 blocked (a secret-looking prompt or folder),
    3 agy failed, timed out or answered with an error (or no account has room left),
    4 another Gemini run holds the lock, 5 agy not found, 6 the Google account is unavailable.
.EXAMPLE
    pwsh -NoProfile -File ask-gemini.ps1 -Prompt "Resume estos logs" -Out answers/logs.md -Directory C:/repo/logs
.EXAMPLE
    pwsh -NoProfile -File ask-gemini.ps1 -PromptFile task.md -Out answers/review.md -Model claude-opus-4-6-thinking -Effort high
#>
[CmdletBinding()]
param(
    [string] $Prompt,
    [string] $PromptFile,
    [Parameter(Mandatory)] [string] $Out,
    # An `agy models` id: gemini-3.8-flash-high, claude-opus-4-6-thinking, gpt-oss-120b-medium…
    [string] $Model = 'gemini-3.8-flash-high',
    [string] $Effort,
    # The folder Gemini may read. Empty: none (an empty scratch folder).
    [string] $Directory,
    [int] $TimeoutSeconds = 900,
    [string] $AgyPath,
    # A Google account of gemini-accounts.json, or auto (default there): the account with the most room.
    [string] $Account,
    [string] $AiswPath,
    [string] $ConfigPath,
    [string] $DataDir,
    # How long to wait for another Gemini run to release the account lock.
    [int] $LockWaitSeconds = 120,
    # Skip reading the account's usage again after the call (it is one /usage call).
    [switch] $NoUsageRefresh
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'gemini-accounts.ps1')

# Above this the prompt goes to a file the model reads (Windows caps a command line near 32 K).
$InlineLimit = 20000
# agy gets this long past its own --print-timeout before the process is killed.
$KillGraceSeconds = 60
$SecretPatterns = [ordered]@{
    'openai_key'          = 'sk-[A-Za-z0-9_\-]{20,}'
    'aws_access_key'      = 'AKIA[0-9A-Z]{16}'
    'github_token'        = 'gh[pousr]_[A-Za-z0-9]{30,}'
    'google_api_key'      = 'AIza[0-9A-Za-z_\-]{30,}'
    'slack_token'         = 'xox[abprs]-[A-Za-z0-9\-]{10,}'
    'private_key'         = '-----BEGIN [A-Z ]*PRIVATE KEY-----'
    'bearer_token'        = '(?i)bearer\s+[A-Za-z0-9\-._~+/]{20,}=*'
    'password_assignment' = '(?i)(password|passwd|pwd|secret|api[_-]?key)\s*[:=]\s*\S{6,}'
}
# File names that usually hold secrets; a folder with one of them (3 levels down) is not shared.
$SecretFiles = '^(\.env(\.(?!example$|sample$|template$|dist$)[\w.-]+)?|.*\.(pem|key|pfx|p12|keystore|jks)|id_(rsa|dsa|ecdsa|ed25519)(\.pub)?|\.?credentials(\.json)?|\.netrc|\.npmrc|\.pypirc|secrets?\.(json|ya?ml|toml))$'
$SkipFolders = 'node_modules', '.git', '.venv', 'venv', 'dist', 'build', '.next', 'target'

function Stop-With([int] $Code, [string] $Message) {
    [Console]::Error.WriteLine($Message)
    exit $Code
}

function Find-SecretFile([string] $Root) {
    $queue = [System.Collections.Generic.Queue[object]]::new()
    $queue.Enqueue(@($Root, 0))
    while ($queue.Count -gt 0) {
        $dir, $depth = $queue.Dequeue()
        foreach ($item in Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue) {
            if ($item.PSIsContainer) {
                if ($depth -lt 3 -and $item.Name -notin $SkipFolders) { $queue.Enqueue(@($item.FullName, ($depth + 1))) }
            } elseif ($item.Name -match $SecretFiles) {
                return $item.FullName
            }
        }
    }
    $null
}

function ConvertFrom-AgyOutput([string] $Text) {
    # The whole output first (in case agy pretty-prints it), else its last JSON line.
    foreach ($candidate in @($Text.Trim(), @($Text -split "`r?`n" | Where-Object { $_.TrimStart().StartsWith('{') })[-1])) {
        if ($candidate -and $candidate.TrimStart().StartsWith('{')) {
            try { return $candidate | ConvertFrom-Json } catch { }
        }
    }
    $null
}

if (-not $Prompt -and -not $PromptFile) { Stop-With 1 'Missing -Prompt or -PromptFile.' }
if ($Prompt -and $PromptFile) { Stop-With 1 'Use -Prompt or -PromptFile, not both.' }
if ($Model -notmatch '^[a-z0-9][a-z0-9.\-]{0,59}$') { Stop-With 1 "Invalid model: $Model (use an id from 'agy models')." }
if ($Effort -and $Effort -notin 'low', 'medium', 'high', 'max') { Stop-With 1 "Invalid effort: $Effort (low, medium, high or max)." }
if ($TimeoutSeconds -lt 30 -or $TimeoutSeconds -gt 7200) { Stop-With 1 'TimeoutSeconds goes from 30 to 7200.' }
if ($Directory -and -not (Test-Path -LiteralPath $Directory -PathType Container)) { Stop-With 1 "Folder not found: $Directory" }
if ($Account -and $Account -ne 'auto' -and $Account -notmatch $script:GeminiNamePattern) { Stop-With 1 "Invalid account: $Account (a name of gemini-accounts.json, or auto)." }
if (-not $DataDir) { $DataDir = Get-GeminiDataDir }
try {
    $config = Get-GeminiAccountConfig -Path $(if ($ConfigPath) { $ConfigPath } else { Join-Path $DataDir 'gemini-accounts.json' })
} catch { Stop-With (Get-GeminiExitCode $_) $_.Exception.Message }
if (-not $config -and $Account) { Stop-With 1 "-Account needs ~/.claude-switch/gemini-accounts.json (the Google accounts); there is none." }

if ($PromptFile) {
    if (-not (Test-Path -LiteralPath $PromptFile -PathType Leaf)) { Stop-With 1 "File not found: $PromptFile" }
    $Prompt = Get-Content -LiteralPath $PromptFile -Raw
}
foreach ($name in $SecretPatterns.Keys) {
    if ($Prompt -match $SecretPatterns[$name]) { Stop-With 2 "Blocked: the prompt looks like it carries a secret ($name). Remove it and try again." }
}
if ($Directory) {
    $found = Find-SecretFile -Root (Resolve-Path -LiteralPath $Directory).Path
    if ($found) { Stop-With 2 "Blocked: the folder holds a file that may keep secrets ($found). Use a subfolder without it, or put what Gemini needs in the prompt." }
}

if (-not $AgyPath) {
    $local = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $HOME 'AppData' 'Local' }
    $AgyPath = Join-Path $local 'agy' 'bin' 'agy.exe'
}
if (-not (Test-Path -LiteralPath $AgyPath -PathType Leaf)) { Stop-With 5 "agy not found at $AgyPath. Install Antigravity CLI or pass -AgyPath." }

# Several Google accounts: the account, chosen and made live under the lock (released in the last finally).
$lock = $null
$aisw = $null
$agyDir = Split-Path -Parent ([IO.Path]::GetFullPath($AgyPath))
$chosen = $null
$hasRunAgy = $false
if ($config) {
    $aisw = Find-Aisw -Override $AiswPath -Config $config
    if (-not $aisw) { Stop-With 6 'Google accounts are unavailable: aisw was not found (put it on PATH, in ~/.aisw/bin, or set aiswPath in gemini-accounts.json).' }
    try {
        $lock = Enter-GeminiLock -Path (Join-Path $DataDir 'gemini.lock') -WaitSeconds $LockWaitSeconds
        if (-not $Account -or $Account -eq 'auto') {
            $readings = foreach ($candidate in $config.Accounts) {
                $reading = Read-GeminiUsage -DataDir $DataDir -Account $candidate -Model $Model
                $isOld = $reading.ReadAt -and ([DateTimeOffset]::UtcNow - $reading.ReadAt).TotalHours -gt $script:GeminiAutoMaxAgeHours
                if ($null -eq $reading.Room -or $isOld) {
                    # Unknown or old: read it now (one /usage call), never guess.
                    try {
                        Switch-GeminiAccount -Account $candidate -Aisw $aisw -AgyDir $agyDir
                        [void](Update-GeminiUsage -Account $candidate -AgyPath $AgyPath -DataDir $DataDir)
                        $reading = Read-GeminiUsage -DataDir $DataDir -Account $candidate -Model $Model
                    } catch {
                        $reading = [pscustomobject]@{ Account = $candidate; Room = $null; ReadAt = $null; ResetsAt = $null; Why = $_.Exception.Message }
                    }
                }
                $reading
            }
            $readings = @($readings)
            $pick = Select-GeminiAccount -Readings $readings
            foreach ($r in $readings | Where-Object { $null -eq $_.Room -or $_.Room -le 0 }) {
                [Console]::Error.WriteLine("Skipped Google account $($r.Account.Name): $(if ($null -eq $r.Room) { "usage unknown ($($r.Why))" } else { 'no room left' })")
            }
            if (-not $pick) {
                $resets = @($readings | Where-Object { $_.ResetsAt } | ForEach-Object { "$($_.Account.Name) resets $($_.ResetsAt.ToString('u'))" })
                Stop-GeminiAccount 3 "No Google account has known room for $Model.$(if ($resets) { ' ' + ($resets -join '; ') + '.' }) Pass -Account <name> to use one anyway."
            }
            $chosen = $pick.Account
        } else {
            $chosen = Resolve-GeminiAccount -Config $config -Name $Account
        }
        Switch-GeminiAccount -Account $chosen -Aisw $aisw -AgyDir $agyDir
    } catch {
        # Whatever failed after the lock was taken, the default account goes back before the script stops.
        # Without the lock (another run holds it) nothing was switched, and nothing is touched.
        if ($lock) {
            $warning = Restore-GeminiDefaultAccount -Config $config -Aisw $aisw -AgyDir $agyDir
            if ($warning) { [Console]::Error.WriteLine($warning) }
            Exit-GeminiLock $lock
        }
        Stop-With (Get-GeminiExitCode $_) $_.Exception.Message
    }
}

$work = Join-Path ([IO.Path]::GetTempPath()) "ask-gemini-$PID-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
$workspace = Join-Path $work 'workspace'
New-Item -ItemType Directory -Path $workspace -Force | Out-Null
try {
    $agyArgs = [System.Collections.Generic.List[string]]::new()
    if ($Prompt.Length -gt $InlineLimit) {
        $taskDir = Join-Path $work 'task'
        New-Item -ItemType Directory -Path $taskDir | Out-Null
        $taskFile = Join-Path $taskDir 'task.md'
        Set-Content -LiteralPath $taskFile -Value $Prompt -Encoding utf8NoBOM
        $agyArgs.AddRange([string[]]@('-p', "Your whole task is in the file $taskFile. Read it and do what it asks.", '--add-dir', $taskDir))
    } else {
        # A prompt that starts with '-' would read as a flag.
        $agyArgs.AddRange([string[]]@('-p', $(if ($Prompt.TrimStart().StartsWith('-')) { "Task: $Prompt" } else { $Prompt })))
    }
    $agyArgs.AddRange([string[]]@('--mode', 'plan', '--sandbox', '--model', $Model, '--output-format', 'json',
            '--print-timeout', "$($TimeoutSeconds)s", '--log-file', (Join-Path $work 'agy.log')))
    if ($Effort) { $agyArgs.AddRange([string[]]@('--effort', $Effort)) }

    $info = [System.Diagnostics.ProcessStartInfo]::new($AgyPath)
    foreach ($a in $agyArgs) { $info.ArgumentList.Add($a) }
    $info.WorkingDirectory = if ($Directory) { (Resolve-Path -LiteralPath $Directory).Path } else { $workspace }
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.RedirectStandardInput = $true
    $hasRunAgy = $true
    $process = [System.Diagnostics.Process]::Start($info)
    $process.StandardInput.Close()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(($TimeoutSeconds + $KillGraceSeconds) * 1000)) {
        $process.Kill($true)
        Stop-With 3 "agy did not finish in $($TimeoutSeconds + $KillGraceSeconds) s; it was stopped."
    }
    $process.WaitForExit()
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $code = $process.ExitCode

    $answer = ConvertFrom-AgyOutput $stdout
    if ($code -ne 0 -or -not $answer -or $answer.status -ne 'SUCCESS' -or -not $answer.response) {
        $why = if ($answer -and $answer.response) { "$($answer.response)" } else { "$stderr $stdout".Trim() }
        if ($why.Length -gt 600) { $why = $why.Substring($why.Length - 600) }
        Stop-With 3 "agy failed (exit $code): $why"
    }

    $outDir = Split-Path -Parent ([IO.Path]::GetFullPath($Out))
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    $header = @(
        '---'
        'source: Gemini (Antigravity CLI)'
        "model: $Model"
        "effort: $(if ($Effort) { $Effort } else { 'default' })"
        "folder: $(if ($Directory) { $info.WorkingDirectory } else { 'none' })"
        "date: $((Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK'))"
        'status: UNVERIFIED'
        '---'
        ''
    )
    if ($chosen) { $header = $header[0..1] + "account: $($chosen.Name)" + $header[2..($header.Count - 1)] }
    $header = $header -join "`n"
    Set-Content -LiteralPath $Out -Value ($header + $answer.response) -Encoding utf8NoBOM
    Write-Output "Saved: $Out ($Model$(if ($chosen) { "; account: $($chosen.Name)" }); tokens: $($answer.usage.total_tokens))"
    exit 0
} finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    if ($lock) {
        try {
            # The call changed this account's numbers: read them again while its account is still live.
            if ($hasRunAgy -and -not $NoUsageRefresh) { [void](Update-GeminiUsage -Account $chosen -AgyPath $AgyPath -DataDir $DataDir) }
        } catch { [Console]::Error.WriteLine("Could not read the usage of $($chosen.Name) again: $($_.Exception.Message)") }
        $warning = Restore-GeminiDefaultAccount -Config $config -Aisw $aisw -AgyDir $agyDir
        if ($warning) { [Console]::Error.WriteLine($warning) }
        Exit-GeminiLock $lock
    }
}
