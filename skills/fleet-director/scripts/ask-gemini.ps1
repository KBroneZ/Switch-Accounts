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

    Exit codes: 0 saved, 1 bad arguments, 2 blocked (a secret-looking prompt or folder),
    3 agy failed, timed out or answered with an error, 5 agy not found.
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
    [string] $AgyPath
)
$ErrorActionPreference = 'Stop'

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
                if ($depth -lt 3 -and $item.Name -notin $SkipFolders) { $queue.Enqueue(@($item.FullName, $depth + 1)) }
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
    ) -join "`n"
    Set-Content -LiteralPath $Out -Value ($header + $answer.response) -Encoding utf8NoBOM
    Write-Output "Saved: $Out ($Model; tokens: $($answer.usage.total_tokens))"
    exit 0
} finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}
