function Test-StopLine {
    # Returns a stop reason for a stream-json line that means the account hit a usage limit.
    param([string] $Line)
    if (-not $Line.StartsWith('{')) { return $null }
    try { $event = $Line | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
    $type = $event.PSObject.Properties['type']?.Value
    if ($type -eq 'rate_limit_event') {
        $info = $event.PSObject.Properties['rate_limit_info']?.Value
        if ($info -is [pscustomobject] -and $info.PSObject.Properties['status']?.Value -eq 'rejected') {
            return 'RateLimited'
        }
    }
    if ($type -eq 'system' -and $event.PSObject.Properties['subtype']?.Value -eq 'api_retry' -and
        $event.PSObject.Properties['error']?.Value -eq 'rate_limit') {
        return 'RateLimited'
    }
    $null
}

function ConvertFrom-SessionStream {
    # Summarises the stream-json lines of a finished session: session id, result and outcome.
    param([string[]] $Lines)
    $summary = [ordered]@{ SessionId = $null; NumTurns = $null; ResultText = $null; Outcome = 'Failed'; Reason = 'no result message' }
    foreach ($line in $Lines) {
        if (-not $line.StartsWith('{')) { continue }
        try { $event = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        $props = $event.PSObject.Properties
        if ($props['session_id']?.Value) { $summary.SessionId = $props['session_id'].Value }
        if ($props['type']?.Value -ne 'result') { continue }
        $summary.NumTurns = $props['num_turns']?.Value
        $summary.ResultText = $props['result']?.Value
        $subtype = $props['subtype']?.Value
        if ($subtype -eq 'success' -and $props['is_error']?.Value -eq $false) {
            $summary.Outcome = 'Completed'; $summary.Reason = $null
        } elseif ($subtype -eq 'error_max_turns') {
            $summary.Outcome = 'MaxTurns'; $summary.Reason = 'reached --max-turns'
        } else {
            $summary.Outcome = 'Failed'; $summary.Reason = "result $subtype"
        }
    }
    [pscustomobject]$summary
}
