function Update-TokenLedger {
    <#
    .SYNOPSIS
        Counts the tokens of every account's transcripts and Codex sessions into an append-only
        ledger, and writes the per-day totals the Fleet pane draws.
    .DESCRIPTION
        Claude: every assistant message in <configDir>/projects/**/*.jsonl (subagents included),
        counted once by message id and request id (a message is written several times while it
        streams; resumed sessions copy earlier ones). Codex: the cumulative totals of each session
        in <CODEX_HOME>/sessions (compressed `.jsonl.zst` files need Node 22.15 or later to read).

        The ledger (<StateDir>/ledger.tsv) is only appended to, so totals survive Claude Code
        deleting old transcripts. Files are read from where the last run stopped; a run stops after
        -MaxSeconds and the next one goes on. The first run reads everything there is.

        Writes <SummaryPath> (schema 1): per local day, account and model, the input, output,
        cache write (5 minutes and 1 hour) and cache read tokens. No message text is kept.
    .OUTPUTS
        Status (Done, Partial, Busy), Files (read this run), Added (ledger lines), Skipped (files it
        could not read), SummaryPath.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [string] $StateDir = (Join-Path (Split-Path -Parent (Get-SwitchConfigPath)) 'tokens'),
        [string] $SummaryPath = (Join-Path (Split-Path -Parent (Get-SwitchConfigPath)) 'tokens.json'),
        # Each @{ Account; Kind = 'claude' | 'codex'; Dir }. Default: the accounts of accounts.json,
        # other ~/.claude* config dirs that have transcripts (by folder name), and Codex.
        [object[]] $Sources,
        [string] $ConfigPath = (Get-SwitchConfigPath),
        [string] $NodePath,
        [ValidateRange(5, 3600)] [int] $MaxSeconds = 480,
        [DateTimeOffset] $Now = [DateTimeOffset]::Now
    )
    New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
    # One run at a time, across sessions: the lock goes with the process.
    try {
        $lock = [IO.File]::Open((Join-Path $StateDir '.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    } catch [IO.IOException] {
        return [pscustomobject]@{ Status = 'Busy'; Files = 0; Added = 0; Skipped = 0; SummaryPath = $SummaryPath }
    }
    try {
        if (-not $PSBoundParameters.ContainsKey('Sources')) { $Sources = Get-TokenSources -ConfigPath $ConfigPath }
        if (-not $PSBoundParameters.ContainsKey('NodePath')) { $NodePath = Find-ZstdNode }
        $ledgerPath = Join-Path $StateDir 'ledger.tsv'
        $filesPath = Join-Path $StateDir 'files.json'
        # Temp files a run cut short left behind (the lock says no run is writing them now).
        Get-ChildItem -LiteralPath $StateDir -Filter '*.tmp' -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        Get-ChildItem -LiteralPath (Split-Path -Parent $SummaryPath) -Filter "$(Split-Path -Leaf $SummaryPath).*.tmp" -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        $state = Read-TokenLedger -Path $ledgerPath
        $files = Read-TokenFiles -Path $filesPath
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $added = 0; $read = 0; $skipped = 0; $isPartial = $false; $sinceSave = 0
        $savedAt = 0.0
        $save = {
            Save-TokenLedger -State $state -Path $ledgerPath
            Write-TokenFiles -Path $filesPath -Files $files
        }
        $present = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

        foreach ($source in $Sources) {
            foreach ($file in @(Get-TokenFiles $source)) {
                [void]$present.Add($file.FullName)
                $was = $files[$file.FullName]
                $mtime = $file.LastWriteTimeUtc.Ticks
                if ($was -and $was.s -eq $file.Length -and $was.t -eq $mtime) { continue }
                if ($clock.Elapsed.TotalSeconds -ge $MaxSeconds) { $isPartial = $true; break }
                $offset = if ($was -and $file.Length -ge $was.o) { [long]$was.o } else { [long]0 }
                $model = if ($was -and $was.m) { [string]$was.m } else { 'unknown' }
                $isCodex = $source.Kind -eq 'codex'
                $needles = if ($isCodex) { @('"token_count"', '"turn_context"') } else { @('"usage"') }
                $session = if ($isCodex) { 'codex:' + (Get-CodexSessionId $file.Name) } else { $null }
                $isDone = $true
                do {
                    if ($file.Name.EndsWith('.zst')) {
                        $lines = if ($NodePath) { Expand-ZstdLines -NodePath $NodePath -Path $file.FullName -Needles $needles } else { $null }
                        if ($null -eq $lines) { break }
                        $next = $file.Length
                        $model = 'unknown'
                    } else {
                        $chunk = Read-NewLines -Path $file.FullName -Offset $offset -Needles $needles
                        $lines = $chunk.Lines
                        $next = $chunk.Offset
                        $isDone = $chunk.IsDone
                    }
                    if ($isCodex) {
                        foreach ($line in $lines) {
                            $ev = Read-CodexEvent -Line $line
                            if ($null -eq $ev) { continue }
                            if ($ev.PSObject.Properties['Model']) { $model = $ev.Model; continue }
                            if (Add-TokenUsage -State $state -Key $session -Account $source.Account -Model $model -Day $ev.Day -Usage $ev.Usage) { $added++ }
                        }
                    } else {
                        foreach ($line in $lines) {
                            $u = ConvertFrom-ClaudeUsageLine -Line $line
                            if ($null -eq $u) { continue }
                            if (Add-TokenUsage -State $state -Key $u.Key -Account $source.Account -Model $u.Model -Day $u.Day -Usage $u.Usage) { $added++ }
                        }
                    }
                    # The ledger first: a crash between the two reads the file again, and the keys
                    # already counted add nothing. A file not read to its end keeps no size, so the
                    # next run goes on with it.
                    $files[$file.FullName] = @{ s = if ($isDone) { $file.Length } else { -1 }; t = $mtime; o = $next; m = $model }
                    $offset = $next
                    if (++$sinceSave -ge 25 -or $clock.Elapsed.TotalSeconds - $savedAt -ge 20) {
                        & $save
                        $sinceSave = 0
                        $savedAt = $clock.Elapsed.TotalSeconds
                    }
                    if (-not $isDone -and $clock.Elapsed.TotalSeconds -ge $MaxSeconds) { $isPartial = $true }
                } while (-not $isDone -and -not $isPartial)
                if ($null -eq $lines) { $skipped++; continue }
                $read++
                if ($isPartial) { break }
            }
            if ($isPartial) { break }
        }
        & $save
        # Files that are gone stay counted in the ledger; only their read positions go.
        if (-not $isPartial) { foreach ($p in @($files.Keys)) { if (-not $present.Contains($p)) { $files.Remove($p) } } }
        Write-TokenFiles -Path $filesPath -Files $files
        $notes = @()
        if ($skipped -gt 0 -and -not $NodePath) { $notes += "$skipped compressed Codex sessions not read: they need Node 22.15 or later on PATH" }
        elseif ($skipped -gt 0) { $notes += "$skipped files could not be read" }
        Write-TokenSummary -State $state -Path $SummaryPath -Sources $Sources -IsComplete (-not $isPartial) -Notes $notes -Now $Now
        [pscustomobject]@{ Status = if ($isPartial) { 'Partial' } else { 'Done' }; Files = $read; Added = $added; Skipped = $skipped; SummaryPath = $SummaryPath }
    } finally {
        $lock.Dispose()
    }
}

function Get-TokenSources {
    param([string] $ConfigPath)
    $sources = [Collections.Generic.List[object]]::new()
    $known = [Collections.Generic.HashSet[string]]::new()
    $config = Get-SwitchAccountConfig -ConfigPath $ConfigPath -NoCreate
    foreach ($a in $config.Accounts) {
        $sources.Add([pscustomobject]@{ Account = $a.Name; Kind = 'claude'; Dir = $a.ConfigDir })
        [void]$known.Add((ConvertTo-ComparablePath $a.ConfigDir))
    }
    # A config dir accounts.json no longer lists still holds past use: counted under its folder name.
    foreach ($d in @(Get-ChildItem -LiteralPath $HOME -Directory -Force -Filter '.claude*' -ErrorAction SilentlyContinue)) {
        if ($known.Contains((ConvertTo-ComparablePath $d.FullName))) { continue }
        if ($d.Name -notmatch '^\.claude[A-Za-z0-9._-]*$' -or $d.Name -eq '.claude-switch') { continue }
        if (-not (Test-Path -LiteralPath (Join-Path $d.FullName 'projects') -PathType Container)) { continue }
        $sources.Add([pscustomobject]@{ Account = $d.Name; Kind = 'claude'; Dir = $d.FullName })
    }
    $codex = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
    $sources.Add([pscustomobject]@{ Account = 'ChatGPT'; Kind = 'codex'; Dir = $codex })
    $sources
}

function Get-TokenFiles {
    param($Source)
    $root = if ($Source.Kind -eq 'codex') { Join-Path $Source.Dir 'sessions' } else { Join-Path $Source.Dir 'projects' }
    if (-not (Test-Path -LiteralPath $root -PathType Container)) { return }
    # Links are not followed: only files that are really under the folder are read.
    $all = Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) }
    if ($Source.Kind -eq 'codex') {
        $all | Where-Object { $_.Name -match '^rollout-.*\.jsonl(\.zst)?$' }
    } else {
        $all | Where-Object { $_.Name.EndsWith('.jsonl') }
    }
}

