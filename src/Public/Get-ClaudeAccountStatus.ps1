function Get-ClaudeAccountStatus {
    <#
    .SYNOPSIS
        Lists the configured accounts with their login, 5-hour and weekly usage, caps, reset
        times and whether each one can open a session in a folder.
    .DESCRIPTION
        The login comes from Get-AccountAuth (`claude auth status --json`) and the usage from
        Get-AccountUsage (`claude -p /usage`); neither makes a model request. An account that is
        logged out is not asked for /usage: it is Unknown with a reason that says how to log in.
        Accounts are read in parallel. Ready means the account finished its first start and
        trusts the folder; Available means Ready, logged in (or login unknown) and below its caps.
        Unknown usage is never treated as 0: such an account is not Available.
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
    $readings = if ($SkipUsage) { @{} } else { Read-AccountHealth -Accounts $accounts -ClaudePath $cli }

    foreach ($account in $accounts) {
        $reading = $readings[$account.Name]
        $missing = if ($SkipUsage) { 'not read (-SkipUsage)' } else { 'not read (no answer for this account)' }
        $auth = if ($reading) { $reading.Auth } else { New-AuthResult -Status Unknown -Reason "login $missing" }
        $usage = if ($reading) { $reading.Usage } else { New-UsageResult -Reason "usage $missing" }
        $capArgs = @{ MaxFiveHourPercent = $account.MaxFiveHourPercent }
        if ($null -ne $account.MaxWeeklyPercent) { $capArgs.MaxWeeklyPercent = $account.MaxWeeklyPercent }
        $decision = Test-UsageCap -Usage $usage @capArgs
        $state = Get-AccountReadiness -Account $account -WorkingDirectory $folder
        [pscustomobject]@{
            Name               = $account.Name
            ConfigDir          = $account.ConfigDir
            IsDefaultConfigDir = $account.IsDefaultConfigDir
            AuthStatus         = $auth.Status
            AuthMethod         = $auth.Method
            Plan               = $auth.Plan
            PlanTier           = $auth.Tier
            LoginExpiresAt     = $auth.ExpiresAt
            LoginCommand       = Get-LoginCommand -Account $account
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
            Available          = $state -eq 'Ready' -and $decision.Decision -eq 'Allow' -and $auth.Status -ne 'LoggedOut'
            RemoteControl      = $account.RemoteControl
            DefaultModel       = $account.DefaultModel
            DefaultEffort      = $account.DefaultEffort
            Directory          = $folder
            Line               = Format-AccountStatusLine -Account $account -Auth $auth -Usage $usage -Decision $decision -State $state
        }
    }
}

function Read-AccountHealth {
    <#
      Login and usage of each account, keyed by name. One account is read in this runspace; several
      are read side by side (each /usage call takes seconds), each in a runspace of its own that
      imports this module again, since module-private functions do not cross runspaces.
    #>
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Accounts, [Parameter(Mandatory)] [string] $ClaudePath)
    $result = @{}
    if ($Accounts.Count -eq 0) { return $result }
    if ($Accounts.Count -eq 1) {
        $result[$Accounts[0].Name] = Read-OneAccountHealth -ConfigDir $Accounts[0].ConfigDir -ClaudePath $ClaudePath
        return $result
    }
    $manifest = Join-Path $PSScriptRoot '..' 'SwitchAccounts.psd1'
    $items = $Accounts | ForEach-Object { [pscustomobject]@{ Name = $_.Name; ConfigDir = $_.ConfigDir } }
    $rows = $items | ForEach-Object -ThrottleLimit ([Math]::Min(8, $Accounts.Count)) -Parallel {
        $item = $_
        try {
            Import-Module $using:manifest
            $module = Get-Module SwitchAccounts
            $health = & $module { param($dir, $cli) Read-OneAccountHealth -ConfigDir $dir -ClaudePath $cli } $item.ConfigDir $using:ClaudePath
        } catch {
            # Fail safe and say why: unknown login and usage, with the error as the reason.
            $why = "could not read the account: $($_.Exception.Message)"
            $health = [pscustomobject]@{
                Auth  = [pscustomobject]@{ Status = 'Unknown'; Method = $null; Plan = $null; Tier = $null; ExpiresAt = $null; Reason = $why }
                Usage = [pscustomobject]@{ Status = 'Unknown'; FiveHourPercent = $null; ResetsAt = $null; WeeklyPercent = $null; WeeklyResetsAt = $null; Reason = $why }
            }
        }
        [pscustomobject]@{ Name = $item.Name; Health = $health }
    }
    foreach ($row in $rows) { $result[$row.Name] = $row.Health }
    $result
}

function Read-OneAccountHealth {
    # Login first: a logged-out account is not asked for /usage, whose answer would only mislead.
    param([Parameter(Mandatory)] [string] $ConfigDir, [Parameter(Mandatory)] [string] $ClaudePath)
    $auth = Get-AccountAuth -ConfigDir $ConfigDir -ClaudePath $ClaudePath
    $usage = if ($auth.Status -eq 'LoggedOut') { New-UsageResult -Reason $auth.Reason }
    else { Get-AccountUsage -ConfigDir $ConfigDir -ClaudePath $ClaudePath }
    [pscustomobject]@{ Auth = $auth; Usage = $usage }
}

function Get-LoginCommand {
    <# The PowerShell line that logs this account in again. #>
    param([Parameter(Mandatory)] $Account)
    if ($Account.IsDefaultConfigDir) { 'claude auth login' }
    else { "`$env:CLAUDE_CONFIG_DIR = '$($Account.ConfigDir -replace "'", "''")'; claude auth login; Remove-Item Env:CLAUDE_CONFIG_DIR" }
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
    # "B: 26% of 5 h (cap 80%, resets 2030-01-01 16:30), 3% weekly -> below caps, ready; max, login until 2030-01-20"
    param($Account, $Auth, $Usage, $Decision, [string] $State)
    if ($Auth -and $Auth.Status -eq 'LoggedOut') {
        return "$($Account.Name): not logged in (login expired?), not available. Log in again: $(Get-LoginCommand -Account $Account)"
    }
    if ($Usage.Status -ne 'Known') { return "$($Account.Name): usage unknown, not available ($($Usage.Reason))" }
    $weekly = if ($null -ne $Usage.WeeklyPercent) { "$($Usage.WeeklyPercent)% weekly" } else { 'weekly unknown' }
    $caps = "cap $($Account.MaxFiveHourPercent)%"
    if ($null -ne $Account.MaxWeeklyPercent) { $caps += ", weekly cap $($Account.MaxWeeklyPercent)%" }
    $verdict = switch ($Decision.Decision) { 'Allow' { 'below caps' } 'Wait' { 'at a cap' } default { 'not available' } }
    $ready = if ($State -eq 'Ready') { 'ready' } else { "not ready ($State)" }
    $line = '{0}: {1}% of 5 h ({2}, resets {3}), {4} -> {5}, {6}' -f $Account.Name, $Usage.FiveHourPercent, $caps,
    (Format-LocalTime $Usage.ResetsAt), $weekly, $verdict, $ready
    if ($Auth -and $Auth.Status -eq 'LoggedIn') {
        $plan = @($Auth.Tier, $Auth.Plan | Where-Object { $_ })[0]
        $until = if ($Auth.ExpiresAt) { "login until $(Format-LocalTime $Auth.ExpiresAt)" } else { $null }
        $extra = @($plan, $until | Where-Object { $_ }) -join ', '
        if ($extra) { $line += "; $extra" }
    }
    $line
}
