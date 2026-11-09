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
        $status[0].Line | Should -BeLike 'A: 20% of 5 h (cap 80%*5% weekly*ready*'
    }

    It 'reads each account with its own config dir' {
        $a = New-SwitchTestAccount -Root $root -Name A -Trusted @($project)
        $config = Write-SwitchTestConfig -Path (Join-Path $root 'accounts.json') -Accounts @($a)

        Get-ClaudeAccountStatus -ConfigPath $config -Directory $project -ClaudePath $fake | Out-Null

        $calls = @(Get-FakeCalls -ConfigDir $a.configDir)
        $calls.prompt | Should -Be @('auth status', '/usage')
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
        $status.Line | Should -BeLike "*not ready ($State)*"
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

    It 'reports a logged-out account with the login command and does not ask it for /usage' {
        $a = New-SwitchTestAccount -Root $root -Name A -Trusted @($project)
        Set-Content -LiteralPath (Join-Path $a.configDir 'fake-auth.json') -Value '{"loggedIn":false,"authMethod":"none","loginExpiresAt":null}'
        $config = Write-SwitchTestConfig -Path (Join-Path $root 'accounts.json') -Accounts @($a)

        $status = Get-ClaudeAccountStatus -ConfigPath $config -Directory $project -ClaudePath $fake

        $status.AuthStatus | Should -Be 'LoggedOut'
        $status.UsageStatus | Should -Be 'Unknown'
        $status.Available | Should -BeFalse
        $status.LoginCommand | Should -BeLike '*CLAUDE_CONFIG_DIR*claude auth login*'
        $status.Line | Should -BeLike 'A: not logged in*claude auth login*'
        @(Get-FakeCalls -ConfigDir $a.configDir).prompt | Should -Be @('auth status')
    }

    It 'adds plan and login expiry, and reads several accounts side by side' {
        $a = New-SwitchTestAccount -Root $root -Name A -Trusted @($project)
        $b = New-SwitchTestAccount -Root $root -Name B -Trusted @($project)
        $c = New-SwitchTestAccount -Root $root -Name C -Trusted @($project)
        $config = Write-SwitchTestConfig -Path (Join-Path $root 'accounts.json') -Accounts @($a, $b, $c)

        $status = @(Get-ClaudeAccountStatus -ConfigPath $config -Directory $project -ClaudePath $fake)

        $status.Name | Should -Be @('A', 'B', 'C')
        $status.AuthStatus | Should -Be @('LoggedIn', 'LoggedIn', 'LoggedIn')
        $status[0].PlanTier | Should -Be 'max_5x'
        $status[0].LoginExpiresAt.Year | Should -Be 2099
        $status[0].Line | Should -BeLike '*ready; max_5x, login until *'
    }

    It 'still reads /usage when the login cannot be read' {
        $a = New-SwitchTestAccount -Root $root -Name A -Percent 30 -Trusted @($project)
        Set-Content -LiteralPath (Join-Path $a.configDir 'fake-auth.json') -Value 'error: unknown option --json'
        $config = Write-SwitchTestConfig -Path (Join-Path $root 'accounts.json') -Accounts @($a)

        $status = Get-ClaudeAccountStatus -ConfigPath $config -Directory $project -ClaudePath $fake

        $status.AuthStatus | Should -Be 'Unknown'
        $status.FiveHourPercent | Should -Be 30
        $status.Available | Should -BeTrue
    }

    It 'never prints anything from the account files' {
        $a = New-SwitchTestAccount -Root $root -Name A -Trusted @($project)
        Set-Content -LiteralPath (Join-Path $a.configDir '.credentials.json') -Value '{"accessToken":"synthetic-secret-token"}'
        $config = Write-SwitchTestConfig -Path (Join-Path $root 'accounts.json') -Accounts @($a)

        $status = Get-ClaudeAccountStatus -ConfigPath $config -Directory $project -ClaudePath $fake

        ($status | ConvertTo-Json -Depth 5) | Should -Not -Match 'synthetic-secret-token|synthetic-user'
    }
}

