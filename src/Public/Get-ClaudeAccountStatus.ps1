function Get-ClaudeAccountStatus {
    <#
    .SYNOPSIS
        Lists the configured accounts with their 5-hour and weekly usage, caps, reset times and
        whether each one can open a session in a folder.
    .DESCRIPTION
        Usage comes from Get-AccountUsage (`claude -p /usage`, no model request). Ready means the
        account finished its first start and trusts the folder; Available means Ready and
        below its caps. Unknown usage is never treated as 0: such an account is not Available.
        Only hasCompletedOnboarding and the folder trust mark are read from .claude.json.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string[]] $Name,
        [string] $Directory = (Get-Location).Path,
        [string] $ConfigPath = (Get-SwitchConfigPath),
        [string] $ClaudePath,
        [switch] $SkipUsage
    )

    $config = Get-SwitchAccountConfig -ConfigPath $ConfigPath -NoCreate
    $folder = [IO.Path]::GetFullPath($Directory)
    $cli = Resolve-ClaudePath -Override $ClaudePath -Configured $config.ClaudePath
    $accounts = @($config.Accounts | Where-Object { -not $Name -or $Name -contains $_.Name })
    foreach ($account in $accounts) {
        $usage = if ($SkipUsage) { New-UsageResult -Reason 'usage not read (-SkipUsage)' }
        else { Get-AccountUsage -ConfigDir $account.ConfigDir -ClaudePath $cli }
        $capArgs = @{ MaxFiveHourPercent = $account.MaxFiveHourPercent }
        if ($null -ne $account.MaxWeeklyPercent) { $capArgs.MaxWeeklyPercent = $account.MaxWeeklyPercent }
        $decision = Test-UsageCap -Usage $usage @capArgs
        $state = Get-AccountReadiness -Account $account -WorkingDirectory $folder
        [pscustomobject]@{
            Name               = $account.Name
            ConfigDir          = $account.ConfigDir
            IsDefaultConfigDir = $account.IsDefaultConfigDir
            FiveHourPercent    = $usage.FiveHourPercent
            ResetsAt           = $usage.ResetsAt
            WeeklyPercent      = $usage.WeeklyPercent
            WeeklyResetsAt     = $usage.WeeklyResetsAt
            MaxFiveHourPercent = $account.MaxFiveHourPercent
            MaxWeeklyPercent   = $account.MaxWeeklyPercent
            UsageStatus        = $usage.Status
            Decision           = $decision.Decision
            Reason             = $decision.Reason
            RetryAfter         = $decision.RetryAfter
            Onboarding         = $state
            Ready              = $state -eq 'Ready'
            Available          = $state -eq 'Ready' -and $decision.Decision -eq 'Allow'
            RemoteControl      = $account.RemoteControl
            DefaultModel       = $account.DefaultModel
            DefaultEffort      = $account.DefaultEffort
            Directory          = $folder
            Line               = Format-AccountStatusLine -Account $account -Usage $usage -Decision $decision -State $state
        }
    }
}

function Resolve-ClaudePath {
    <# -ClaudePath, then claudePath of the config, then the CLI found on this machine, else 'claude'. #>
    param([string] $Override, [string] $Configured)
    if ($Override) { return $Override }
    if ($Configured) { return $Configured }
    $found = Find-ClaudeCli
    if ($found) { $found } else { 'claude' }
}

function Format-LocalTime {
    param($When)
    if ($When) { ([DateTimeOffset]$When).ToLocalTime().ToString('yyyy-MM-dd HH:mm') } else { 'unknown' }
}

function Format-AccountStatusLine {
    # "B: 26% of 5 h (cap 80%, resets 2030-01-01 16:30), 3% weekly -> ready"
    param($Account, $Usage, $Decision, [string] $State)
    if ($Usage.Status -ne 'Known') { return "$($Account.Name): usage unknown, not available ($($Usage.Reason))" }
    $weekly = if ($null -ne $Usage.WeeklyPercent) { "$($Usage.WeeklyPercent)% weekly" } else { 'weekly unknown' }
    $caps = "cap $($Account.MaxFiveHourPercent)%"
    if ($null -ne $Account.MaxWeeklyPercent) { $caps += ", weekly cap $($Account.MaxWeeklyPercent)%" }
    $verdict = switch ($Decision.Decision) { 'Allow' { 'below caps' } 'Wait' { 'at a cap' } default { 'not available' } }
    $ready = if ($State -eq 'Ready') { 'ready' } else { "not ready ($State)" }
    '{0}: {1}% of 5 h ({2}, resets {3}), {4} -> {5}, {6}' -f $Account.Name, $Usage.FiveHourPercent, $caps,
    (Format-LocalTime $Usage.ResetsAt), $weekly, $verdict, $ready
}
