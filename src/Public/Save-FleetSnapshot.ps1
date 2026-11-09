function Save-FleetSnapshot {
    <#
    .SYNOPSIS
        Writes the account statuses to status.json beside accounts.json, for the Fleet pane and
        other readers.
    .DESCRIPTION
        Schema 1: { schema, updatedAt, directory, accounts: [...] }. Each account holds its name,
        config dir, login (status, method, plan, tier, expiry, the command that logs it in
        again), usage (status, 5-hour and weekly percent and resets, reason), caps, the cap
        decision, readiness and Remote Control. Nothing else from the account is written: no
        email, organization, ids or credentials. The file is swapped in whole, so a reader never
        sees half of it. Session heartbeats in live/ untouched for a day are deleted.
    .OUTPUTS
        The path written.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Statuses,
        [string] $ConfigPath = (Get-SwitchConfigPath),
        [DateTimeOffset] $Now = [DateTimeOffset]::Now
    )

    $folder = Split-Path -Parent ([IO.Path]::GetFullPath($ConfigPath))
    $path = Join-Path $folder 'status.json'
    $snapshot = [ordered]@{
        schema    = 1
        updatedAt = Format-IsoTime $Now
        directory = @($Statuses | Select-Object -First 1).Directory
        accounts  = @($Statuses | ForEach-Object { ConvertTo-FleetAccount $_ })
    }
    if (-not $PSCmdlet.ShouldProcess($path, 'Write the account status snapshot')) { return $path }
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    $temp = "$path.$PID.tmp"
    [IO.File]::WriteAllText($temp, ($snapshot | ConvertTo-Json -Depth 6), [System.Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temp, $path, $true)
    # The snapshot is written; the history and the clean-up are extras that must not fail it.
    try { Add-UsageHistory -Path (Join-Path $folder 'usage-history.jsonl') -Statuses $Statuses -Now $Now }
    catch { Write-Warning "Could not update usage-history.jsonl: $($_.Exception.Message)" }
    try { Remove-StaleFleetBeat -LiveDir (Join-Path $folder 'live') -Now $Now }
    catch { Write-Warning "Could not clean old heartbeats: $($_.Exception.Message)" }
    $path
}

function Add-UsageHistory {
    <#
      One JSON line per account with known usage: {at, name, fiveHour, fiveHourResetsAt, weekly,
      weeklyResetsAt}. Lines older than 8 days (one weekly window and a day) are dropped, and the
      file is swapped in whole. The Fleet pane fits its forecast to these samples.
    #>
    param([Parameter(Mandatory)] [string] $Path, [AllowEmptyCollection()] [object[]] $Statuses, [DateTimeOffset] $Now = [DateTimeOffset]::Now)
    $fresh = @($Statuses | Where-Object { $_.UsageStatus -eq 'Known' } | ForEach-Object {
            [ordered]@{
                at               = Format-IsoTime $Now
                name             = $_.Name
                fiveHour         = $_.FiveHourPercent
                fiveHourResetsAt = Format-IsoTime $_.ResetsAt
                weekly           = $_.WeeklyPercent
                weeklyResetsAt   = Format-IsoTime $_.WeeklyResetsAt
            } | ConvertTo-Json -Compress
        })
    if ($fresh.Count -eq 0) { return }
    $limit = $Now.AddDays(-8)
    $kept = [System.Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        foreach ($line in [IO.File]::ReadAllLines($Path)) {
            if ($line -notmatch '^\{"at":"(?<at>[^"]+)"') { continue }
            $at = [DateTimeOffset]::MinValue
            if ([DateTimeOffset]::TryParse($Matches.at, [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$at) -and $at -ge $limit) {
                $kept.Add($line)
            }
        }
    }
    $kept.AddRange([string[]]$fresh)
    $temp = "$Path.$PID.tmp"
    [IO.File]::WriteAllLines($temp, $kept, [System.Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temp, $Path, $true)
}

function Remove-StaleFleetBeat {
    <# Deletes session heartbeats (live/*.json, written by the Fleet mod) untouched for a day. #>
    param([Parameter(Mandatory)] [string] $LiveDir, [DateTimeOffset] $Now = [DateTimeOffset]::Now, [int] $MaxAgeHours = 24)
    if (-not (Test-Path -LiteralPath $LiveDir -PathType Container)) { return }
    $limit = $Now.UtcDateTime.AddHours(-$MaxAgeHours)
    Get-ChildItem -LiteralPath $LiveDir -Filter '*.json' -File |
        Where-Object { $_.LastWriteTimeUtc -lt $limit } |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
}

function ConvertTo-FleetAccount {
    param([Parameter(Mandatory)] $Status)
    [ordered]@{
        name          = $Status.Name
        configDir     = $Status.ConfigDir
        isDefault     = [bool]$Status.IsDefaultConfigDir
        auth          = [ordered]@{
            status       = $Status.AuthStatus
            method       = $Status.AuthMethod
            plan         = $Status.Plan
            tier         = $Status.PlanTier
            expiresAt    = Format-IsoTime $Status.LoginExpiresAt
            loginCommand = $Status.LoginCommand
        }
        usage         = [ordered]@{
            status          = $Status.UsageStatus
            fiveHourPercent = $Status.FiveHourPercent
            resetsAt        = Format-IsoTime $Status.ResetsAt
            weeklyPercent   = $Status.WeeklyPercent
            weeklyResetsAt  = Format-IsoTime $Status.WeeklyResetsAt
        }
        caps          = [ordered]@{ fiveHour = $Status.MaxFiveHourPercent; weekly = $Status.MaxWeeklyPercent }
        decision      = $Status.Decision
        reason        = $Status.Reason
        retryAfter    = Format-IsoTime $Status.RetryAfter
        onboarding    = $Status.Onboarding
        available     = [bool]$Status.Available
        remoteControl = [bool]$Status.RemoteControl
    }
}

function Format-IsoTime {
    param($When)
    if ($null -eq $When) { return $null }
    ([DateTimeOffset]$When).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [cultureinfo]::InvariantCulture)
}
