function Invoke-AccountSession {
    <#
    .SYNOPSIS
        Runs one non-interactive Claude Code session with one account, inside its usage cap.
    .DESCRIPTION
        1. Reads the account's 5-hour usage; does not start when the cap is reached (CapWait)
           or usage is unknown (UsageUnknown).
        2. Runs `claude -p` with the prompt on stdin, stream-json output, --max-turns, a
           permission mode that never skips permissions, --permission-prompts none, and the
           usage guard as a PreToolUse hook passed through --settings (this session only).
        3. Kills the session on a rate-limit rejection or when it runs past TimeoutMinutes.
    .OUTPUTS
        Account, Outcome (Completed | MaxTurns | Failed | CapWait | UsageUnknown | CapReached |
        RateLimited | TimedOut), Reason, RetryAfter, SessionId, NumTurns, ResultText, StartedAt, EndedAt.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Account,
        [Parameter(Mandatory)] [string] $WorkingDirectory,
        [Parameter(Mandatory)] [string] $Prompt,
        [Parameter(Mandatory)] [string] $StateDir,
        [ValidateRange(1, 500)] [int] $MaxTurns = 30,
        [ValidateRange(0.01, 1440)] [double] $TimeoutMinutes = 60,
        [string[]] $AllowedTools = @('Read', 'Glob', 'Grep'),
        [string[]] $DisallowedTools = @(),
        [ValidateSet('dontAsk', 'acceptEdits', 'default', 'plan')] [string] $PermissionMode = 'dontAsk',
        [string] $ClaudePath = 'claude',
        [ValidateRange(1, 60)] [double] $GuardIntervalMinutes = 5
    )

    $startedAt = [DateTimeOffset]::Now
    $base = @{ Account = $Account.Name; StartedAt = $startedAt }
    $usage = Get-AccountUsage -ConfigDir $Account.ConfigDir -ClaudePath $ClaudePath
    $cap = Test-UsageCap -Usage $usage -MaxFiveHourPercent $Account.MaxFiveHourPercent
    if ($cap.Decision -ne 'Allow') {
        $outcome = if ($cap.Decision -eq 'Wait') { 'CapWait' } else { 'UsageUnknown' }
        return New-SessionResult @base -Outcome $outcome -Reason $cap.Reason -RetryAfter $cap.RetryAfter
    }

    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    $guardState = Join-Path $StateDir "guard-$($Account.Name)-$([guid]::NewGuid().ToString('N')).json"
    @{ Decision = 'Allow'; Reason = $cap.Reason; LastCheck = [DateTimeOffset]::Now.ToString('o') } |
        ConvertTo-Json | Set-Content -LiteralPath $guardState

    $arguments = @(
        '-p', '--output-format', 'stream-json', '--verbose',
        '--max-turns', $MaxTurns,
        '--permission-mode', $PermissionMode,
        '--permission-prompts', 'none',
        '--settings', (New-GuardSettings -Account $Account -StatePath $guardState -ClaudePath $ClaudePath -IntervalMinutes $GuardIntervalMinutes)
    )
    # Variadic flags go last, one argument per rule, so rules with spaces stay intact.
    if ($DisallowedTools) { $arguments += @('--disallowedTools') + $DisallowedTools }
    if ($AllowedTools) { $arguments += @('--allowedTools') + $AllowedTools }

    $run = Invoke-StreamingCommand -FilePath $ClaudePath -ArgumentList $arguments -StdIn $Prompt `
        -Environment @{ CLAUDE_CONFIG_DIR = $Account.ConfigDir } -WorkingDirectory $WorkingDirectory `
        -TimeoutSeconds ($TimeoutMinutes * 60) -OnLine { param($line) Test-StopLine -Line $line }

    $summary = ConvertFrom-SessionStream -Lines $run.Lines
    $guard = Get-Content -LiteralPath $guardState -Raw | ConvertFrom-Json
    $outcome = $summary.Outcome
    $reason = $summary.Reason
    if ($guard.Decision -ne 'Allow') { $outcome = 'CapReached'; $reason = $guard.Reason }
    elseif ($run.StoppedBy -eq 'Timeout') { $outcome = 'TimedOut'; $reason = "ran past $TimeoutMinutes min" }
    elseif ($run.StoppedBy) { $outcome = $run.StoppedBy; $reason = 'rate limit reported by the API' }
    elseif ($outcome -eq 'Completed' -and $run.ExitCode -ne 0) { $outcome = 'Failed'; $reason = "exit code $($run.ExitCode)" }

    New-SessionResult @base -Outcome $outcome -Reason $reason -SessionId $summary.SessionId `
        -NumTurns $summary.NumTurns -ResultText $summary.ResultText
}

function New-GuardSettings {
    param($Account, [string] $StatePath, [string] $ClaudePath, [double] $IntervalMinutes)
    $guardScript = Join-Path $PSScriptRoot '..' '..' 'scripts' 'usage-guard.ps1' | Resolve-Path
    $claude = Resolve-ExecutablePath -FilePath $ClaudePath
    $hook = [ordered]@{
        type    = 'command'
        command = (Get-Process -Id $PID).Path
        args    = @('-NoProfile', '-NonInteractive', '-File', $guardScript.Path,
            '-ConfigDir', $Account.ConfigDir, '-MaxFiveHourPercent', [string]$Account.MaxFiveHourPercent,
            '-StatePath', $StatePath, '-ClaudePath', $claude, '-IntervalMinutes', [string]$IntervalMinutes)
        timeout = 120
    }
    @{ hooks = @{ PreToolUse = @(@{ matcher = '*'; hooks = @($hook) }) } } | ConvertTo-Json -Depth 6 -Compress
}

function New-SessionResult {
    param(
        [string] $Account, [DateTimeOffset] $StartedAt, [string] $Outcome, [string] $Reason,
        $RetryAfter = $null, [string] $SessionId, $NumTurns = $null, [string] $ResultText
    )
    [pscustomobject]@{
        Account    = $Account
        Outcome    = $Outcome
        Reason     = $Reason
        RetryAfter = $RetryAfter
        SessionId  = $SessionId
        NumTurns   = $NumTurns
        ResultText = $ResultText
        StartedAt  = $StartedAt
        EndedAt    = [DateTimeOffset]::Now
    }
}
