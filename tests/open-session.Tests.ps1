BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'SwitchAccounts.psd1') -Force
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    $fake = Get-FakeClaudePath
    $script = Join-Path $PSScriptRoot '..' 'scripts' 'open-session.ps1'

    # Runs the wrapper in its own pwsh. Every call that could open a tab carries -PrintOnly or fails first.
    function Invoke-Wrapper {
        param([string[]] $Arguments)
        $stdout = Join-Path $TestDrive "out-$([guid]::NewGuid()).txt"
        $stderr = Join-Path $TestDrive "err-$([guid]::NewGuid()).txt"
        $old = $env:SWITCH_ACCOUNTS_ALLOW_OVERRIDES
        try {
            $env:SWITCH_ACCOUNTS_ALLOW_OVERRIDES = '1'
            $process = Start-Process -FilePath (Get-Process -Id $PID).Path -Wait -PassThru -NoNewWindow `
                -RedirectStandardOutput $stdout -RedirectStandardError $stderr `
                -ArgumentList (@('-NoProfile', '-File', $script) + $Arguments)
        } finally {
            if ($null -eq $old) { Remove-Item Env:SWITCH_ACCOUNTS_ALLOW_OVERRIDES -ErrorAction SilentlyContinue }
            else { $env:SWITCH_ACCOUNTS_ALLOW_OVERRIDES = $old }
        }
        [pscustomobject]@{
            ExitCode = $process.ExitCode
            Out      = (Get-Content -LiteralPath $stdout -Raw -Encoding utf8) + ''
            Err      = (Get-Content -LiteralPath $stderr -Raw -Encoding utf8) + ''
        }
    }

    function New-WrapperFixture {
        param([hashtable[]] $Accounts)
        $root = Join-Path $TestDrive "w-$([guid]::NewGuid())"
        $project = Join-Path $root 'project'
        New-Item -ItemType Directory -Path $project -Force | Out-Null
        $entries = foreach ($spec in $Accounts) {
            $arguments = @{ Root = $root; Trusted = @($project) }
            foreach ($key in $spec.Keys) { $arguments[$key] = $spec[$key] }
            New-SwitchTestAccount @arguments
        }
        $config = Write-SwitchTestConfig -Path (Join-Path $root 'accounts.json') -Accounts @($entries)
        @{ Root = $root; Project = $project; Config = $config }
    }
}

