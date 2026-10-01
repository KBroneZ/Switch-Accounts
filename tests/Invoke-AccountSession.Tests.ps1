BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'SwitchAccounts.psd1') -Force
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    $fake = Get-FakeClaudePath

    function New-SessionAccount {
        param([string] $Name = 'A', [string] $Percent = '20', [double] $Cap = 70, [string[]] $Lines = @())
        $dir = New-FakeAccount -Path (Join-Path $TestDrive "$Name-$([guid]::NewGuid())") -UsageText (Get-SampleUsageText -Percent $Percent)
        Set-Content -LiteralPath (Join-Path $dir 'fake-session.jsonl') -Value $Lines
        [pscustomobject]@{ Name = $Name; ConfigDir = $dir; MaxFiveHourPercent = $Cap }
    }

    function Get-InitLine { '{"type":"system","subtype":"init","session_id":"s-1"}' }
    function Get-ResultLine {
        param([string] $Subtype = 'success', [bool] $IsError = $false, [string] $Text = 'done', [int] $Turns = 3)
        [ordered]@{ type = 'result'; subtype = $Subtype; is_error = $IsError; result = $Text; num_turns = $Turns; session_id = 's-1' } |
            ConvertTo-Json -Compress
    }

    $work = New-Item -ItemType Directory -Path (Join-Path $TestDrive 'work') -Force
}

