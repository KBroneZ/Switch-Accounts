BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'SwitchAccounts.psd1') -Force

    function New-Root {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path (Join-Path $root 'claude' 'projects' 'p1' 'sess' 'subagents') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $root 'codex' 'sessions' '2030' '01' '10') -Force | Out-Null
        [pscustomobject]@{
            Root    = $root
            Project = Join-Path $root 'claude' 'projects' 'p1'
            Codex   = Join-Path $root 'codex' 'sessions' '2030' '01' '10'
            Sources = @(
                [pscustomobject]@{ Account = 'A'; Kind = 'claude'; Dir = (Join-Path $root 'claude') }
                [pscustomobject]@{ Account = 'ChatGPT'; Kind = 'codex'; Dir = (Join-Path $root 'codex') }
            )
            State   = Join-Path $root 'state'
            Summary = Join-Path $root 'tokens.json'
        }
    }

    function Assistant([string] $Id, [long] $In, [long] $Out, [long] $Write = 0, [long] $Read = 0, [string] $Model = 'claude-opus-5-5', [string] $At = '2030-01-10T12:00:00Z', [int] $Write1h = 0, [string] $Speed = 'standard') {
        $usage = @{ input_tokens = $In; output_tokens = $Out; cache_creation_input_tokens = $Write; cache_read_input_tokens = $Read; speed = $Speed; cache_creation = @{ ephemeral_5m_input_tokens = $Write - $Write1h; ephemeral_1h_input_tokens = $Write1h } }
        ConvertTo-Json -Compress -Depth 5 -InputObject ([ordered]@{
                type = 'assistant'; requestId = "req_$Id"; timestamp = $At
                message = [ordered]@{ model = $Model; id = "msg_$Id"; content = @(@{ type = 'text'; text = 'the "usage" word in text' }); usage = $usage }
            })
    }

    function TokenCount([int] $In, [int] $Cached, [int] $Out, [string] $At = '2030-01-10T12:00:00Z') {
        ConvertTo-Json -Compress -Depth 6 -InputObject ([ordered]@{
                timestamp = $At; type = 'event_msg'
                payload = [ordered]@{ type = 'token_count'; info = @{ total_token_usage = @{ input_tokens = $In; cached_input_tokens = $Cached; cache_write_input_tokens = 0; output_tokens = $Out; reasoning_output_tokens = 0; total_tokens = $In + $Out } } }
            })
    }

    function Run($r, [object[]] $Sources = $r.Sources) {
        Update-TokenLedger -StateDir $r.State -SummaryPath $r.Summary -Sources $Sources -NodePath '' -Now ([DateTimeOffset]'2030-01-10T13:00:00Z')
    }

    function Totals($r, [string] $Account = 'A') {
        $doc = Get-Content -LiteralPath $r.Summary -Raw | ConvertFrom-Json
        $sum = [ordered]@{ i = 0; o = 0; w5 = 0; w1 = 0; r = 0 }
        foreach ($d in @($doc.days | Where-Object { $_.a -eq $Account })) { foreach ($k in @($sum.Keys)) { $sum[$k] += $d.$k } }
        [pscustomobject]$sum
    }
}

