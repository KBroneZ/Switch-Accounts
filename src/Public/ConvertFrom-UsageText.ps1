function ConvertFrom-UsageText {
    <#
    .SYNOPSIS
        Extracts the 5-hour ("Current session") and weekly usage from the text that
        `claude -p /usage` prints.
    .DESCRIPTION
        The /usage text is not a documented contract, so the parser is strict: it needs exactly
        one "Current session: NN% used [· resets <when>]" line (the layout of CLI 2.1.284).
        Anything else, stale ("last-known") data and rate-limited answers all return
        Status = Unknown. A missing reset time keeps the percentage (ResetsAt = $null).

        One exception: CLI 2.1.295 prints no limit line at all for an account with no use in the
        window. That exact layout (subscription header and breakdown present, no "Current ..."
        line, no word that signals an error) reads as 0% with no reset time and no weekly value.

        The weekly usage comes from exactly one "Current week (all models): NN% used" line.
        When that line is missing or cannot be read, WeeklyPercent and WeeklyResetsAt are
        $null (unknown) and the 5-hour result does not change.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Text,
        [DateTimeOffset] $Now = [DateTimeOffset]::Now
    )

    if ([string]::IsNullOrWhiteSpace($Text)) { return New-UsageResult -Reason '/usage printed no text' }
    if ($Text -match '(?i)last-known') { return New-UsageResult -Reason '/usage shows last-known (stale) data' }
    if ($Text -match '(?i)rate.limited') { return New-UsageResult -Reason 'usage endpoint is rate limited' }

    $lines = $Text -split '\r?\n'
    $sessionLines = @($lines | Where-Object { $_ -match '^\s*Current session\b' })
    if ($sessionLines.Count -eq 0) {
        if (Test-IdleUsageText -Text $Text) {
            # CLI 2.1.295 leaves the limit lines out when nothing was used in the window.
            return [pscustomobject]@{
                Status = 'Known'; FiveHourPercent = 0; ResetsAt = $null; WeeklyPercent = $null; WeeklyResetsAt = $null; Reason = $null
            }
        }
        return New-UsageResult -Reason 'no "Current session" line in /usage output'
    }
    if ($sessionLines.Count -gt 1) { return New-UsageResult -Reason 'more than one "Current session" line in /usage output' }

    $session = Read-LimitLine -Line $sessionLines[0] -Label 'Current session' -Now $Now
    if (-not $session) { return New-UsageResult -Reason 'no "% used" on the "Current session" line' }
    if ($session.Percent -gt 100) { return New-UsageResult -Reason "5-hour percentage out of range ($($session.Percent))" }

    # The weekly limit is optional: unknown here never changes the 5-hour result.
    $weekly = $null
    $weekLines = @($lines | Where-Object { $_ -match '^\s*Current week \(all models\)' })
    if ($weekLines.Count -eq 1) {
        $weekly = Read-LimitLine -Line $weekLines[0] -Label 'Current week \(all models\)' -Now $Now
        if ($weekly -and $weekly.Percent -gt 100) { $weekly = $null }
    }

    [pscustomobject]@{
        Status          = 'Known'
        FiveHourPercent = $session.Percent
        ResetsAt        = $session.ResetsAt
        WeeklyPercent   = ${weekly}?.Percent
        WeeklyResetsAt  = ${weekly}?.ResetsAt
        Reason          = $null
    }
}

function Read-LimitLine {
    # "<Label>: NN% used [\u00B7 resets <when>]" -> Percent and ResetsAt; $null when it does not match.
    param([string] $Line, [string] $Label, [DateTimeOffset] $Now)
    $pattern = '^\s*' + $Label + ':\s*(?<p>\d{1,3}(?:\.\d+)?)\s*%\s*used(?:\s*\u00B7\s*resets\s+(?<r>.+?))?\s*$'
    if ($Line -notmatch $pattern) { return $null }
    $resetText = $Matches['r']
    [pscustomobject]@{
        Percent  = [double]::Parse($Matches.p, [cultureinfo]::InvariantCulture)
        ResetsAt = if ($resetText) { ConvertFrom-ResetText -Text $resetText -Now $Now } else { $null }
    }
}

function Test-IdleUsageText {
    <#
      True only for the layout of an account with no use in the window: the subscription header
      and the usage breakdown are there, no limit line of any kind is, and nothing says that an
      error happened. Any other text without a "Current session" line stays unknown.
    #>
    param([string] $Text)
    $lines = $Text -split '\r?\n'
    $hasHeader = @($lines | Where-Object { $_ -match '^\s*You are currently using your subscription' }).Count -eq 1
    $hasBreakdown = @($lines | Where-Object { $_ -match "^\s*What's contributing to your limits usage\?" }).Count -eq 1
    $hasLimitLine = @($lines | Where-Object { $_ -match '^\s*Current (session|week)\b' }).Count -gt 0
    $mentionsError = $Text -match '(?i)\b(error|unavailable|failed|unable|log ?in|sign ?in|expired|unauthori[sz]ed|retry)\b'
    $hasHeader -and $hasBreakdown -and -not $hasLimitLine -and -not $mentionsError
}

function New-UsageResult {
    param([Parameter(Mandatory)] [string] $Reason)
    [pscustomobject]@{
        Status          = 'Unknown'
        FiveHourPercent = $null
        ResetsAt        = $null
        WeeklyPercent   = $null
        WeeklyResetsAt  = $null
        Reason          = $Reason
    }
}

function ConvertFrom-ResetText {
    # "4:30pm (Europe/Madrid)", "9am (UTC)", "Oct 9, 9am (UTC)". Returns $null when unsure.
    param([string] $Text, [DateTimeOffset] $Now)
    $pattern = '^(?:(?<mon>[A-Za-z]{3})\s+(?<day>\d{1,2}),?\s+)?(?<h>\d{1,2})(?::(?<m>\d{2}))?\s*(?<ap>am|pm)\s*(?:\((?<tz>[^)]+)\))?$'
    if ($Text -notmatch $pattern) { return $null }

    $parts = $Matches
    $zone = [TimeZoneInfo]::Local
    if ($parts['tz']) {
        try { $zone = [TimeZoneInfo]::FindSystemTimeZoneById($parts['tz']) } catch { return $null }
    }
    $hour = [int]$parts['h'] % 12
    if ($parts['ap'] -eq 'pm') { $hour += 12 }
    $minute = if ($parts['m']) { [int]$parts['m'] } else { 0 }
    if ($hour -gt 23 -or $minute -gt 59) { return $null }

    $local = [TimeZoneInfo]::ConvertTime($Now, $zone).DateTime
    if ($parts['mon']) {
        $months = [cultureinfo]::InvariantCulture.DateTimeFormat.AbbreviatedMonthNames
        $month = 1 + [Array]::FindIndex($months, [Predicate[string]] { param($n) $n -and $n -ieq $parts['mon'] })
        if ($month -lt 1) { return $null }
        try { $candidate = [datetime]::new($local.Year, $month, [int]$parts['day'], $hour, $minute, 0) } catch { return $null }
        # Only a date well in the past means "next year" (Dec -> Jan). /usage prints minutes only,
        # so a reset can look up to a minute old; keep it, and the caller simply reads usage again.
        if ($candidate -lt $local.AddDays(-30)) { $candidate = $candidate.AddYears(1) }
    } else {
        $candidate = [datetime]::new($local.Year, $local.Month, $local.Day, $hour, $minute, 0)
        if ($candidate -le $local) { $candidate = $candidate.AddDays(1) }
    }
    [DateTimeOffset]::new($candidate, $zone.GetUtcOffset($candidate))
}
