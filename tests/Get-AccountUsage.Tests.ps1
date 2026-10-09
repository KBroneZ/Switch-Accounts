BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'SwitchAccounts.psd1') -Force
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    $fake = Get-FakeClaudePath
    $now = [DateTimeOffset]::new(2030, 1, 1, 12, 0, 0, [TimeSpan]::Zero)
}

Describe 'ConvertFrom-UsageText' {
    It 'reads the current-session percentage and its reset time' {
        $usage = ConvertFrom-UsageText -Text (Get-SampleUsageText -Percent '37') -Now $now

        $usage.Status | Should -Be 'Known'
        $usage.FiveHourPercent | Should -Be 37
        $usage.ResetsAt | Should -Be ([DateTimeOffset]::new(2030, 1, 1, 16, 30, 0, [TimeSpan]::Zero))
    }

    It 'ignores the usage breakdown' {
        (ConvertFrom-UsageText -Text (Get-SampleUsageText -Percent '5') -Now $now).FiveHourPercent |
            Should -Be 5
    }

    It 'reads the weekly (all models) percentage and its reset time' {
        $usage = ConvertFrom-UsageText -Text (Get-SampleUsageText -Weekly '64' -WeeklyResets 'Jan 6, 7:59pm (UTC)') -Now $now

        $usage.WeeklyPercent | Should -Be 64
        $usage.WeeklyResetsAt | Should -Be ([DateTimeOffset]::new(2030, 1, 6, 19, 59, 0, [TimeSpan]::Zero))
    }

    It 'leaves the weekly usage unknown but keeps the 5-hour result when the weekly line is missing' {
        $dot = [char]0x00B7
        $usage = ConvertFrom-UsageText -Text "Current session: 12% used $dot resets 4:30pm (UTC)" -Now $now

        $usage.Status | Should -Be 'Known'
        $usage.FiveHourPercent | Should -Be 12
        $usage.ResetsAt | Should -Be ([DateTimeOffset]::new(2030, 1, 1, 16, 30, 0, [TimeSpan]::Zero))
        $usage.WeeklyPercent | Should -BeNullOrEmpty
        $usage.WeeklyResetsAt | Should -BeNullOrEmpty
    }

    It 'leaves the weekly usage unknown when <Case>' -TestCases @(
        @{ Case = 'the weekly line has no percentage'; Weekly = 'Current week (all models): loading...' }
        @{ Case = 'the weekly percentage is out of range'; Weekly = 'Current week (all models): 140% used' }
        @{ Case = 'there are two weekly lines'; Weekly = "Current week (all models): 10% used`nCurrent week (all models): 20% used" }
    ) {
        $usage = ConvertFrom-UsageText -Text ("Current session: 12% used`n" + $Weekly) -Now $now

        $usage.Status | Should -Be 'Known'
        $usage.FiveHourPercent | Should -Be 12
        $usage.WeeklyPercent | Should -BeNullOrEmpty
    }

    It 'only reads the all-models weekly line, not a per-model one' {
        $text = "Current session: 12% used`nCurrent week (Sonnet only): 90% used`nCurrent week (all models): 30% used"

        (ConvertFrom-UsageText -Text $text -Now $now).WeeklyPercent | Should -Be 30
    }

    It 'keeps the weekly percentage without a reset time' {
        $usage = ConvertFrom-UsageText -Text "Current session: 12% used`nCurrent week (all models): 30% used" -Now $now

        $usage.WeeklyPercent | Should -Be 30
        $usage.WeeklyResetsAt | Should -BeNullOrEmpty
    }

    It 'reads a reset time given in an IANA zone' {
        $usage = ConvertFrom-UsageText -Text (Get-SampleUsageText -Resets 'Jan 1, 6:59pm (Europe/Madrid)') -Now $now

        $usage.ResetsAt | Should -Be ([DateTimeOffset]::new(2030, 1, 1, 17, 59, 0, [TimeSpan]::Zero))
    }

    It 'keeps a dated reset that has just passed instead of moving it a year ahead' {
        # /usage prints minutes only, so for up to a minute the reset can look like the past.
        $usage = ConvertFrom-UsageText -Text (Get-SampleUsageText -Resets 'Jan 1, 11:59am (UTC)') -Now $now

        $usage.ResetsAt | Should -Be ([DateTimeOffset]::new(2030, 1, 1, 11, 59, 0, [TimeSpan]::Zero))
    }

    It 'moves a dated reset to next year across the new year' {
        $dec = [DateTimeOffset]::new(2030, 12, 31, 22, 0, 0, [TimeSpan]::Zero)
        $usage = ConvertFrom-UsageText -Text (Get-SampleUsageText -Resets 'Jan 1, 2am (UTC)') -Now $dec

        $usage.ResetsAt | Should -Be ([DateTimeOffset]::new(2031, 1, 1, 2, 0, 0, [TimeSpan]::Zero))
    }

    It 'keeps the percentage when the line has no reset time' {
        $usage = ConvertFrom-UsageText -Text 'Current session: 12% used' -Now $now

        $usage.Status | Should -Be 'Known'
        $usage.FiveHourPercent | Should -Be 12
        $usage.ResetsAt | Should -BeNullOrEmpty
    }

    It 'accepts decimals and 0%' -TestCases @(@{ P = '0'; E = 0 }, @{ P = '12.5'; E = 12.5 }, @{ P = '100'; E = 100 }) {
        (ConvertFrom-UsageText -Text (Get-SampleUsageText -Percent $P) -Now $now).FiveHourPercent |
            Should -Be $E
    }

    It 'rolls an earlier time of day over to tomorrow' {
        $usage = ConvertFrom-UsageText -Text (Get-SampleUsageText -Resets '9am (UTC)') -Now $now

        $usage.ResetsAt | Should -Be ([DateTimeOffset]::new(2030, 1, 2, 9, 0, 0, [TimeSpan]::Zero))
    }

    It 'keeps the percentage but leaves the reset unknown when it cannot be parsed' {
        $usage = ConvertFrom-UsageText -Text (Get-SampleUsageText -Resets 'soon (Mars/Olympus)') -Now $now

        $usage.Status | Should -Be 'Known'
        $usage.ResetsAt | Should -BeNullOrEmpty
    }

    It 'reads an account with no use in the window as 0% without a reset time' {
        $usage = ConvertFrom-UsageText -Text (Get-IdleUsageText) -Now $now

        $usage.Status | Should -Be 'Known'
        $usage.FiveHourPercent | Should -Be 0
        $usage.ResetsAt | Should -BeNullOrEmpty
        $usage.WeeklyPercent | Should -BeNullOrEmpty
        $usage.Reason | Should -BeNullOrEmpty
    }

    It 'keeps the account unknown when the idle layout is not exact: <Case>' -TestCases @(
        @{ Case = 'no subscription header'; Text = (Get-IdleUsageText) -replace 'You are currently using your subscription[^\n]*\n', '' }
        @{ Case = 'no breakdown section'; Text = "You are currently using your subscription to power your Claude Code usage`n" }
        @{ Case = 'a week line without a session line'; Text = (Get-IdleUsageText) + "`nCurrent week (all models): 3% used" }
        @{ Case = 'an error is mentioned'; Text = (Get-IdleUsageText) + "`nCould not load usage: unavailable" }
        @{ Case = 'a login prompt is mentioned'; Text = (Get-IdleUsageText) + "`nPlease log in again" }
        @{ Case = 'the header appears twice'; Text = (Get-IdleUsageText) + "`n" + (Get-IdleUsageText) }
        @{ Case = 'only the breakdown title'; Text = "What's contributing to your limits usage?`nnothing" }
    ) {
        (ConvertFrom-UsageText -Text $Text -Now $now).Status | Should -Be 'Unknown'
    }

    It 'is Unknown when <Case>' -TestCases @(
        @{ Case = 'the text is empty'; Text = '' }
        @{ Case = 'there is no current-session line'; Text = 'Current week (all models): 50% used' }
        @{ Case = 'the line has no percentage'; Text = 'Current session: loading...' }
        @{ Case = 'the percentage is on another line'; Text = "Current session`n50% used" }
        @{ Case = 'the CLI shows last-known (stale) data'; Text = (Get-SampleUsageText) + "`nShowing last-known usage from 12 minutes ago" }
        @{ Case = 'the usage endpoint is rate limited'; Text = 'Usage endpoint is rate limited. Press r to retry.' }
        @{ Case = 'there are two current-session lines'; Text = (Get-SampleUsageText) + "`n" + (Get-SampleUsageText) }
        @{ Case = 'the percentage is out of range'; Text = (Get-SampleUsageText -Percent '140') }
    ) {
        $usage = ConvertFrom-UsageText -Text $Text -Now $now

        $usage.Status | Should -Be 'Unknown'
        $usage.FiveHourPercent | Should -BeNullOrEmpty
        $usage.WeeklyPercent | Should -BeNullOrEmpty
        $usage.Reason | Should -Not -BeNullOrEmpty
    }
}

