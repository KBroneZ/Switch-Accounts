<#
.SYNOPSIS
    PreToolUse hook: stops the Claude Code session when the account reaches its 5-hour cap.
.DESCRIPTION
    Installed per session by Invoke-AccountSession through --settings; it never edits the
    user's settings files. It re-reads usage at most every IntervalMinutes (state in
    StatePath). When the cap is reached, or usage cannot be read, it prints
    {"continue": false, "stopReason": ...}, which stops the session before the next model call.
    Overshoot is bounded by what the session spends in one interval plus the current turn.
#>
param(
    [Parameter(Mandatory)] [string] $ConfigDir,
    [Parameter(Mandatory)] [double] $MaxFiveHourPercent,
    [Parameter(Mandatory)] [string] $StatePath,
    [string] $ClaudePath = 'claude',
    [double] $IntervalMinutes = 5
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

try {
    [void][Console]::In.ReadToEnd()  # hook input is not needed
    $state = if (Test-Path -LiteralPath $StatePath) { Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json } else { $null }
    if ($state -and $state.Decision -eq 'Allow' -and
        ([DateTimeOffset]::Now - (ConvertTo-Offset $state.LastCheck)).TotalMinutes -lt $IntervalMinutes) {
        exit 0
    }
    if ($state -and $state.Decision -ne 'Allow') {
        Write-Stop $state.Reason
        exit 0
    }

    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'SwitchAccounts.psd1') -Force
    $usage = Get-AccountUsage -ConfigDir $ConfigDir -ClaudePath $ClaudePath
    $cap = Test-UsageCap -Usage $usage -MaxFiveHourPercent $MaxFiveHourPercent
    @{ Decision = $cap.Decision; Reason = $cap.Reason; LastCheck = [DateTimeOffset]::Now.ToString('o') } |
        ConvertTo-Json | Set-Content -LiteralPath $StatePath
    if ($cap.Decision -ne 'Allow') { Write-Stop $cap.Reason }
    exit 0
} catch {
    Write-Stop "usage guard failed, stopping to be safe: $($_.Exception.Message)"
    exit 0
}