Describe 'Invoke-AccountSession' {
    BeforeEach {
        $stateDir = Join-Path $TestDrive "state-$([guid]::NewGuid())"
        $common = @{ WorkingDirectory = $work.FullName; ClaudePath = $fake; StateDir = $stateDir }
    }

    It 'runs a session that completes and reports turns and result' {
        $account = New-SessionAccount -Lines @((Get-InitLine), (Get-ResultLine -Text 'all good' -Turns 4))

        $session = Invoke-AccountSession -Account $account -Prompt 'Implement task 001' -MaxTurns 12 @common

        $session.Outcome | Should -Be 'Completed'
        $session.NumTurns | Should -Be 4
        $session.SessionId | Should -Be 's-1'
        $session.ResultText | Should -Be 'all good'
    }

    It 'passes the prompt on stdin and the limits as flags, in the account config dir' {
        $account = New-SessionAccount -Lines @((Get-ResultLine))

        Invoke-AccountSession -Account $account -Prompt 'Review PR 12' -MaxTurns 7 `
            -AllowedTools Read, Grep -DisallowedTools 'Bash(git push *)' @common | Out-Null

        $call = Get-FakeCalls -ConfigDir $account.ConfigDir | Where-Object { $_.prompt -ne '/usage' }
        $call.prompt | Should -Be 'Review PR 12'
        $call.cwd | Should -Be $work.FullName
        $line = $call.args -join ' '
        $line | Should -Match '--max-turns 7'
        $line | Should -Match '--output-format stream-json'
        $line | Should -Match '--permission-mode dontAsk'
        $line | Should -Match '--permission-prompts none'
        Get-FlagValues -Arguments $call.args -Flag '--allowedTools' | Should -Be @('Read', 'Grep')
        Get-FlagValues -Arguments $call.args -Flag '--disallowedTools' | Should -Be @('Bash(git push *)')
        $line | Should -Not -Match 'dangerously|bypassPermissions'
    }

    It 'installs the usage guard as a PreToolUse hook for this session only' {
        $account = New-SessionAccount -Lines @((Get-ResultLine))

        Invoke-AccountSession -Account $account -Prompt 'x' @common | Out-Null

        $call = Get-FakeCalls -ConfigDir $account.ConfigDir | Where-Object { $_.prompt -ne '/usage' }
        $settings = $call.args[[Array]::IndexOf([string[]]$call.args, '--settings') + 1] | ConvertFrom-Json
        $hook = $settings.hooks.PreToolUse[0].hooks[0]
        $hook.type | Should -Be 'command'
        ($hook.args -join ' ') | Should -Match 'usage-guard\.ps1'
        ($hook.args -join ' ') | Should -Match '-MaxFiveHourPercent 70'
        $hook.args | Should -Contain $account.ConfigDir
    }

    It 'does not start when the account is at its cap' {
        $account = New-SessionAccount -Percent '75' -Cap 70 -Lines @((Get-ResultLine))

        $session = Invoke-AccountSession -Account $account -Prompt 'x' @common

        $session.Outcome | Should -Be 'CapWait'
        $session.RetryAfter | Should -Not -BeNullOrEmpty
        @(Get-FakeCalls -ConfigDir $account.ConfigDir | Where-Object { $_.prompt -ne '/usage' }) | Should -HaveCount 0
    }

    It 'does not start when usage is unknown' {
        $account = New-SessionAccount -Lines @((Get-ResultLine))
        New-FakeAccount -Path $account.ConfigDir -UsageText 'Not logged in' -IsError | Out-Null

        $session = Invoke-AccountSession -Account $account -Prompt 'x' @common

        $session.Outcome | Should -Be 'UsageUnknown'
        @(Get-FakeCalls -ConfigDir $account.ConfigDir | Where-Object { $_.prompt -ne '/usage' }) | Should -HaveCount 0
    }

    It 'reports MaxTurns when the CLI stops on the turn limit' {
        $account = New-SessionAccount -Lines @((Get-ResultLine -Subtype 'error_max_turns' -IsError $true))

        (Invoke-AccountSession -Account $account -Prompt 'x' @common).Outcome | Should -Be 'MaxTurns'
    }

    It 'reports Failed when the result is an error or missing' -TestCases @(
        @{ Lines = @('{"type":"result","subtype":"error_during_execution","is_error":true,"result":"boom"}') }
        @{ Lines = @('{"type":"system","subtype":"init","session_id":"s"}') }
        @{ Lines = @('not json at all') }
    ) {
        $account = New-SessionAccount -Lines $Lines

        (Invoke-AccountSession -Account $account -Prompt 'x' @common).Outcome | Should -Be 'Failed'
    }

    It 'kills the session as soon as a rate-limit rejection arrives' {
        $account = New-SessionAccount -Lines @(
            (Get-InitLine),
            '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1900000000}}',
            '#sleep 30',
            (Get-ResultLine))
        $clock = [Diagnostics.Stopwatch]::StartNew()

        $session = Invoke-AccountSession -Account $account -Prompt 'x' @common

        $session.Outcome | Should -Be 'RateLimited'
        $clock.Elapsed.TotalSeconds | Should -BeLessThan 20
    }

    It 'kills the session when it runs past the timeout' {
        $account = New-SessionAccount -Lines @((Get-InitLine), '#sleep 30', (Get-ResultLine))

        $session = Invoke-AccountSession -Account $account -Prompt 'x' -TimeoutMinutes 0.05 @common

        $session.Outcome | Should -Be 'TimedOut'
    }

    It 'reports CapReached when the guard stopped the session' {
        $account = New-SessionAccount -Lines @((Get-InitLine), (Get-ResultLine -Subtype 'success'))
        Set-Content -LiteralPath (Join-Path $account.ConfigDir 'fake-session-action.ps1') -Value @"
`$state = Get-ChildItem -LiteralPath '$stateDir' -Filter 'guard-*.json' | Select-Object -First 1
@{ Decision = 'Wait'; Reason = '5-hour usage 71% has reached the cap of 70%'; LastCheck = [DateTimeOffset]::Now.ToString('o') } |
    ConvertTo-Json | Set-Content -LiteralPath `$state.FullName
"@

        $session = Invoke-AccountSession -Account $account -Prompt 'x' @common

        $session.Outcome | Should -Be 'CapReached'
        $session.Reason | Should -Match '71%'
    }

    It 'rejects a permission mode that skips permissions' {
        $account = New-SessionAccount -Lines @((Get-ResultLine))

        { Invoke-AccountSession -Account $account -Prompt 'x' -PermissionMode bypassPermissions @common } |
            Should -Throw
    }
}