Describe 'Get-AccountUsage' {
    It 'asks the CLI for /usage with that account config dir and no session persistence' {
        $dir = New-FakeAccount -Path (Join-Path $TestDrive 'a') -UsageText (Get-SampleUsageText -Percent '22')

        $usage = Get-AccountUsage -ConfigDir $dir -ClaudePath $fake -Now $now

        $usage.Status | Should -Be 'Known'
        $usage.FiveHourPercent | Should -Be 22
        $call = (Get-FakeCalls -ConfigDir $dir)[0]
        $call.args | Should -Contain '/usage'
        $call.args | Should -Contain '--no-session-persistence'
        $call.args | Should -Contain '--safe-mode'
        ($call.args -join ' ') | Should -Match '--output-format json'
    }

    It 'reads each account from its own config dir' {
        $a = New-FakeAccount -Path (Join-Path $TestDrive 'acc-a') -UsageText (Get-SampleUsageText -Percent '10')
        $b = New-FakeAccount -Path (Join-Path $TestDrive 'acc-b') -UsageText (Get-SampleUsageText -Percent '90')

        (Get-AccountUsage -ConfigDir $a -ClaudePath $fake -Now $now).FiveHourPercent | Should -Be 10
        (Get-AccountUsage -ConfigDir $b -ClaudePath $fake -Now $now).FiveHourPercent | Should -Be 90
    }

    It 'reads an account with no use in the window as 0% without a reset time' {
        $usage = ConvertFrom-UsageText -Text (Get-IdleUsageText) -Now $now

        $usage.Status | Should -Be 'Known'
        $usage.FiveHourPercent | Should -Be 0
        $usage.ResetsAt | Should -BeNullOrEmpty
        $usage.WeeklyPercent | Should -BeNullOrEmpty
        $usage.Reason | Should -BeNullOrEmpty
    }

    It 'keeps the account unknown when the idle layout is not exact: <Case>' -TestCases @(
        @{ Case = 'no subscription header'; Text = (Get-IdleUsageText) -replace 'You are currently using your subscription[^\n]*\n', '' }
        @{ Case = 'no breakdown section'; Text = "You are currently using your subscription to power your Claude Code usage`n" }
        @{ Case = 'a week line without a session line'; Text = (Get-IdleUsageText) + "`nCurrent week (all models): 3% used" }
        @{ Case = 'an error is mentioned'; Text = (Get-IdleUsageText) + "`nCould not load usage: unavailable" }
        @{ Case = 'a login prompt is mentioned'; Text = (Get-IdleUsageText) + "`nPlease log in again" }
        @{ Case = 'the header appears twice'; Text = (Get-IdleUsageText) + "`n" + (Get-IdleUsageText) }
        @{ Case = 'only the breakdown title'; Text = "What's contributing to your limits usage?`nnothing" }
    ) {
        (ConvertFrom-UsageText -Text $Text -Now $now).Status | Should -Be 'Unknown'
    }

    It 'is Unknown when <Case>' -TestCases @(
        @{ Case = 'the CLI reports an error'; Setup = { param($p) New-FakeAccount -Path $p -UsageText 'Not logged in · Please run /login' -IsError } }
        @{ Case = 'the output is not JSON'; Setup = { param($p) New-FakeAccount -Path $p -RawUsageBody 'Segmentation fault' } }
        @{ Case = 'the JSON has no result'; Setup = { param($p) New-FakeAccount -Path $p -RawUsageBody '{"type":"result","is_error":false}' } }
        @{ Case = 'the CLI exits non-zero'; Setup = { param($p) New-FakeAccount -Path $p -UsageText (Get-SampleUsageText) -ExitCode 1 } }
        @{ Case = 'the CLI prints nothing'; Setup = { param($p) New-FakeAccount -Path $p } }
    ) {
        $dir = & $Setup (Join-Path $TestDrive ([guid]::NewGuid()))

        $usage = Get-AccountUsage -ConfigDir $dir -ClaudePath $fake -Now $now

        $usage.Status | Should -Be 'Unknown'
        $usage.FiveHourPercent | Should -BeNullOrEmpty
    }

    It 'is Unknown when the config dir does not exist' {
        $usage = Get-AccountUsage -ConfigDir (Join-Path $TestDrive 'missing') -ClaudePath $fake -Now $now

        $usage.Status | Should -Be 'Unknown'
        $usage.Reason | Should -Match 'config dir'
    }

    It 'is Unknown when the CLI cannot be found' {
        $dir = New-FakeAccount -Path (Join-Path $TestDrive 'nocli') -UsageText (Get-SampleUsageText)

        (Get-AccountUsage -ConfigDir $dir -ClaudePath (Join-Path $TestDrive 'nope.exe') -Now $now).Status |
            Should -Be 'Unknown'
    }

    It 'is Unknown when the CLI does not answer in time' {
        $dir = New-FakeAccount -Path (Join-Path $TestDrive 'slow') -UsageText (Get-SampleUsageText)
        Set-Content -LiteralPath (Join-Path $dir 'fake-sleep.txt') -Value 10 -NoNewline

        $usage = Get-AccountUsage -ConfigDir $dir -ClaudePath $fake -Now $now -TimeoutSeconds 2

        $usage.Status | Should -Be 'Unknown'
        $usage.Reason | Should -Match 'timed out'
    }

    It 'does not copy CLI error text longer than 200 characters into the reason' {
        $dir = New-FakeAccount -Path (Join-Path $TestDrive 'long') -UsageText ('x' * 1000) -IsError

        (Get-AccountUsage -ConfigDir $dir -ClaudePath $fake -Now $now).Reason.Length |
            Should -BeLessOrEqual 260
    }
}
