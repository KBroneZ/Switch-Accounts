<#
.SYNOPSIS
    PreToolUse hook: stops the Claude Code session when the account reaches its 5-hour cap
    (and, optionally, its weekly cap).
.DESCRIPTION
    Installed per session by Invoke-AccountSession through --settings; it never edits the
    user's settings files. It re-reads usage at most every IntervalMinutes (state in
    StatePath), whatever the last decision was, so a session that was stopped can go on
    once the window resets. When a cap is reached, or usage cannot be read, it prints
    {"continue": false, "stopReason": ...}, which stops the session before the next model call.
    Overshoot is bounded by what the session spends in one interval plus the current turn.

    Several sessions of the same account may share one StatePath: the state file is
    replaced atomically and a busy file is retried.
#>
param(
    [Parameter(Mandatory)] [string] $ConfigDir,
    [Parameter(Mandatory)] [double] $MaxFiveHourPercent,
    [Parameter(Mandatory)] [string] $StatePath,
    [string] $ClaudePath = 'claude',
    [double] $IntervalMinutes = 5,
    # 0 = no weekly cap.
    [double] $MaxWeeklyPercent = 0
)
$ErrorActionPreference = 'Stop'

function Write-Stop([string] $Reason) {
    [Console]::Out.Write((@{ continue = $false; stopReason = "Switch-Accounts: $Reason" } | ConvertTo-Json -Compress))
}

function ConvertTo-Offset($Value) {
    # ConvertFrom-Json already turns ISO 8601 strings into DateTime.
    if ($Value -is [datetime]) { return [DateTimeOffset]$Value }
    [DateTimeOffset]::Parse([string]$Value, [cultureinfo]::InvariantCulture)
}

function Invoke-WithRetry([scriptblock] $Action) {
    # Another session of the same account may be replacing the file right now.
    for ($i = 1; ; $i++) {
        try { return & $Action }
        catch [System.IO.IOException] { if ($i -ge 5) { throw }; Start-Sleep -Milliseconds (50 * $i) }
    }
}

function Read-GuardState {
    if (-not (Test-Path -LiteralPath $StatePath)) { return $null }
    # A corrupt state throws: the caller fails closed.
    Invoke-WithRetry { [IO.File]::ReadAllText($StatePath) } | ConvertFrom-Json
}

function Save-GuardState($Decision) {
    $json = @{ Decision = $Decision.Decision; Reason = $Decision.Reason; LastCheck = [DateTimeOffset]::Now.ToString('o') } |
        ConvertTo-Json
    $temp = "$StatePath.$PID.tmp"
    try {
        [IO.File]::WriteAllText($temp, $json)
        Invoke-WithRetry { [IO.File]::Move($temp, $StatePath, $true) }
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
}

try {
    [void][Console]::In.ReadToEnd()  # hook input is not needed
    $state = Read-GuardState
    if ($state -and ([DateTimeOffset]::Now - (ConvertTo-Offset $state.LastCheck)).TotalMinutes -lt $IntervalMinutes) {
        if ($state.Decision -ne 'Allow') { Write-Stop $state.Reason }
        exit 0
    }

    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'SwitchAccounts.psd1') -Force
    $usage = Get-AccountUsage -ConfigDir $ConfigDir -ClaudePath $ClaudePath
    $capArgs = @{ Usage = $usage; MaxFiveHourPercent = $MaxFiveHourPercent }
    if ($MaxWeeklyPercent -gt 0) { $capArgs.MaxWeeklyPercent = $MaxWeeklyPercent }
    $cap = Test-UsageCap @capArgs
    Save-GuardState $cap
    if ($cap.Decision -ne 'Allow') { Write-Stop $cap.Reason }
    exit 0
} catch {
    Write-Stop "usage guard failed, stopping to be safe: $($_.Exception.Message)"
    exit 0
}