Describe 'scripts/open-session.ps1' {
    It 'prints the summary line and exits 0' {
        $f = New-WrapperFixture @(@{ Name = 'B'; Percent = '10' })

        $run = Invoke-Wrapper @('-ConfigPath', $f.Config, '-ClaudePath', $fake, '-Directory', $f.Project, '-Model', 'sonnet', '-Effort', 'high', '-RemoteControl', '-PrintOnly')

        $run.ExitCode | Should -Be 0
        $first = ($run.Out -split '\r?\n')[0]
        $first | Should -Be "Simulada (no abierta): cuenta B · sonnet · effort high · RC «project · B» · $($f.Project)"
        $run.Out | Should -Match "--model 'sonnet' --effort 'high'"
    }

    It 'prints the result as JSON with -Json' {
        $f = New-WrapperFixture @(@{ Name = 'B'; Percent = '10' })

        $run = Invoke-Wrapper @('-ConfigPath', $f.Config, '-ClaudePath', $fake, '-Directory', $f.Project, '-Model', 'haiku', '-PrintOnly', '-Json')

        $run.ExitCode | Should -Be 0
        $json = $run.Out | ConvertFrom-Json
        $json.Account | Should -Be 'B'
        $json.Model | Should -Be 'haiku'
        $json.Opened | Should -BeFalse
        $json.Summary | Should -BeLike 'Simulada*'
    }

    It 'opens nothing with -WhatIf' {
        $f = New-WrapperFixture @(@{ Name = 'B'; Percent = '10' })

        $run = Invoke-Wrapper @('-ConfigPath', $f.Config, '-ClaudePath', $fake, '-Directory', $f.Project, '-WhatIf')

        $run.ExitCode | Should -Be 0
        $run.Out | Should -BeLike '*Simulada (no abierta)*'
    }

    It 'lists the accounts with -List' {
        $f = New-WrapperFixture @(@{ Name = 'A'; Percent = '10' }, @{ Name = 'B'; Percent = '90' })

        $run = Invoke-Wrapper @('-List', '-ConfigPath', $f.Config, '-ClaudePath', $fake, '-Directory', $f.Project)

        $run.ExitCode | Should -Be 0
        $lines = @($run.Out -split '\r?\n' | Where-Object { $_ })
        $lines | Should -HaveCount 2
        $lines[0] | Should -BeLike 'A: 10% of 5 h*below caps, ready'
        $lines[1] | Should -BeLike 'B: 90% of 5 h*at a cap, ready'
    }

    It 'lists the accounts as JSON without the display line' {
        $f = New-WrapperFixture @(@{ Name = 'A'; Percent = '10' })

        $run = Invoke-Wrapper @('-List', '-Json', '-ConfigPath', $f.Config, '-ClaudePath', $fake, '-Directory', $f.Project)

        $run.ExitCode | Should -Be 0
        $json = @($run.Out | ConvertFrom-Json)
        $json[0].Name | Should -Be 'A'
        $json[0].FiveHourPercent | Should -Be 10
        $json[0].PSObject.Properties.Name | Should -Not -Contain 'Line'
    }

    It 'shows the config with -ShowConfig and creates it with defaults when missing' {
        $path = Join-Path $TestDrive "show-$([guid]::NewGuid())" 'accounts.json'

        $run = Invoke-Wrapper @('-ShowConfig', '-ConfigPath', $path)

        $run.ExitCode | Should -Be 0
        $run.Out | Should -BeLike "Config file: $path (created with defaults)*"
        $run.Out | Should -Match '"maxFiveHourPercent": 80'
        Test-Path -LiteralPath $path | Should -BeTrue
    }

    It 'exits <Code> for <Case>' -TestCases @(
        @{ Case = 'a bad model'; Code = 2; Extra = @('-Model', 'gpt-5', '-PrintOnly') }
        @{ Case = 'a bad effort'; Code = 2; Extra = @('-Effort', 'ultra', '-PrintOnly') }
        @{ Case = 'a bad count'; Code = 2; Extra = @('-Count', 'many', '-PrintOnly') }
        @{ Case = 'a count out of range'; Code = 2; Extra = @('-Count', '9', '-PrintOnly') }
        @{ Case = 'an unknown account'; Code = 2; Extra = @('-Account', 'Zed', '-PrintOnly') }
        @{ Case = 'a prompt that starts with a dash'; Code = 2; Extra = @('-InitialPrompt', '--version', '-PrintOnly') }
    ) {
        $f = New-WrapperFixture @(@{ Name = 'A'; Percent = '10' })

        $run = Invoke-Wrapper (@('-ConfigPath', $f.Config, '-ClaudePath', $fake, '-Directory', $f.Project) + $Extra)

        $run.ExitCode | Should -Be $Code
        $run.Err | Should -Not -BeNullOrEmpty
        $run.Out | Should -Not -BeLike 'Abierta*'
    }

    It 'exits 3 when no account can start, with the reset time' {
        $f = New-WrapperFixture @(@{ Name = 'A'; Percent = '95' })

        $run = Invoke-Wrapper @('-ConfigPath', $f.Config, '-ClaudePath', $fake, '-Directory', $f.Project, '-PrintOnly')

        $run.ExitCode | Should -Be 3
        $run.Err | Should -BeLike '*No account can start now*Earliest reset*'
    }

    It 'exits 4 when the account is not ready, and says what to do' {
        $f = New-WrapperFixture @(@{ Name = 'A'; Percent = '10'; Onboarded = $false })

        $run = Invoke-Wrapper @('-ConfigPath', $f.Config, '-ClaudePath', $fake, '-Directory', $f.Project, '-Account', 'A', '-PrintOnly')

        $run.ExitCode | Should -Be 4
        $run.Err | Should -BeLike '*first start*'
    }

    It 'exits 5 when the CLI is missing, before any tab is attempted' {
        $f = New-WrapperFixture @(@{ Name = 'A'; Percent = '10' })

        $run = Invoke-Wrapper @('-ConfigPath', $f.Config, '-ClaudePath', (Join-Path $f.Root 'no-claude'), '-Directory', $f.Project, '-Account', 'A', '-NoUsageCheck')

        $run.ExitCode | Should -Be 5
        $run.Err | Should -BeLike '*CLI not found*'
    }

    It 'exits 2 when the config path is a folder, and writes nothing into it' {
        $f = New-WrapperFixture @(@{ Name = 'A' })

        $run = Invoke-Wrapper @('-ConfigPath', $f.Root, '-ClaudePath', $fake, '-Directory', $f.Project, '-PrintOnly')

        $run.ExitCode | Should -Be 2
        Get-ChildItem -LiteralPath $f.Root -Filter '*.tmp' | Should -BeNullOrEmpty
    }

    It 'refuses -ConfigPath and -ClaudePath unless the test switch is set' {
        $f = New-WrapperFixture @(@{ Name = 'A'; Percent = '10' })
        $stdout = Join-Path $TestDrive "o-$([guid]::NewGuid()).txt"
        $stderr = Join-Path $TestDrive "e-$([guid]::NewGuid()).txt"
        $old = $env:SWITCH_ACCOUNTS_ALLOW_OVERRIDES
        try {
            Remove-Item Env:SWITCH_ACCOUNTS_ALLOW_OVERRIDES -ErrorAction SilentlyContinue
            $process = Start-Process -FilePath (Get-Process -Id $PID).Path -Wait -PassThru -NoNewWindow `
                -RedirectStandardOutput $stdout -RedirectStandardError $stderr `
                -ArgumentList @('-NoProfile', '-File', $script, '-ClaudePath', $fake, '-Directory', $f.Project, '-PrintOnly')
        } finally {
            if ($old) { $env:SWITCH_ACCOUNTS_ALLOW_OVERRIDES = $old }
        }

        $process.ExitCode | Should -Be 2
        Get-Content -LiteralPath $stderr -Raw | Should -BeLike '*for tests*'
    }

    It 'documents every exit code' {
        $help = Get-Content -LiteralPath $script -Raw
        foreach ($code in '0', '1', '2', '3', '4', '5') { $help | Should -Match "(?s)Exit codes:.*\b$code\b" }
    }
}
