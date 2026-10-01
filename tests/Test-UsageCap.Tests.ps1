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