Describe 'Save-FleetSnapshot' {
    It 'writes schema 1 beside accounts.json with login, usage and caps, and no account secrets' {
        $root = Join-Path $TestDrive "s-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path $root | Out-Null
        $a = New-SwitchTestAccount -Root $root -Name A -Percent 40 -Trusted @($project)
        Set-Content -LiteralPath (Join-Path $a.configDir '.credentials.json') -Value '{"accessToken":"synthetic-secret-token"}'
        $config = Write-SwitchTestConfig -Path (Join-Path $root 'accounts.json') -Accounts @($a)
        $status = @(Get-ClaudeAccountStatus -ConfigPath $config -Directory $project -ClaudePath $fake)

        $path = Save-FleetSnapshot -Statuses $status -ConfigPath $config -Now ([DateTimeOffset]::new(2030, 1, 1, 12, 0, 0, [TimeSpan]::Zero))

        $path | Should -Be (Join-Path $root 'status.json')
        $raw = Get-Content -LiteralPath $path -Raw
        $raw | Should -Not -Match 'synthetic-secret-token|synthetic-user'
        $doc = $raw | ConvertFrom-Json
        $doc.schema | Should -Be 1
        $raw | Should -Match '"updatedAt": "2030-01-01T12:00:00Z"'
        $doc.accounts[0].name | Should -Be 'A'
        $doc.accounts[0].auth.status | Should -Be 'LoggedIn'
        $doc.accounts[0].auth.tier | Should -Be 'max_5x'
        $doc.accounts[0].usage.fiveHourPercent | Should -Be 40
        $doc.accounts[0].caps.fiveHour | Should -Be 80
        $doc.accounts[0].available | Should -BeTrue
        @(Get-ChildItem -LiteralPath $root -Filter '*.tmp') | Should -HaveCount 0
    }
}

Describe 'Remove-StaleFleetBeat' {
    It 'deletes heartbeats untouched for a day and keeps fresh ones' {
        $live = Join-Path $TestDrive "live-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path $live | Out-Null
        $old = New-Item -ItemType File -Path (Join-Path $live 'old.json')
        $old.LastWriteTimeUtc = [datetime]::UtcNow.AddHours(-30)
        New-Item -ItemType File -Path (Join-Path $live 'new.json') | Out-Null
        New-Item -ItemType File -Path (Join-Path $live 'keep.txt') | Out-Null
        (Get-Item (Join-Path $live 'keep.txt')).LastWriteTimeUtc = [datetime]::UtcNow.AddDays(-5)

        & (Get-Module SwitchAccounts) { param($d) Remove-StaleFleetBeat -LiveDir $d } $live

        (Get-ChildItem -LiteralPath $live).Name | Sort-Object | Should -Be @('keep.txt', 'new.json')
    }
}

Describe 'Add-UsageHistory' {
    It 'appends one line per account with known usage and drops lines older than 8 days' {
        $dir = Join-Path $TestDrive "h-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path $dir | Out-Null
        $path = Join-Path $dir 'usage-history.jsonl'
        $now = [DateTimeOffset]::new(2030, 1, 10, 12, 0, 0, [TimeSpan]::Zero)
        Set-Content -LiteralPath $path -Value @(
            '{"at":"2030-01-01T00:00:00Z","name":"A","fiveHour":1}'
            '{"at":"2030-01-09T00:00:00Z","name":"A","fiveHour":2}'
            'not json'
        )
        $statuses = @(
            [pscustomobject]@{ Name = 'A'; UsageStatus = 'Known'; FiveHourPercent = 44; ResetsAt = $now.AddHours(2); WeeklyPercent = 6; WeeklyResetsAt = $null }
            [pscustomobject]@{ Name = 'B'; UsageStatus = 'Unknown'; FiveHourPercent = $null; ResetsAt = $null; WeeklyPercent = $null; WeeklyResetsAt = $null }
        )

        & (Get-Module SwitchAccounts) { param($p, $s, $n) Add-UsageHistory -Path $p -Statuses $s -Now $n } $path $statuses $now

        $lines = @(Get-Content -LiteralPath $path)
        $lines | Should -HaveCount 2
        $lines[0] | Should -BeLike '*"fiveHour":2*'
        $last = $lines[1] | ConvertFrom-Json -DateKind String
        $last.name | Should -Be 'A'
        $last.fiveHour | Should -Be 44
        $last.at | Should -Be '2030-01-10T12:00:00Z'
        $last.fiveHourResetsAt | Should -Be '2030-01-10T14:00:00Z'
    }
}