Describe 'Update-TokenLedger' {
    It 'counts a message written several times while it streams once, with its final usage' {
        $r = New-Root
        Set-Content -LiteralPath (Join-Path $r.Project 's1.jsonl') -Value @(
            (Assistant 'a' 10 5 100 1000)
            (Assistant 'a' 10 40 100 1000)
            (Assistant 'a' 10 40 100 1000)
            '{"type":"user","message":{"content":"hi"}}'
            'not json with "usage" and "assistant"'
            (Assistant 'b' 1 2 0 0 '<synthetic>')
        )
        (Run $r).Status | Should -Be 'Done'
        $t = Totals $r
        $t.i | Should -Be 10
        $t.o | Should -Be 40
        $t.w5 | Should -Be 100
        $t.r | Should -Be 1000
    }

    It 'counts a message copied into another transcript (a resumed session) once' {
        $r = New-Root
        Set-Content -LiteralPath (Join-Path $r.Project 's1.jsonl') -Value (Assistant 'a' 10 5)
        Set-Content -LiteralPath (Join-Path $r.Project 'sess' 'subagents' 'agent-1.jsonl') -Value @((Assistant 'a' 10 5), (Assistant 'c' 3 4))
        Run $r | Out-Null
        (Totals $r).i | Should -Be 13
    }

    It 'splits 1-hour cache writes and marks fast mode' {
        $r = New-Root
        Set-Content -LiteralPath (Join-Path $r.Project 's1.jsonl') -Value @((Assistant 'a' 1 1 50 0 -Write1h 30), (Assistant 'f' 1 1 0 0 -Speed 'fast'))
        Run $r | Out-Null
        $doc = Get-Content -LiteralPath $r.Summary -Raw | ConvertFrom-Json
        ($doc.days | Where-Object m -EQ 'claude-opus-5-5').w5 | Should -Be 20
        ($doc.days | Where-Object m -EQ 'claude-opus-5-5').w1 | Should -Be 30
        @($doc.days | Where-Object m -EQ 'claude-opus-5-5@fast') | Should -HaveCount 1
    }

    It 'reads only new lines on the next run and leaves a half-written last line for later' {
        $r = New-Root
        $file = Join-Path $r.Project 's1.jsonl'
        Set-Content -LiteralPath $file -Value (Assistant 'a' 10 5)
        $half = Assistant 'b' 7 7
        [IO.File]::AppendAllText($file, $half.Substring(0, 20))
        Run $r | Out-Null
        (Totals $r).i | Should -Be 10
        [IO.File]::AppendAllText($file, $half.Substring(20) + "`n")
        (Run $r).Files | Should -Be 1
        (Totals $r).i | Should -Be 17
        (Run $r).Files | Should -Be 0
    }

    It 'never lowers a total: a deleted or shrunk transcript keeps what it added' {
        $r = New-Root
        $file = Join-Path $r.Project 's1.jsonl'
        Set-Content -LiteralPath $file -Value @((Assistant 'a' 10 5), (Assistant 'b' 20 5))
        Run $r | Out-Null
        (Totals $r).i | Should -Be 30
        Set-Content -LiteralPath $file -Value (Assistant 'a' 10 1)
        Run $r | Out-Null
        (Totals $r).i | Should -Be 30
        (Totals $r).o | Should -Be 10
        Remove-Item -LiteralPath $file
        Run $r | Out-Null
        (Totals $r).i | Should -Be 30
        # The ledger alone rebuilds the totals, with no transcript left.
        Remove-Item -LiteralPath (Join-Path $r.State 'files.json')
        Run $r | Out-Null
        (Totals $r).i | Should -Be 30
    }

    It 'only appends to the ledger and survives a torn last line' {
        $r = New-Root
        Set-Content -LiteralPath (Join-Path $r.Project 's1.jsonl') -Value (Assistant 'a' 10 5)
        Run $r | Out-Null
        $ledger = Join-Path $r.State 'ledger.tsv'
        $before = [IO.File]::ReadAllText($ledger)
        [IO.File]::AppendAllText($ledger, "msg_torn|req`tA`tclaude-opus-5-5`t2030-01-")
        Add-Content -LiteralPath (Join-Path $r.Project 's1.jsonl') -Value (Assistant 'b' 1 1)
        Run $r | Out-Null
        $after = [IO.File]::ReadAllText($ledger)
        $after.StartsWith($before) | Should -BeTrue
        (Totals $r).i | Should -Be 11
    }

    It 'takes Codex session totals as cumulative: the last value, not the sum of every event' {
        $r = New-Root
        $file = Join-Path $r.Codex 'rollout-2030-01-10T10-00-00-01a1a873-51d8-7772-9a12-a7c4a8b3f6cd.jsonl'
        Set-Content -LiteralPath $file -Value @(
            '{"timestamp":"2030-01-09T10:00:00Z","type":"turn_context","payload":{"model":"gpt-6-luna"}}'
            (TokenCount 1000 600 50 '2030-01-09T10:01:00Z')
            (TokenCount 1000 600 50 '2030-01-09T10:01:01Z')
            (TokenCount 3000 2000 120)
        )
        Run $r | Out-Null
        $t = Totals $r 'ChatGPT'
        $t.i | Should -Be 1000      # 3000 input of which 2000 cached
        $t.r | Should -Be 2000
        $t.o | Should -Be 120
        $doc = Get-Content -LiteralPath $r.Summary -Raw | ConvertFrom-Json
        $days = @($doc.days | Where-Object a -EQ 'ChatGPT')
        ($days | Where-Object d -EQ '2030-01-09').o | Should -Be 50
        ($days | Where-Object d -EQ '2030-01-10').o | Should -Be 70
        $days[0].m | Should -Be 'gpt-6-luna'
        # The same session again (or compressed later under the same id) adds nothing.
        Add-Content -LiteralPath $file -Value (TokenCount 3000 2000 120)
        Run $r | Out-Null
        (Totals $r 'ChatGPT').o | Should -Be 120
    }

    It 'says when compressed Codex sessions need Node' {
        $r = New-Root
        Set-Content -LiteralPath (Join-Path $r.Codex 'rollout-x-01a1a873-51d8-7772-9a12-a7c4a8b3f6cd.jsonl.zst') -Value 'zz'
        (Run $r).Skipped | Should -Be 1
        (Get-Content -LiteralPath $r.Summary -Raw | ConvertFrom-Json).notes[0] | Should -Match 'Node'
    }

    It 'skips an impossible count, a line over 8 MB and a name with a newline, and keeps going' {
        $r = New-Root
        $file = Join-Path $r.Project 's1.jsonl'
        $huge = '{"type":"assistant","usage":"' + ('x' * 9MB) + '"}'
        Set-Content -LiteralPath $file -Value @(
            (Assistant 'big' 9000000000000000000 1)
            $huge
            ((Assistant 'nl' 5 5) -replace '"claude-opus-5-5"', '"claude-opus-5-5\n"')
            (Assistant 'ok' 7 1)
        )
        (Run $r).Status | Should -Be 'Done'
        $t = Totals $r
        $t.i | Should -Be 7
        $t.o | Should -Be 2
        (Get-Content -LiteralPath (Join-Path $r.State 'ledger.tsv')).Count | Should -Be 3
        (Run $r).Status | Should -Be 'Done'
        (Totals $r).i | Should -Be 7
    }

    It 'reads a big file in pieces and keeps the place of each piece' {
        $r = New-Root
        $file = Join-Path $r.Project 's1.jsonl'
        Set-Content -LiteralPath $file -Value @(1..40 | ForEach-Object { Assistant "m$_" 1 1 })
        $module = Get-Module SwitchAccounts
        $first = & $module { param($p) Read-NewLines -Path $p -Needles @('"usage"') -MaxBytes 2KB } $file
        $first.IsDone | Should -BeFalse
        $first.Lines.Count | Should -BeLessThan 40
        $rest = & $module { param($p, $o) Read-NewLines -Path $p -Offset $o -Needles @('"usage"') -MaxBytes 1MB } $file $first.Offset
        $rest.IsDone | Should -BeTrue
        ($first.Lines.Count + $rest.Lines.Count) | Should -Be 40
        Run $r | Out-Null
        (Totals $r).i | Should -Be 40
    }

    It 'runs one at a time: a second run while one holds the lock does nothing' {
        $r = New-Root
        1..3 | ForEach-Object { Set-Content -LiteralPath (Join-Path $r.Project "s$_.jsonl") -Value (Assistant "m$_" 1 1) }
        $state = $r.State
        New-Item -ItemType Directory -Path $state -Force | Out-Null
        $lock = [IO.File]::Open((Join-Path $state '.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
        try { (Run $r).Status | Should -Be 'Busy' } finally { $lock.Dispose() }
        (Run $r).Status | Should -Be 'Done'
        (Totals $r).i | Should -Be 3
    }
}
