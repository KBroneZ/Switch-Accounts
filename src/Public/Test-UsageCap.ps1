function Test-UsageCap {
    <#
    .SYNOPSIS
        Decides whether an account may start a session, given its 5-hour usage and a cap,
        and optionally its weekly usage and a weekly cap.
    .DESCRIPTION
        Fail-closed: unknown usage is never treated as zero. Returns an object with
        Decision = Allow | Wait | Block, a Reason and, for Wait, RetryAfter (the reset time
        of the reached limit, or $null when it is unknown).

        The weekly usage only counts when -MaxWeeklyPercent is given; then an unknown weekly
        usage blocks too. When both caps are reached, RetryAfter is the later reset.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Usage,
        [Parameter(Mandatory)] [ValidateRange(1, 100)] [double] $MaxFiveHourPercent,
        [ValidateRange(1, 100)] [double] $MaxWeeklyPercent
    )

    $status = $Usage.PSObject.Properties['Status']?.Value
    $percent = $Usage.PSObject.Properties['FiveHourPercent']?.Value
    $resetsAt = $Usage.PSObject.Properties['ResetsAt']?.Value
    $useWeekly = $PSBoundParameters.ContainsKey('MaxWeeklyPercent')

    if ($status -ne 'Known') {
        $why = $Usage.PSObject.Properties['Reason']?.Value
        if (-not $why) { $why = 'usage status is not Known' }
        return New-CapDecision -Decision 'Block' -Reason "Usage unknown: $why"
    }
    if ($null -eq $percent) {
        return New-CapDecision -Decision 'Block' -Reason 'Usage unknown: no 5-hour percentage'
    }
    if ($percent -lt 0 -or $percent -gt 100) {
        return New-CapDecision -Decision 'Block' -Reason "Usage unknown: 5-hour percentage out of range ($percent)"
    }

    $reached = [System.Collections.Generic.List[object]]::new()
    if ($percent -ge $MaxFiveHourPercent) {
        $reached.Add(@{ Reason = "5-hour usage $percent% has reached the cap of $MaxFiveHourPercent%"; ResetsAt = $resetsAt })
    }
    if ($useWeekly) {
        $weekly = $Usage.PSObject.Properties['WeeklyPercent']?.Value
        if ($null -eq $weekly) {
            return New-CapDecision -Decision 'Block' -Reason 'Usage unknown: no weekly percentage'
        }
        if ($weekly -lt 0 -or $weekly -gt 100) {
            return New-CapDecision -Decision 'Block' -Reason "Usage unknown: weekly percentage out of range ($weekly)"
        }
        if ($weekly -ge $MaxWeeklyPercent) {
            $reached.Add(@{
                    Reason   = "weekly usage $weekly% has reached the cap of $MaxWeeklyPercent%"
                    ResetsAt = $Usage.PSObject.Properties['WeeklyResetsAt']?.Value
                })
        }
    }

    if ($reached.Count -gt 0) {
        # Both limits must have reset before work can go on: wait for the later one.
        $retry = $null
        if (@($reached | Where-Object { $null -eq $_.ResetsAt }).Count -eq 0) {
            $retry = ($reached | Sort-Object { ([DateTimeOffset]$_.ResetsAt).UtcTicks } | Select-Object -Last 1).ResetsAt
        }
        return New-CapDecision -Decision 'Wait' -RetryAfter $retry -Reason (($reached | ForEach-Object { $_.Reason }) -join '; ')
    }
    $why = "5-hour usage $percent% is below the cap of $MaxFiveHourPercent%"
    if ($useWeekly) { $why += "; weekly usage $weekly% is below the cap of $MaxWeeklyPercent%" }
    New-CapDecision -Decision 'Allow' -Reason $why
}

function New-CapDecision {
    param([string] $Decision, [string] $Reason, $RetryAfter = $null)
    [pscustomobject]@{
        Decision   = $Decision
        Reason     = $Reason
        RetryAfter = $RetryAfter
    }
}
