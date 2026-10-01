function ConvertFrom-UsageText {
    <#
    .SYNOPSIS
        Extracts the 5-hour ("Current session") usage from the text that `claude -p /usage` prints.
    .DESCRIPTION
        The /usage text is not a documented contract, so the parser is strict: it needs exactly
        one "Current session: NN% used [· resets <when>]" line (the layout of CLI 2.1.284).
        Anything else, stale ("last-known") data and rate-limited answers all return
        Status = Unknown. A missing reset time keeps the percentage (ResetsAt = $null).
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

    $sessionLines = @($Text -split '\r?\n' | Where-Object { $_ -match '^\s*Current session\b' })
    if ($sessionLines.Count -eq 0) { return New-UsageResult -Reason 'no "Current session" line in /usage output' }
    if ($sessionLines.Count -gt 1) { return New-UsageResult -Reason 'more than one "Current session" line in /usage output' }

    $linePattern = '^\s*Current session:\s*(?<p>\d{1,3}(?:\.\d+)?)\s*%\s*used(?:\s*·\s*resets\s+(?<r>.+?))?\s*$'
    if ($sessionLines[0] -notmatch $linePattern) {
        return New-UsageResult -Reason 'no "% used" on the "Current session" line'
    }
    $percent = [double]::Parse($Matches.p, [cultureinfo]::InvariantCulture)
    $resetText = $Matches['r']
    if ($percent -gt 100) { return New-UsageResult -Reason "5-hour percentage out of range ($percent)" }

    [pscustomobject]@{
        Status          = 'Known'
        FiveHourPercent = $percent
        ResetsAt        = if ($resetText) { ConvertFrom-ResetText -Text $resetText -Now $Now } else { $null }
        Reason          = $null
    }
}

function New-UsageResult {
    param([Parameter(Mandatory)] [string] $Reason)
    [pscustomobject]@{
        Status          = 'Unknown'
        FiveHourPercent = $null
        ResetsAt        = $null
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
        if ($candidate -le $local) { $candidate = $candidate.AddYears(1) }
    } else {
        $candidate = [datetime]::new($local.Year, $local.Month, $local.Day, $hour, $minute, 0)
        if ($candidate -le $local) { $candidate = $candidate.AddDays(1) }
    }
    [DateTimeOffset]::new($candidate, $zone.GetUtcOffset($candidate))
}