function Get-CodexSessionId {
    param([string] $Name)
    if ($Name -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\.jsonl') { return $Matches[1].ToLowerInvariant() }
    ($Name -replace '\.jsonl(\.zst)?$', '' -replace '[^A-Za-z0-9_.-]', '_')
}

function Find-ZstdNode {
    $node = Get-Command node -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $node) { return $null }
    $probe = & $node.Source -e "process.stdout.write(typeof require('zlib').zstdDecompressSync)" 2>$null
    if ($probe -eq 'function') { $node.Source } else { $null }
}

function Expand-ZstdLines {
    <#
    The lines of a .zst file that contain one of $Needles, through Node's zlib (no shell; the path
    and the needles are arguments, the script is fixed). Output is capped at 256 MB. $null on failure.
    #>
    param([string] $NodePath, [string] $Path, [string[]] $Needles)
    $script = "const [f, ...n] = process.argv.slice(1); const nl = String.fromCharCode(10); const t = require('zlib').zstdDecompressSync(require('fs').readFileSync(f), { maxOutputLength: 268435456 }).toString('utf8'); process.stdout.write(t.split(nl).filter(l => l.length <= 8388608 && n.some(x => l.includes(x))).join(nl))"
    $before = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
        # Bare words: quotes inside native arguments are not worth the risk.
        $words = @($Needles | ForEach-Object { $_.Trim('"') })
        $out = & $NodePath -e $script $Path @words 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        , @($out)
    } catch {
        $null
    } finally {
        [Console]::OutputEncoding = $before
    }
}

