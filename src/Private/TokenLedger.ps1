# The token ledger: every Claude message and every Codex session, counted once, kept forever.
#
# ledger.tsv is append-only. A line adds tokens to one key (a Claude message id plus its request
# id, or a Codex session id) on one local day, for one account and model. The first line of a key
# is what was first seen; a later line only adds what a key grew by (a message is written several
# times while it streams; a Codex session's totals are cumulative). The totals are the sum of the
# lines, so a transcript Claude Code deletes later never lowers them.

$script:TokenFields = 5   # input, output, cache write 5m, cache write 1h, cache read
$script:LedgerHeader = '# switch-fleet token ledger v1: key account model day input output cacheWrite5m cacheWrite1h cacheRead'
# \A and \z, not ^ and $: $ also matches before a final newline, which would split a ledger line.
$script:LedgerKey = '\A[A-Za-z0-9_:.|-]{1,200}\z'
$script:LedgerName = '\A[A-Za-z0-9 ._@:/-]{1,80}\z'
$script:LedgerDay = '\A[0-9]{4}-[0-9]{2}-[0-9]{2}\z'
$script:HaikuLongPrompt = 100000
# No real count comes near this; a larger value is a broken line, and summing it could overflow.
$script:MaxTokenCount = [long]1e12
# A transcript line longer than this (a pasted image, say) is skipped, not held in memory.
$script:MaxLineBytes = 8MB

function New-TokenState {
    [pscustomobject]@{
        # Per key: the largest value seen of each field.
        Keys    = [Collections.Generic.Dictionary[string, long[]]]::new([StringComparer]::Ordinal)
        # Per "day<TAB>account<TAB>model": the summed fields.
        Days    = [Collections.Generic.Dictionary[string, long[]]]::new([StringComparer]::Ordinal)
        # Ledger lines added in this run, not yet written.
        Pending = [Collections.Generic.List[string]]::new()
    }
}

function Add-TokenDay {
    param($State, [string] $Day, [string] $Account, [string] $Model, [long[]] $Delta)
    $k = "$Day`t$Account`t$Model"
    $sum = $null
    if (-not $State.Days.TryGetValue($k, [ref]$sum)) {
        $sum = [long[]]::new($script:TokenFields)
        $State.Days[$k] = $sum
    }
    for ($i = 0; $i -lt $script:TokenFields; $i++) { $sum[$i] += $Delta[$i] }
}

function Read-TokenLedger {
    <# Rebuilds the state from ledger.tsv. Lines that do not parse (a torn last line) are skipped. #>
    param([Parameter(Mandatory)] [string] $Path)
    $state = New-TokenState
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $state }
    foreach ($line in [IO.File]::ReadLines($Path)) {
        if ($line.Length -eq 0 -or $line[0] -eq '#') { continue }
        $c = $line.Split("`t")
        if ($c.Count -ne 4 + $script:TokenFields) { continue }
        $v = [long[]]::new($script:TokenFields)
        $ok = $true
        $n = [long]0
        for ($i = 0; $i -lt $script:TokenFields; $i++) {
            # [ref] to an array element would write a copy: parse into a scalar.
            if (-not [long]::TryParse($c[4 + $i], [ref]$n) -or $n -lt 0 -or $n -gt $script:MaxTokenCount) { $ok = $false; break }
            $v[$i] = $n
        }
        if (-not $ok -or $c[0] -notmatch $script:LedgerKey -or $c[1] -notmatch $script:LedgerName -or $c[2] -notmatch $script:LedgerName -or $c[3] -notmatch $script:LedgerDay) { continue }
        # A line adds to its key: the key's value is the sum of its lines.
        $have = $null
        if ($state.Keys.TryGetValue($c[0], [ref]$have)) {
            for ($i = 0; $i -lt $script:TokenFields; $i++) { $have[$i] += $v[$i] }
        } else {
            $state.Keys[$c[0]] = $v.Clone()
        }
        Add-TokenDay $state $c[3] $c[1] $c[2] $v
    }
    $state
}

function Add-TokenUsage {
    <#
    Counts one reading of a key. A new key is added whole; a known one adds only what each field
    grew by since its largest reading (a smaller reading adds nothing). Returns whether it added.
    #>
    param(
        [Parameter(Mandatory)] $State,
        [Parameter(Mandatory)] [string] $Key,
        [Parameter(Mandatory)] [string] $Account,
        [Parameter(Mandatory)] [string] $Model,
        [Parameter(Mandatory)] [string] $Day,
        [Parameter(Mandatory)] [long[]] $Usage
    )
    if ($Key -notmatch $script:LedgerKey -or $Account -notmatch $script:LedgerName -or $Model -notmatch $script:LedgerName -or $Day -notmatch $script:LedgerDay) {
        return $false
    }
    $have = $null
    $delta = [long[]]::new($script:TokenFields)
    $grew = $false
    if ($State.Keys.TryGetValue($Key, [ref]$have)) {
        for ($i = 0; $i -lt $script:TokenFields; $i++) {
            if ($Usage[$i] -gt $have[$i]) { $delta[$i] = $Usage[$i] - $have[$i]; $have[$i] = $Usage[$i]; $grew = $true }
        }
    } else {
        for ($i = 0; $i -lt $script:TokenFields; $i++) { $delta[$i] = [Math]::Max(0, $Usage[$i]) }
        $State.Keys[$Key] = $delta.Clone()
        $grew = $true
    }
    if (-not $grew) { return $false }
    Add-TokenDay $State $Day $Account $Model $delta
    $State.Pending.Add((@($Key, $Account, $Model, $Day) + $delta) -join "`t")
    $true
}

