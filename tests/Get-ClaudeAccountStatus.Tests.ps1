BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'SwitchAccounts.psd1') -Force
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    $fake = Get-FakeClaudePath
    $project = Join-Path $TestDrive 'project'
    New-Item -ItemType Directory -Path $project | Out-Null
}

Describe 'Get-ClaudeAccountStatus' {
    BeforeEach {
        $root = Join-Path $TestDrive "t-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path $root | Out-Null
    }

    It 'lists each account with usage, caps, reset time and readiness' {
        $a = New-SwitchTestAccount -Root $root -Name A -Percent 20 -Weekly 5 -Trusted @($project)
        $b = New-SwitchTestAccount -Root $root -Name B -Percent 55 -Weekly 40 -Trusted @($project) -Extra @{ maxWeeklyPercent = 90 }
        $config = Write-SwitchTestConfig -Path (Join-Path $root 'accounts.json') -Accounts @($a, $b)

        $status = @(Get-ClaudeAccountStatus -ConfigPath $config -Directory $project -ClaudePath $fake)

        $status.Name | Should -Be @('A', 'B')
        $status[0].FiveHourPercent | Should -Be 20
        $status[0].WeeklyPercent | Should -Be 5
        $status[0].ResetsAt | Should -Not -BeNullOrEmpty
        $status[0].MaxFiveHourPercent | Should -Be 80
        $status[1].MaxWeeklyPercent | Should -Be 90
        $status.Decision | Should -Be @('Allow', 'Allow')
        $status.Ready | Should -Be @($true, $true)
        $status.Available | Should -Be @($true, $true)
        $status[0].Line | Should -BeLike 'A: 20% of 5 h (cap 80%*5% weekly*ready'
    }

    It 'reads each account with its own config dir' {
        $a = New-SwitchTestAccount -Root $root -Name A -Trusted @($project)
        $config = Write-SwitchTestConfig -Path (Join-Path $root 'accounts.json') -Accounts @($a)

        Get-ClaudeAccountStatus -ConfigPath $config -Directory $project -ClaudePath $fake | Out-Null

        $calls = Get-FakeCalls -ConfigDir $a.configDir
        $calls | Should -HaveCount 1
        $calls[0].prompt | Should -Be '/usage'
    }

    It 'is not available when the cap is reached, and says when it resets' {
        $a = New-SwitchTestAccount -Root $root -Name A -Percent 95 -Trusted @($project)
        $config = Write-SwitchTestConfig -Path (Join-Path $root 'accounts.json') -Accounts @($a)

        $status = Get-ClaudeAccountStatus -ConfigPath $config -Directory $project -ClaudePath $fake

        $status.Decision | Should -Be 'Wait'
        $status.Available | Should -BeFalse
        $status.RetryAfter | Should -Not -BeNullOrEmpty
        $status.Line | Should -BeLike '*at a cap*'
    }

    It 'is not available when the weekly cap is reached' {
        $a = New-SwitchTestAccount -Root $root -Name A -Percent 10 -Weekly 95 -Trusted @($project) -Extra @{ maxWeeklyPercent = 90 }
        $config = Write-SwitchTestConfig -Path (Join-Path $root 'accounts.json') -Accounts @($a)

        (Get-ClaudeAccountStatus -ConfigPath $config -Directory $project -ClaudePath $fake).Available | Should -BeFalse
    }

    It 'lists an account with no use in the window as 0% and available' {
        $a = New-SwitchTestAccount -Root $root -Name A -IdleUsage -Trusted @($project)
        $config = Write-SwitchTestConfig -Path (Join-Path $root 'accounts.json') -Accounts @($a)

        $status = Get-ClaudeAccountStatus -ConfigPath $config -Directory $project -ClaudePath $fake

        $status.UsageStatus | Should -Be 'Known'
        $status.FiveHourPercent | Should -Be 0
        $status.ResetsAt | Should -BeNullOrEmpty
        $status.Available | Should -BeTrue
        $status.Line | Should -BeLike 'A: 0% of 5 h (cap 80%, resets unknown), weekly unknown*'
    }

    It 'still blocks that account when a weekly cap is set, because the weekly usage is unknown' {
        $a = New-SwitchTestAccount -Root $root -Name A -IdleUsage -Trusted @($project) -Extra @{ maxWeeklyPercent = 90 }
        $config = Write-SwitchTestConfig -Path (Join-Path $root 'accounts.json') -Accounts @($a)

        (Get-ClaudeAccountStatus -ConfigPath $config -Directory $project -ClaudePath $fake).Available | Should -BeFalse
    }

    It 'discards an account whose usage is unknown instead of reading it as 0%' {
        $a = New-SwitchTestAccount -Root $root -Name A -UnknownUsage -Trusted @($project)
        $config = Write-SwitchTestConfig -Path (Join-Path $root 'accounts.json') -Accounts @($a)

        $status = Get-ClaudeAccountStatus -ConfigPath $config -Directory $project -ClaudePath $fake

        $status.UsageStatus | Should -Be 'Unknown'
        $status.FiveHourPercent | Should -BeNullOrEmpty
        $status.Available | Should -BeFalse
        $status.Line | Should -BeLike 'A: usage unknown, not available*'
    }

    It 'reports readiness separately from usage' -TestCases @(
        @{ Case = 'first start'; Onboarded = $false; Trusted = @(); State = 'FirstRun' }
        @{ Case = 'untrusted folder'; Onboarded = $true; Trusted = @(); State = 'Untrusted' }
    ) {
        $a = New-SwitchTestAccount -Root $root -Name A -Onboarded $Onboarded -Trusted $(if ($Trusted.Count) { $Trusted } else { @() })
        $config = Write-SwitchTestConfig -Path (Join-Path $root 'accounts.json') -Accounts @($a)

        $status = Get-ClaudeAccountStatus -ConfigPath $config -Directory $project -ClaudePath $fake

        $status.Onboarding | Should -Be $State
        $status.Ready | Should -BeFalse
        $status.Available | Should -BeFalse
        $status.Decision | Should -Be 'Allow'
        $status.Line | Should -BeLike "*not ready ($State)"
    }

    It 'is Missing when the config dir does not exist' {
        $config = Write-SwitchTestConfig -Path (Join-Path $root 'accounts.json') -Accounts @(
            [ordered]@{ name = 'Ghost'; configDir = (Join-Path $root 'nowhere') })

        $status = Get-ClaudeAccountStatus -ConfigPath $config -Directory $project -ClaudePath $fake

        $status.Onboarding | Should -Be 'Missing'
        $status.Available | Should -BeFalse
    }

    It 'filters by name and can skip reading usage' {
        $a = New-SwitchTestAccount -Root $root -Name A -Trusted @($project)
        $b = New-SwitchTestAccount -Root $root -Name B -Trusted @($project)
        $config = Write-SwitchTestConfig -Path (Join-Path $root 'accounts.json') -Accounts @($a, $b)

        $status = @(Get-ClaudeAccountStatus -ConfigPath $config -Directory $project -ClaudePath $fake -Name B -SkipUsage)

        $status | Should -HaveCount 1
        $status[0].Name | Should -Be 'B'
        $status[0].UsageStatus | Should -Be 'Unknown'
        Get-FakeCalls -ConfigDir $b.configDir | Should -HaveCount 0
        Get-FakeCalls -ConfigDir $a.configDir | Should -HaveCount 0
    }

    It 'does not create the config file when it does not exist' {
        $config = Join-Path $root 'accounts.json'

        { Get-ClaudeAccountStatus -ConfigPath $config -Directory $project -ClaudePath (Join-Path $root 'no-claude') -SkipUsage } | Should -Not -Throw

        Test-Path -LiteralPath $config | Should -BeFalse
    }

    It 'never prints anything from the account files' {
        $a = New-SwitchTestAccount -Root $root -Name A -Trusted @($project)
        Set-Content -LiteralPath (Join-Path $a.configDir '.credentials.json') -Value '{"accessToken":"synthetic-secret-token"}'
        $config = Write-SwitchTestConfig -Path (Join-Path $root 'accounts.json') -Accounts @($a)

        $status = Get-ClaudeAccountStatus -ConfigPath $config -Directory $project -ClaudePath $fake

        ($status | ConvertTo-Json -Depth 5) | Should -Not -Match 'synthetic-secret-token|synthetic-user'
    }
}