function Read-TokenFiles {
    param([string] $Path)
    $files = @{}
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $files }
    try { $doc = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop } catch { return $files }
    if ($doc -isnot [hashtable]) { return $files }
    foreach ($k in $doc.Keys) {
        $v = $doc[$k]
        if ($v -is [hashtable] -and ($v.s -is [long] -or $v.s -is [int])) { $files[$k] = @{ s = [long]$v.s; t = [long]$v.t; o = [long]$v.o; m = [string]$v.m } }
    }
    $files
}

function Write-TokenFiles {
    param([string] $Path, [hashtable] $Files)
    $tmp = "$Path.$PID.tmp"
    [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $Files -Depth 3 -Compress), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}

function Write-TokenSummary {
    param($State, [string] $Path, [object[]] $Sources, [bool] $IsComplete, [string[]] $Notes, [DateTimeOffset] $Now)
    $days = foreach ($k in $State.Days.Keys) {
        $c = $k.Split("`t")
        $v = $State.Days[$k]
        [ordered]@{ d = $c[0]; a = $c[1]; m = $c[2]; i = $v[0]; o = $v[1]; w5 = $v[2]; w1 = $v[3]; r = $v[4] }
    }
    $doc = [ordered]@{
        schema     = 1
        updatedAt  = $Now.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ', [cultureinfo]::InvariantCulture)
        isComplete = $IsComplete
        sources    = @($Sources | ForEach-Object { [ordered]@{ account = $_.Account; kind = $_.Kind } })
        days       = @($days | Sort-Object { $_.d }, { $_.a }, { $_.m })
        notes      = @($Notes)
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    $tmp = "$Path.$PID.tmp"
    [IO.File]::WriteAllText($tmp, (ConvertTo-Json -InputObject $doc -Depth 4 -Compress), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $Path -Force
}
