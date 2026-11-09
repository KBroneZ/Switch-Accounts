BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'SwitchAccounts.psd1') -Force
}

Describe 'Get-UsageReport' {
    It 'groups readings per local day and account, newest day first' {
        $path = Join-Path $TestDrive "h-$([guid]::NewGuid()).jsonl"
        $now = [DateTimeOffset]::new(2030, 1, 10, 12, 0, 0, [TimeSpan]::Zero).ToLocalTime()
        $at = { param($days, $hours) $now.AddDays(-$days).Date.AddHours($hours).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
        Set-Content -LiteralPath $path -Value @(
            "{`"at`":`"$(& $at 0 9)`",`"name`":`"A`",`"fiveHour`":20,`"weekly`":3}"
            "{`"at`":`"$(& $at 0 10)`",`"name`":`"A`",`"fiveHour`":55,`"weekly`":4}"
            "{`"at`":`"$(& $at 0 11)`",`"name`":`"B`",`"fiveHour`":5}"
            "{`"at`":`"$(& $at 1 10)`",`"name`":`"A`",`"fiveHour`":70,`"weekly`":2}"
            "{`"at`":`"$(& $at 9 10)`",`"name`":`"A`",`"fiveHour`":99}"
            'garbage'
        )

        $rows = @(Get-UsageReport -Path $path -Days 7 -Now $now)

        $rows | Should -HaveCount 3
        $today = $now.ToString('yyyy-MM-dd')
        $rows[0].Date | Should -Be $today
        $rows[0].Account | Should -Be 'A'
        $rows[0].MaxFiveHourPercent | Should -Be 55
        $rows[0].WeeklyPercent | Should -Be 4
        $rows[0].Readings | Should -Be 2
        $rows[1].Account | Should -Be 'B'
        $rows[1].WeeklyPercent | Should -BeNullOrEmpty
        $rows[2].MaxFiveHourPercent | Should -Be 70
    }

    It 'returns nothing when there is no history' {
        @(Get-UsageReport -Path (Join-Path $TestDrive 'none.jsonl')) | Should -HaveCount 0
    }
}
