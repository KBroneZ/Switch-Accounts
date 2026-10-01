function Test-UsageCap {
    <#
    .SYNOPSIS
        Decides whether an account may start a session, given its 5-hour usage and a cap.
    .DESCRIPTION
        Fail-closed: unknown usage is never treated as zero. Returns an object with
        Decision = Allow | Wait | Block, a Reason and, for Wait, RetryAfter (the window
        reset time, or $null when it is unknown).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)] [pscustomobject] $Usage,
        [Parameter(Mandatory)] [ValidateRange(1, 100)] [double] $MaxFiveHourPercent
    )

    $status = $Usage.PSObject.Properties['Status']?.Value
    $percent = $Usage.PSObject.Properties['FiveHourPercent']?.Value
    $resetsAt = $Usage.PSObject.Properties['ResetsAt']?.Value

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
    if ($percent -ge $MaxFiveHourPercent) {
        return New-CapDecision -Decision 'Wait' -RetryAfter $resetsAt `
            -Reason "5-hour usage $percent% has reached the cap of $MaxFiveHourPercent%"
    }
    New-CapDecision -Decision 'Allow' -Reason "5-hour usage $percent% is below the cap of $MaxFiveHourPercent%"
}

function New-CapDecision {
    param([string] $Decision, [string] $Reason, $RetryAfter = $null)
    [pscustomobject]@{
        Decision   = $Decision
        Reason     = $Reason
        RetryAfter = $RetryAfter
    }
}
