BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'SwitchAccounts.psd1') -Force
}

Describe 'Test-UsageCap' {
    BeforeAll {
        $resetsAt = [DateTimeOffset]::new(2030, 1, 1, 15, 0, 0, [TimeSpan]::Zero)
        function New-Usage {
            param($Status = 'Known', $Percent = 10, $ResetsAt = $resetsAt, $Reason = $null)
            [pscustomobject]@{
                Status          = $Status
                FiveHourPercent = $Percent
                ResetsAt        = $ResetsAt
                Reason          = $Reason
            }
        }
    }

    It 'allows a session when usage is known and below the cap' {
        $result = Test-UsageCap -Usage (New-Usage -Percent 42) -MaxFiveHourPercent 70

        $result.Decision | Should -Be 'Allow'
        $result.RetryAfter | Should -BeNullOrEmpty
    }

    It 'waits until the reset when usage reaches the cap exactly' {
        $result = Test-UsageCap -Usage (New-Usage -Percent 70) -MaxFiveHourPercent 70

        $result.Decision | Should -Be 'Wait'
        $result.RetryAfter | Should -Be $resetsAt
        $result.Reason | Should -Match '70'
    }

    It 'waits when usage is above the cap' {
        (Test-UsageCap -Usage (New-Usage -Percent 99.5) -MaxFiveHourPercent 70).Decision |
            Should -Be 'Wait'
    }

    It 'waits without a retry time when the reset time is unknown' {
        $result = Test-UsageCap -Usage (New-Usage -Percent 80 -ResetsAt $null) -MaxFiveHourPercent 70

        $result.Decision | Should -Be 'Wait'
        $result.RetryAfter | Should -BeNullOrEmpty
    }

    It 'blocks when usage is unknown, even though the percent looks like zero' {
        $usage = New-Usage -Status 'Unknown' -Percent $null -ResetsAt $null -Reason 'not logged in'

        $result = Test-UsageCap -Usage $usage -MaxFiveHourPercent 70

        $result.Decision | Should -Be 'Block'
        $result.Reason | Should -Match 'not logged in'
    }

    It 'blocks when a known usage carries no percent' {
        (Test-UsageCap -Usage (New-Usage -Percent $null) -MaxFiveHourPercent 70).Decision |
            Should -Be 'Block'
    }

    It 'blocks when the percent is out of range' -TestCases @(
        @{ Percent = -1 }, @{ Percent = 100.1 }
    ) {
        (Test-UsageCap -Usage (New-Usage -Percent $Percent) -MaxFiveHourPercent 70).Decision |
            Should -Be 'Block'
    }

    It 'rejects a cap outside 1-100' -TestCases @(@{ Cap = 0 }, @{ Cap = 101 }) {
        { Test-UsageCap -Usage (New-Usage) -MaxFiveHourPercent $Cap } | Should -Throw
    }
}

Describe 'Test-UsageCap with a weekly cap' {
    BeforeAll {
        $fiveHourReset = [DateTimeOffset]::new(2030, 1, 1, 15, 0, 0, [TimeSpan]::Zero)
        $weeklyReset = [DateTimeOffset]::new(2030, 1, 6, 9, 0, 0, [TimeSpan]::Zero)
        function New-WeeklyUsage {
            param($Percent = 10, $Weekly = 20, $WeeklyResetsAt = $weeklyReset)
            [pscustomobject]@{
                Status          = 'Known'
                FiveHourPercent = $Percent
                ResetsAt        = $fiveHourReset
                WeeklyPercent   = $Weekly
                WeeklyResetsAt  = $WeeklyResetsAt
                Reason          = $null
            }
        }
    }

    It 'ignores the weekly usage when no weekly cap is given' {
        (Test-UsageCap -Usage (New-WeeklyUsage -Weekly 100) -MaxFiveHourPercent 70).Decision | Should -Be 'Allow'
        (Test-UsageCap -Usage (New-WeeklyUsage -Weekly $null) -MaxFiveHourPercent 70).Decision | Should -Be 'Allow'
    }

    It 'allows a session when both usages are below their caps' {
        (Test-UsageCap -Usage (New-WeeklyUsage -Weekly 40) -MaxFiveHourPercent 70 -MaxWeeklyPercent 90).Decision |
            Should -Be 'Allow'
    }

    It 'waits until the weekly reset when the weekly usage reaches its cap' {
        $result = Test-UsageCap -Usage (New-WeeklyUsage -Weekly 90) -MaxFiveHourPercent 70 -MaxWeeklyPercent 90

        $result.Decision | Should -Be 'Wait'
        $result.RetryAfter | Should -Be $weeklyReset
        $result.Reason | Should -Match 'weekly'
    }

    It 'waits until the later reset when both caps are reached' {
        $result = Test-UsageCap -Usage (New-WeeklyUsage -Percent 80 -Weekly 95) -MaxFiveHourPercent 70 -MaxWeeklyPercent 90

        $result.Decision | Should -Be 'Wait'
        $result.RetryAfter | Should -Be $weeklyReset
    }

    It 'waits without a retry time when a reached cap has no reset time' {
        $result = Test-UsageCap -Usage (New-WeeklyUsage -Weekly 95 -WeeklyResetsAt $null) -MaxFiveHourPercent 70 -MaxWeeklyPercent 90

        $result.Decision | Should -Be 'Wait'
        $result.RetryAfter | Should -BeNullOrEmpty
    }

    It 'blocks when a weekly cap is given but the weekly usage is unknown' {
        $result = Test-UsageCap -Usage (New-WeeklyUsage -Weekly $null) -MaxFiveHourPercent 70 -MaxWeeklyPercent 90

        $result.Decision | Should -Be 'Block'
        $result.Reason | Should -Match 'weekly'
    }

    It 'blocks when the weekly percentage is out of range' {
        (Test-UsageCap -Usage (New-WeeklyUsage -Weekly 101) -MaxFiveHourPercent 70 -MaxWeeklyPercent 90).Decision |
            Should -Be 'Block'
    }

    It 'still blocks on unknown 5-hour usage' {
        $usage = [pscustomobject]@{ Status = 'Unknown'; FiveHourPercent = $null; ResetsAt = $null; WeeklyPercent = 5; Reason = 'x' }

        (Test-UsageCap -Usage $usage -MaxFiveHourPercent 70 -MaxWeeklyPercent 90).Decision | Should -Be 'Block'
    }

    It 'rejects a weekly cap outside 1-100' -TestCases @(@{ Cap = 0 }, @{ Cap = 101 }) {
        { Test-UsageCap -Usage (New-WeeklyUsage) -MaxFiveHourPercent 70 -MaxWeeklyPercent $Cap } | Should -Throw
    }
}
