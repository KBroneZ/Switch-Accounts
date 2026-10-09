# Which account opens the session, and is it allowed to.

function Get-StatusSummaryText {
    param([Parameter(Mandatory)] [object[]] $Statuses)
    ($Statuses | ForEach-Object { "  $($_.Line)" }) -join "`n"
}

function Stop-WithNoCandidate {
    <# Auto mode found nobody. Exit kind 3 when usage is the reason, 4 when only readiness is. #>
    param([Parameter(Mandatory)] [object[]] $Statuses, [Parameter(Mandatory)] [string] $Directory, [bool] $NeedRemoteControl)
    $allowed = @($Statuses | Where-Object Decision -EQ 'Allow')
    $notReady = @($allowed | Where-Object Onboarding -NE 'Ready')
    if ($notReady.Count -gt 0 -and $notReady.Count -eq $allowed.Count) {
        $advice = ($notReady | ForEach-Object { "  $($_.Name): $(Get-NotReadyAdvice -Account $_ -State $_.Onboarding -Directory $Directory)" }) -join "`n"
        Stop-WithSwitchError NotReady "No account below its caps is ready for this folder:`n$advice"
    }
    if ($allowed.Count -gt 0 -and $NeedRemoteControl) {
        Stop-WithSwitchError NoAccountAvailable "No account below its caps allows Remote Control (remoteControl in accounts.json).`n$(Get-StatusSummaryText $Statuses)"
    }
    $retry = @($Statuses | Where-Object RetryAfter | ForEach-Object { [DateTimeOffset]$_.RetryAfter } | Sort-Object) | Select-Object -First 1
    $when = if ($retry) { "`nEarliest reset: $(Format-LocalTime $retry)." } else { '' }
    Stop-WithSwitchError NoAccountAvailable "No account can start now (cap reached or usage unknown).`n$(Get-StatusSummaryText $Statuses)$when"
}

function Resolve-SessionAccount {
    <#
      Picks the account (auto = least 5-hour usage below its caps) or checks the named one. Returns
      Account (config entry), Status, WillTrust and Warnings. Throws NotReady, NoAccountAvailable
      or InvalidArgument; nothing is changed here.
    #>
    param(
        [Parameter(Mandatory)] $Request, [Parameter(Mandatory)] $Config, [Parameter(Mandatory)] [string] $ConfigPath,
        [string] $ClaudePath, [Parameter(Mandatory)] [string] $CheckDirectory, [bool] $NoUsageCheck
    )
    $warnings = [System.Collections.Generic.List[string]]::new()
    $statusArgs = @{ ConfigPath = $ConfigPath; Directory = $CheckDirectory; ClaudePath = $ClaudePath }
    if ($Request.Account -ieq 'auto') {
        $statuses = @(Get-ClaudeAccountStatus @statusArgs)
        $candidates = @(Get-AutoCandidates -Statuses $statuses -NeedRemoteControl $Request.RemoteControl -TrustDirectory $Request.TrustDirectory)
        $chosen = Select-AvailableAccount -Candidates $candidates
        if (-not $chosen) { Stop-WithNoCandidate -Statuses $statuses -Directory $CheckDirectory -NeedRemoteControl $Request.RemoteControl }
    } else {
        $entry = $Config.Accounts | Where-Object { $_.Name -ieq $Request.Account } | Select-Object -First 1
        if (-not $entry) {
            Stop-WithSwitchError InvalidArgument "Unknown account '$(Get-ShortText $Request.Account 40)'. Configured: $(($Config.Accounts.Name) -join ', ') (or auto)."
        }
        $chosen = @(Get-ClaudeAccountStatus @statusArgs -Name $entry.Name -SkipUsage:$NoUsageCheck)[0]
        if ($Request.RemoteControl -and -not $chosen.RemoteControl) {
            Stop-WithSwitchError InvalidArgument "Remote Control is turned off for account $($chosen.Name) (remoteControl in accounts.json)."
        }
        if (-not $NoUsageCheck -and $chosen.Decision -ne 'Allow') {
            $warnings.Add("account $($chosen.Name): $($chosen.Reason)")
        }
    }
    $account = $Config.Accounts | Where-Object Name -EQ $chosen.Name | Select-Object -First 1
    $willTrust = $chosen.Onboarding -eq 'Untrusted' -and $Request.TrustDirectory
    if ($chosen.Onboarding -ne 'Ready' -and -not $willTrust) {
        Stop-WithSwitchError NotReady "Account $($chosen.Name) is not ready: $(Get-NotReadyAdvice -Account $account -State $chosen.Onboarding -Directory $CheckDirectory)"
    }
    [pscustomobject]@{ Account = $account; Status = $chosen; WillTrust = $willTrust; Warnings = $warnings.ToArray() }
}
