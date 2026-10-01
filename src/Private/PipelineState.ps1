function Read-PipelineState {
    param([string] $StateDir)
    $path = Join-Path $StateDir 'state.json'
    if (-not (Test-Path -LiteralPath $path)) { return @{ version = 1; tasks = @{} } }
    $state = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
    if ($state['version'] -ne 1 -or $state['tasks'] -isnot [hashtable]) { throw "Unrecognised pipeline state file: $path" }
    $state
}

function Save-PipelineState {
    # Writes state.json through a temporary file so a crash never leaves half a file.
    param([string] $StateDir, [hashtable] $State)
    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    $path = Join-Path $StateDir 'state.json'
    $temp = "$path.tmp"
    $State | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $temp
    Move-Item -LiteralPath $temp -Destination $path -Force
}

function Set-TaskRecord {
    param([hashtable] $State, [string] $Id, [hashtable] $Values)
    if (-not $State.tasks.ContainsKey($Id)) { $State.tasks[$Id] = @{ started = [DateTimeOffset]::Now.ToString('o'); rounds = 0 } }
    foreach ($key in $Values.Keys) { $State.tasks[$Id][$key] = $Values[$key] }
    $State.tasks[$Id]['updated'] = [DateTimeOffset]::Now.ToString('o')
}

function Get-TasksStartedToday {
    param([hashtable] $State)
    $today = [DateTimeOffset]::Now.Date
    @($State.tasks.Values | Where-Object {
            $started = $_['started']
            $when = if ($started -is [datetime]) { [DateTimeOffset]$started } else { [DateTimeOffset]::Parse([string]$started, [cultureinfo]::InvariantCulture) }
            $when.ToLocalTime().Date -eq $today
        }).Count
}

function Add-RunLog {
    # One JSON line per session attempt.
    param([string] $StateDir, [string] $Role, [string] $Task, $Session, $Pr)
    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    $entry = [ordered]@{
        time    = [DateTimeOffset]::Now.ToString('o')
        task    = $Task
        role    = $Role
        account = $Session.Account
        outcome = $Session.Outcome
        reason  = $Session.Reason
        turns   = $Session.NumTurns
        started = $Session.StartedAt.ToString('o')
        ended   = $Session.EndedAt.ToString('o')
        pr      = $Pr
    }
    Add-Content -LiteralPath (Join-Path $StateDir 'runs.jsonl') -Value ($entry | ConvertTo-Json -Compress)
}