function Save-TokenLedger {
    <# Appends the pending lines to ledger.tsv (never rewrites it) and clears them. #>
    param([Parameter(Mandatory)] $State, [Parameter(Mandatory)] [string] $Path)
    if ($State.Pending.Count -eq 0) { return }
    $prefix = ''
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $prefix = $script:LedgerHeader + "`n"
    } else {
        # A torn last line (a run cut mid-write) must not swallow the first new line.
        $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        try {
            if ($fs.Length -gt 0) {
                $fs.Seek(-1, 'End') | Out-Null
                if ($fs.ReadByte() -ne 10) { $prefix = "`n" }
            }
        } finally { $fs.Dispose() }
    }
    [IO.File]::AppendAllText($Path, $prefix + ($State.Pending -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
    $State.Pending.Clear()
}

function ConvertTo-LocalDay {
    param([string] $Timestamp)
    $at = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParse($Timestamp, [cultureinfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$at)) { return $null }
    $at.ToLocalTime().ToString('yyyy-MM-dd', [cultureinfo]::InvariantCulture)
}

function Get-JsonLong {
    param([Text.Json.JsonElement] $Element, [string] $Name)
    $p = [Text.Json.JsonElement]::new()
    if ($Element.ValueKind -ne 'Object' -or -not $Element.TryGetProperty($Name, [ref]$p) -or $p.ValueKind -ne 'Number') { return [long]0 }
    $n = [long]0
    if ($p.TryGetInt64([ref]$n) -and $n -gt 0 -and $n -le $script:MaxTokenCount) { return $n }
    [long]0
}

function Get-JsonString {
    param([Text.Json.JsonElement] $Element, [string] $Name)
    $p = [Text.Json.JsonElement]::new()
    if ($Element.ValueKind -ne 'Object' -or -not $Element.TryGetProperty($Name, [ref]$p) -or $p.ValueKind -ne 'String') { return $null }
    $p.GetString()
}

function Get-JsonObject {
    param([Text.Json.JsonElement] $Element, [string] $Name)
    $p = [Text.Json.JsonElement]::new()
    if ($Element.ValueKind -ne 'Object' -or -not $Element.TryGetProperty($Name, [ref]$p) -or $p.ValueKind -ne 'Object') { return $null }
    $p
}

function ConvertFrom-ClaudeUsageLine {
    <#
    One transcript line: its key, model, local day and usage when it is an assistant message with
    usage, else $null. The model gets `@fast` for fast mode and Haiku 5.5 `@long` for a prompt over
    100,000 tokens: both are priced apart.
    #>
    param([Parameter(Mandatory)] [string] $Line)
    if (-not $Line.Contains('"usage"') -or -not $Line.Contains('"assistant"')) { return $null }
    try { $doc = [Text.Json.JsonDocument]::Parse($Line) } catch { return $null }
    try {
        $root = $doc.RootElement
        if ((Get-JsonString $root 'type') -ne 'assistant') { return $null }
        $msg = Get-JsonObject $root 'message'
        if ($null -eq $msg) { return $null }
        $id = Get-JsonString $msg 'id'
        $model = Get-JsonString $msg 'model'
        $usage = Get-JsonObject $msg 'usage'
        if (-not $id -or -not $model -or $model -eq '<synthetic>' -or $null -eq $usage) { return $null }
        $day = ConvertTo-LocalDay (Get-JsonString $root 'timestamp')
        if (-not $day) { return $null }
        $request = Get-JsonString $root 'requestId'
        $write = Get-JsonLong $usage 'cache_creation_input_tokens'
        $split = Get-JsonObject $usage 'cache_creation'
        $write1h = if ($null -ne $split) { [Math]::Min($write, (Get-JsonLong $split 'ephemeral_1h_input_tokens')) } else { [long]0 }
        $u = [long[]]@(
            (Get-JsonLong $usage 'input_tokens'),
            (Get-JsonLong $usage 'output_tokens'),
            ($write - $write1h),
            $write1h,
            (Get-JsonLong $usage 'cache_read_input_tokens')
        )
        if ((Get-JsonString $usage 'speed') -eq 'fast') { $model = "$model@fast" }
        elseif ($model -eq 'claude-haiku-5-5' -and ($u[0] + $u[2] + $u[3] + $u[4]) -gt $script:HaikuLongPrompt) { $model = "$model@long" }
        [pscustomobject]@{ Key = if ($request) { "$id|$request" } else { $id }; Model = $model; Day = $day; Usage = $u }
    } finally { $doc.Dispose() }
}

function Read-CodexEvent {
    <#
    One Codex rollout line: @{ Model } for a turn_context, @{ Day; Usage } for a token_count with
    its session totals (cumulative), else $null. OpenAI counts cached input inside input_tokens, so
    input is what was not cached; cache writes are priced as 30-minute writes.
    #>
    param([Parameter(Mandatory)] [string] $Line)
    $isTurn = $Line.Contains('"turn_context"')
    if (-not $isTurn -and -not $Line.Contains('"token_count"')) { return $null }
    try { $doc = [Text.Json.JsonDocument]::Parse($Line) } catch { return $null }
    try {
        $root = $doc.RootElement
        $payload = Get-JsonObject $root 'payload'
        if ($null -eq $payload) { return $null }
        if ((Get-JsonString $root 'type') -eq 'turn_context') {
            $model = Get-JsonString $payload 'model'
            if ($model) { return [pscustomobject]@{ Model = $model } }
            return $null
        }
        if ((Get-JsonString $payload 'type') -ne 'token_count') { return $null }
        $info = Get-JsonObject $payload 'info'
        $total = if ($null -ne $info) { Get-JsonObject $info 'total_token_usage' } else { $null }
        if ($null -eq $total) { return $null }
        $day = ConvertTo-LocalDay (Get-JsonString $root 'timestamp')
        if (-not $day) { return $null }
        $prompt = Get-JsonLong $total 'input_tokens'
        $cached = Get-JsonLong $total 'cached_input_tokens'
        $written = Get-JsonLong $total 'cache_write_input_tokens'
        $u = [long[]]@([Math]::Max(0, $prompt - $cached - $written), (Get-JsonLong $total 'output_tokens'), $written, 0, $cached)
        [pscustomobject]@{ Day = $day; Usage = $u }
    } finally { $doc.Dispose() }
}

function Read-NewLines {
    <#
    The complete lines of a file from byte $Offset on that contain one of $Needles, and the offset
    after the last complete line read. A last line with no newline yet (still being written) is left
    for the next run; a line over 8 MB is skipped. Reading stops after about $MaxBytes so one huge
    file cannot hold a run past its time budget (IsDone says whether it reached the end).
    #>
    param([Parameter(Mandatory)] [string] $Path, [long] $Offset = 0, [string[]] $Needles = @(), [long] $MaxBytes = 256MB)
    $lines = [Collections.Generic.List[string]]::new()
    $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    $isDone = $true
    try {
        if ($Offset -gt $fs.Length) { $Offset = 0 }
        $fs.Seek($Offset, 'Begin') | Out-Null
        $buf = [byte[]]::new(1MB)
        $carry = [IO.MemoryStream]::new()
        $isTooLong = $false
        $pos = $Offset
        $utf8 = [Text.UTF8Encoding]::new($false)
        # Bytes of the line not finished yet: in $carry, unless it is already too long to keep.
        $partial = [long]0
        while (($n = $fs.Read($buf, 0, $buf.Length)) -gt 0) {
            $start = 0
            while ($start -lt $n) {
                $nl = [Array]::IndexOf($buf, [byte]10, $start, $n - $start)
                if ($nl -lt 0) {
                    $chunk = $n - $start
                    if (-not $isTooLong -and $partial + $chunk -le $script:MaxLineBytes) { $carry.Write($buf, $start, $chunk) }
                    else { $isTooLong = $true; $carry.SetLength(0) }
                    $partial += $chunk
                    break
                }
                $len = $nl - $start
                if (-not $isTooLong -and $partial + $len -le $script:MaxLineBytes) {
                    $line = if ($partial -gt 0) {
                        $carry.Write($buf, $start, $len)
                        $utf8.GetString($carry.GetBuffer(), 0, [int]$carry.Length)
                    } else {
                        $utf8.GetString($buf, $start, $len)
                    }
                    $line = $line.TrimEnd("`r")
                    $isKept = $Needles.Count -eq 0
                    foreach ($needle in $Needles) { if ($line.Contains($needle)) { $isKept = $true; break } }
                    if ($isKept) { $lines.Add($line) }
                }
                $pos += $partial + $len + 1
                $partial = 0
                $isTooLong = $false
                $carry.SetLength(0)
                $start = $nl + 1
                if ($pos - $Offset -ge $MaxBytes) { $isDone = $false; break }
            }
            if (-not $isDone) { break }
        }
        $carry.Dispose()
    } finally { $fs.Dispose() }
    [pscustomobject]@{ Lines = $lines; Offset = $pos; IsDone = $isDone }
}
