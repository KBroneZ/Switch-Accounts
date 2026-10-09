BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'SwitchAccounts.psd1') -Force
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    $fake = Get-FakeClaudePath

    # Never opens a real tab: Start-TerminalTab is replaced in every test.
    function New-Fixture {
        param([hashtable[]] $Accounts)
        $root = Join-Path $TestDrive "t-$([guid]::NewGuid())"
        $project = Join-Path $root 'project'
        New-Item -ItemType Directory -Path $project -Force | Out-Null
        $entries = foreach ($spec in $Accounts) {
            $arguments = @{ Root = $root; Trusted = @($project) } + $spec
            New-SwitchTestAccount @arguments
        }
        $config = Write-SwitchTestConfig -Path (Join-Path $root 'accounts.json') -Accounts @($entries)
        @{ Root = $root; Project = $project; Config = $config; Entries = @($entries) }
    }

    function Open-Test {
        param($Fixture, [hashtable] $Arguments = @{})
        $all = @{ Directory = $Fixture.Project; ConfigPath = $Fixture.Config; ClaudePath = $fake; WtPath = 'wt-not-used' }
        foreach ($key in $Arguments.Keys) { $all[$key] = $Arguments[$key] }
        Open-ClaudeSession @all
    }

}

Describe 'Open-ClaudeSession' {
    BeforeEach {
        Mock -ModuleName SwitchAccounts Start-TerminalTab {}
    }

    Context 'choosing the account' {
        It 'auto picks the account with the lowest 5-hour usage' {
            $f = New-Fixture @(@{ Name = 'A'; Percent = '50' }, @{ Name = 'B'; Percent = '15' })

            $result = Open-Test $f -Arguments @{ PrintOnly = $true }

            $result.Account | Should -Be 'B'
        }

        It 'auto is the default' {
            $f = New-Fixture @(@{ Name = 'A'; Percent = '50' }, @{ Name = 'B'; Percent = '15' })

            (Open-Test $f -Arguments @{ PrintOnly = $true }).Account | Should -Be 'B'
        }

        It 'auto breaks a tie by the order of the config' {
            $f = New-Fixture @(@{ Name = 'A'; Percent = '30' }, @{ Name = 'B'; Percent = '30' })

            (Open-Test $f -Arguments @{ PrintOnly = $true }).Account | Should -Be 'A'
        }

        It 'auto skips an account at its cap' {
            $f = New-Fixture @(@{ Name = 'A'; Percent = '90' }, @{ Name = 'B'; Percent = '60' })

            (Open-Test $f -Arguments @{ PrintOnly = $true }).Account | Should -Be 'B'
        }

        It 'auto skips an account over its weekly cap' {
            $f = New-Fixture @(
                @{ Name = 'A'; Percent = '5'; Weekly = '95'; Extra = @{ maxWeeklyPercent = 90 } }
                @{ Name = 'B'; Percent = '60' })

            (Open-Test $f -Arguments @{ PrintOnly = $true }).Account | Should -Be 'B'
        }

        It 'auto discards an account with unknown usage even if the other is busier' {
            $f = New-Fixture @(@{ Name = 'A'; UnknownUsage = $true }, @{ Name = 'B'; Percent = '70' })

            (Open-Test $f -Arguments @{ PrintOnly = $true }).Account | Should -Be 'B'
        }

        It 'auto skips an account that is not ready for the folder' {
            $f = New-Fixture @(@{ Name = 'A'; Percent = '5'; Onboarded = $false }, @{ Name = 'B'; Percent = '60' })

            (Open-Test $f -Arguments @{ PrintOnly = $true }).Account | Should -Be 'B'
        }

        It 'auto skips an account without Remote Control when -RemoteControl is asked' {
            $f = New-Fixture @(@{ Name = 'A'; Percent = '5'; RemoteControl = $false }, @{ Name = 'B'; Percent = '60' })

            (Open-Test $f -Arguments @{ PrintOnly = $true; RemoteControl = $true }).Account | Should -Be 'B'
            (Open-Test $f -Arguments @{ PrintOnly = $true }).Account | Should -Be 'A'
        }

        It 'fails with NoAccountAvailable and the reset time when every account is at its cap' {
            $f = New-Fixture @(@{ Name = 'A'; Percent = '90' }, @{ Name = 'B'; Percent = '85' })

            { Open-Test $f } | Should -Throw -ErrorId 'SwitchAccounts.NoAccountAvailable' -ExpectedMessage '*Earliest reset*'
            Should -Invoke -ModuleName SwitchAccounts Start-TerminalTab -Times 0
        }

        It 'fails with NoAccountAvailable when every usage is unknown' {
            $f = New-Fixture @(@{ Name = 'A'; UnknownUsage = $true }, @{ Name = 'B'; UnknownUsage = $true })

            { Open-Test $f } | Should -Throw -ErrorId 'SwitchAccounts.NoAccountAvailable' -ExpectedMessage '*usage unknown*'
        }

        It 'fails with NoAccountAvailable when no account below its cap allows Remote Control' {
            $f = New-Fixture @(@{ Name = 'A'; Percent = '5'; RemoteControl = $false })

            { Open-Test $f -Arguments @{ RemoteControl = $true } } | Should -Throw -ErrorId 'SwitchAccounts.NoAccountAvailable' -ExpectedMessage '*Remote Control*'
        }

        It 'fails with NotReady when the only account below its cap has not finished its first start' {
            $f = New-Fixture @(@{ Name = 'A'; Percent = '5'; Onboarded = $false }, @{ Name = 'B'; Percent = '95' })

            { Open-Test $f } | Should -Throw -ErrorId 'SwitchAccounts.NotReady' -ExpectedMessage '*first start*'
        }

        It 'opens a named account, ignoring case, even if another one is less used' {
            $f = New-Fixture @(@{ Name = 'A'; Percent = '5' }, @{ Name = 'B'; Percent = '70' })

            (Open-Test $f -Arguments @{ Account = 'b'; PrintOnly = $true }).Account | Should -Be 'B'
        }

        It 'warns, but still opens, a named account at its cap' {
            $f = New-Fixture @(@{ Name = 'A'; Percent = '90' })

            $result = Open-Test $f -Arguments @{ Account = 'A'; PrintOnly = $true }

            $result.Account | Should -Be 'A'
            $result.Warnings | Should -HaveCount 1
            $result.Warnings[0] | Should -BeLike '*A*reached the cap*'
        }

        It 'does not read usage of a named account with -NoUsageCheck' {
            $f = New-Fixture @(@{ Name = 'A'; Percent = '90' })

            $result = Open-Test $f -Arguments @{ Account = 'A'; PrintOnly = $true; NoUsageCheck = $true }

            $result.Warnings | Should -HaveCount 0
            Get-FakeCalls -ConfigDir $f.Entries[0].configDir | Should -HaveCount 0
        }

        It 'refuses an unknown account and lists the configured ones' {
            $f = New-Fixture @(@{ Name = 'A' })

            { Open-Test $f -Arguments @{ Account = 'Z' } } | Should -Throw -ErrorId 'SwitchAccounts.InvalidArgument' -ExpectedMessage '*Configured: A*'
        }

        It 'refuses -RemoteControl on a named account that has it turned off' {
            $f = New-Fixture @(@{ Name = 'A'; RemoteControl = $false })

            { Open-Test $f -Arguments @{ Account = 'A'; RemoteControl = $true } } | Should -Throw -ErrorId 'SwitchAccounts.InvalidArgument' -ExpectedMessage '*Remote Control*off*'
        }
    }

    Context 'readiness' {
        It 'does not start a named account that has not finished its first start' {
            $f = New-Fixture @(@{ Name = 'A'; Onboarded = $false })

            { Open-Test $f -Arguments @{ Account = 'A' } } | Should -Throw -ErrorId 'SwitchAccounts.NotReady' -ExpectedMessage '*first start*'
            Should -Invoke -ModuleName SwitchAccounts Start-TerminalTab -Times 0
        }

        It 'does not start in a folder the account does not trust, and leaves its config alone' {
            $f = New-Fixture @(@{ Name = 'A' })
            $other = Join-Path $f.Root 'other'
            New-Item -ItemType Directory -Path $other | Out-Null
            $json = Join-Path $f.Entries[0].configDir '.claude.json'
            $before = (Get-FileHash -LiteralPath $json).Hash

            { Open-Test $f -Arguments @{ Account = 'A'; Directory = $other } } | Should -Throw -ErrorId 'SwitchAccounts.NotReady' -ExpectedMessage '*not trusted*-TrustDirectory*'

            (Get-FileHash -LiteralPath $json).Hash | Should -Be $before
            Should -Invoke -ModuleName SwitchAccounts Start-TerminalTab -Times 0
        }

        It 'marks the folder as trusted only with -TrustDirectory' {
            $f = New-Fixture @(@{ Name = 'A' })
            $other = Join-Path $f.Root 'other'
            New-Item -ItemType Directory -Path $other | Out-Null

            $result = Open-Test $f -Arguments @{ Account = 'A'; Directory = $other; TrustDirectory = $true }

            $result.Opened | Should -BeTrue
            $trusted = (Get-Content -LiteralPath (Join-Path $f.Entries[0].configDir '.claude.json') -Raw | ConvertFrom-Json).projects
            ($trusted.PSObject.Properties | Where-Object { $_.Value.hasTrustDialogAccepted }).Name | Should -Contain $other
        }

        It 'does not change the account config under -PrintOnly or -WhatIf, but says it would' {
            $f = New-Fixture @(@{ Name = 'A' })
            $other = Join-Path $f.Root 'other'
            New-Item -ItemType Directory -Path $other | Out-Null
            $json = Join-Path $f.Entries[0].configDir '.claude.json'
            $before = (Get-FileHash -LiteralPath $json).Hash

            $print = Open-Test $f -Arguments @{ Account = 'A'; Directory = $other; TrustDirectory = $true; PrintOnly = $true }
            $whatIf = Open-Test $f -Arguments @{ Account = 'A'; Directory = $other; TrustDirectory = $true; WhatIf = $true }

            (Get-FileHash -LiteralPath $json).Hash | Should -Be $before
            $print.Warnings | Should -Contain "would mark $other as trusted for account A"
            $whatIf.Opened | Should -BeFalse
        }

        It 'does not let -TrustDirectory rescue an account that has not finished its first start' {
            $f = New-Fixture @(@{ Name = 'A'; Onboarded = $false })

            { Open-Test $f -Arguments @{ Account = 'A'; TrustDirectory = $true } } | Should -Throw -ErrorId 'SwitchAccounts.NotReady'
        }

        It 'refuses to trust a drive root even when asked' {
            $f = New-Fixture @(@{ Name = 'A' })
            $root = [IO.Path]::GetPathRoot($f.Root)

            { Open-Test $f -Arguments @{ Account = 'A'; Directory = $root; TrustDirectory = $true } } | Should -Throw -ErrorId 'SwitchAccounts.InvalidArgument'
        }
    }

    Context 'launching' {
        It 'opens one tab with the chosen settings and returns the summary' {
            $f = New-Fixture @(@{ Name = 'B'; Percent = '10'; Extra = @{ defaultSubagentModel = 'haiku' } })

            $result = Open-Test $f -Arguments @{ Model = 'sonnet'; Effort = 'high'; RemoteControl = $true; SessionName = 'review run' }

            $result.Opened | Should -BeTrue
            $result.Account | Should -Be 'B'
            $result.Model | Should -Be 'sonnet'
            $result.Effort | Should -Be 'high'
            $result.SubagentModel | Should -Be 'haiku'
            $result.RemoteControlName | Should -Be 'review run'
            $result.Directory | Should -Be $f.Project
            $result.Summary | Should -Be "Abierta: cuenta B · sonnet · effort high · subagentes haiku · RC «review run» · $($f.Project)"
            Should -Invoke -ModuleName SwitchAccounts Start-TerminalTab -Times 1 -Exactly -ParameterFilter {
                $WtPath -eq 'wt-not-used' -and $Arguments[0] -eq '-w' -and $Arguments -contains 'new-tab'
            }
        }

        It 'puts the settings in the script of the tab' {
            $f = New-Fixture @(@{ Name = 'B' })

            $result = Open-Test $f -Arguments @{
                Model = 'opus'; Effort = 'max'; SubagentModel = 'haiku'; RemoteControl = $true; InitialPrompt = 'do it'
            }

            $script = $result.Sessions[0].Script
            $script | Should -Match ([regex]::Escape("`$env:CLAUDE_CONFIG_DIR = '$($f.Entries[0].configDir)'"))
            $script | Should -Match "CLAUDE_CODE_SUBAGENT_MODEL = 'haiku'"
            $script | Should -Match ([regex]::Escape("--remote-control '$($result.RemoteControlName)' --model 'opus' --effort 'max' 'do it'"))
        }

        It 'always names a Remote Control session, by folder and account when no name is given' {
            $f = New-Fixture @(@{ Name = 'B' })

            $result = Open-Test $f -Arguments @{ RemoteControl = $true; PrintOnly = $true }

            $result.RemoteControlName | Should -Be 'project · B'
            $result.Sessions[0].Script | Should -Match "--remote-control 'project · B'"
        }

        It 'does not start Remote Control unless asked' {
            $f = New-Fixture @(@{ Name = 'B' })

            $result = Open-Test $f -Arguments @{ PrintOnly = $true }

            $result.RemoteControlName | Should -BeNullOrEmpty
            $result.Sessions[0].Script | Should -Not -Match 'remote-control'
        }

        It 'uses the account defaults when nothing is asked, and lets the request win' {
            $f = New-Fixture @(@{ Name = 'B'; Extra = @{ defaultModel = 'haiku'; defaultEffort = 'low' } })

            $plain = Open-Test $f -Arguments @{ PrintOnly = $true }
            $asked = Open-Test $f -Arguments @{ PrintOnly = $true; Model = 'opus' }

            $plain.Model | Should -Be 'haiku'
            $plain.Effort | Should -Be 'low'
            $asked.Model | Should -Be 'opus'
            $asked.Effort | Should -Be 'low'
        }

        It 'opens -Count numbered tabs with numbered titles and Remote Control names' {
            $f = New-Fixture @(@{ Name = 'A' })

            $result = Open-Test $f -Arguments @{ RemoteControl = $true; SessionName = 'batch'; Title = 'Run'; Count = 3 }

            $result.Sessions.Title | Should -Be @('Run #1', 'Run #2', 'Run #3')
            $result.Sessions.RemoteControlName | Should -Be @('batch #1', 'batch #2', 'batch #3')
            $result.Summary | Should -BeLike 'Abiertas 3 pestañas: *RC «batch #1-3»*'
            Should -Invoke -ModuleName SwitchAccounts Start-TerminalTab -Times 3 -Exactly
        }

        It 'opens nothing with -PrintOnly and returns the plan' {
            $f = New-Fixture @(@{ Name = 'A' })

            $result = Open-Test $f -Arguments @{ PrintOnly = $true; Model = 'haiku'; Effort = 'low' }

            $result.Opened | Should -BeFalse
            $result.Summary | Should -BeLike 'Simulada (no abierta): cuenta A · haiku · effort low*'
            $result.Sessions[0].Script | Should -Match "--model 'haiku' --effort 'low'"
            Should -Invoke -ModuleName SwitchAccounts Start-TerminalTab -Times 0
        }

        It 'opens nothing with -WhatIf' {
            $f = New-Fixture @(@{ Name = 'A' })

            $result = Open-Test $f -Arguments @{ WhatIf = $true }

            $result.Opened | Should -BeFalse
            Should -Invoke -ModuleName SwitchAccounts Start-TerminalTab -Times 0
        }

        It 'reports a tab that could not open' {
            Mock -ModuleName SwitchAccounts Start-TerminalTab { throw 'wt exploded' }
            $f = New-Fixture @(@{ Name = 'A' })

            { Open-Test $f } | Should -Throw -ErrorId 'SwitchAccounts.Environment' -ExpectedMessage '*tab 1 of 1*wt exploded*'
        }

        It 'needs the CLI and Windows Terminal to open a tab, but not to print' {
            $f = New-Fixture @(@{ Name = 'A' })
            $noCli = Join-Path $f.Root 'no-such-claude'

            { Open-Test $f -Arguments @{ ClaudePath = $noCli; Account = 'A'; NoUsageCheck = $true } } | Should -Throw -ErrorId 'SwitchAccounts.Environment' -ExpectedMessage '*CLI not found*'
            (Open-Test $f -Arguments @{ ClaudePath = $noCli; Account = 'A'; NoUsageCheck = $true; PrintOnly = $true }).Opened | Should -BeFalse
        }

        It 'keeps hostile text inside literals: title, session name, prompt and folder' {
            $f = New-Fixture @(@{ Name = 'A' })
            $evil = Join-Path $f.Root "it's; calc"
            New-Item -ItemType Directory -Path $evil | Out-Null
            New-ClaudeJson -ConfigDir $f.Entries[0].configDir -Trusted @($evil)

            $result = Open-Test $f -Arguments @{
                Directory = $evil; RemoteControl = $true; InitialPrompt = "x'; Remove-Item -Recurse C:\; '"; PrintOnly = $true
            }

            $ast = [System.Management.Automation.Language.Parser]::ParseInput($result.Sessions[0].Script, [ref]$null, [ref]$null)
            $names = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() }
            $names | Should -Be @('Get-ChildItem', 'Where-Object', 'ForEach-Object', 'Remove-Item', 'Set-Location', $names[-1])
            $result.Sessions[0].WtArguments | Where-Object { $_ -like '*;*' } | Should -BeNullOrEmpty
        }

        It 'rejects invalid values before anything runs: <Case>' -TestCases @(
            @{ Case = 'model'; Arguments = @{ Model = 'gpt-5' } }
            @{ Case = 'effort'; Arguments = @{ Effort = 'ultra' } }
            @{ Case = 'subagent model'; Arguments = @{ SubagentModel = 'x;y' } }
            @{ Case = 'title'; Arguments = @{ Title = 'a;b' } }
            @{ Case = 'session name'; Arguments = @{ SessionName = 'bad;name'; RemoteControl = $true } }
            @{ Case = 'session name without RC'; Arguments = @{ SessionName = 'fine' } }
            @{ Case = 'prompt'; Arguments = @{ InitialPrompt = '--version' } }
            @{ Case = 'directory'; Arguments = @{ Directory = 'Z:\no\such\folder' } }
            @{ Case = 'worktree'; Arguments = @{ Worktree = 'a b' } }
        ) {
            $f = New-Fixture @(@{ Name = 'A' })
            $bad = @{ PrintOnly = $true }
            foreach ($key in $Arguments.Keys) { $bad[$key] = $Arguments[$key] }

            { Open-Test $f -Arguments $bad } | Should -Throw -ErrorId 'SwitchAccounts.InvalidArgument'
            Should -Invoke -ModuleName SwitchAccounts Start-TerminalTab -Times 0
            Get-FakeCalls -ConfigDir $f.Entries[0].configDir | Should -HaveCount 0
        }

        It 'refuses a CLI that is a batch file, because cmd.exe would re-read the prompt' -TestCases @(
            @{ Name = 'claude.cmd' }
            @{ Name = 'CLAUDE.BAT' }
        ) {
            $f = New-Fixture @(@{ Name = 'A' })
            $shim = Join-Path $f.Root $Name
            Set-Content -LiteralPath $shim -Value '@echo off'

            { Open-Test $f -Arguments @{ ClaudePath = $shim; Account = 'A'; NoUsageCheck = $true; PrintOnly = $true } } |
                Should -Throw -ErrorId 'SwitchAccounts.Environment' -ExpectedMessage '*batch file*'
            Should -Invoke -ModuleName SwitchAccounts Start-TerminalTab -Times 0
        }

        It 'refuses a bare claude that resolves to a batch file' -Skip:(-not $IsWindows) {
            $f = New-Fixture @(@{ Name = 'A' })
            $bin = Join-Path $f.Root 'bin'
            New-Item -ItemType Directory -Path $bin | Out-Null
            Set-Content -LiteralPath (Join-Path $bin 'claude.cmd') -Value '@echo off'
            $old = $env:PATH
            try {
                $env:PATH = $bin + [IO.Path]::PathSeparator + $env:PATH
                { Open-Test $f -Arguments @{ ClaudePath = 'claude'; Account = 'A'; NoUsageCheck = $true; PrintOnly = $true } } |
                    Should -Throw -ErrorId 'SwitchAccounts.Environment' -ExpectedMessage '*batch file*'
            } finally {
                $env:PATH = $old
            }
        }

        It 'says how many tabs were already open when a later one fails' {
            $script:calls = 0
            Mock -ModuleName SwitchAccounts Start-TerminalTab { if ((++$script:calls) -eq 2) { throw 'wt exploded' } }
            $f = New-Fixture @(@{ Name = 'A' })

            { Open-Test $f -Arguments @{ Count = 3 } } | Should -Throw -ErrorId 'SwitchAccounts.Environment' -ExpectedMessage '*tab 2 of 3*1 tab(s) were already opened*'
        }

        It 'cannot be given a label that reads as an option: <Case>' -TestCases @(
            @{ Case = 'session name'; Arguments = @{ SessionName = '--dangerously-skip-permissions'; RemoteControl = $true } }
            @{ Case = 'session name that eats the prompt'; Arguments = @{ SessionName = '--permission-mode'; RemoteControl = $true; InitialPrompt = 'bypassPermissions' } }
            @{ Case = 'title used as the session name'; Arguments = @{ Title = '-p'; RemoteControl = $true } }
        ) {
            $f = New-Fixture @(@{ Name = 'A' })
            $bad = @{ PrintOnly = $true }
            foreach ($key in $Arguments.Keys) { $bad[$key] = $Arguments[$key] }

            { Open-Test $f -Arguments $bad } | Should -Throw -ErrorId 'SwitchAccounts.InvalidArgument'
        }

        It 'names a Remote Control session after a folder whose name starts with a dash without starting with one' {
            $f = New-Fixture @(@{ Name = 'A' })
            $odd = Join-Path $f.Root '-odd folder'
            New-Item -ItemType Directory -Path $odd | Out-Null
            New-ClaudeJson -ConfigDir $f.Entries[0].configDir -Trusted @($odd)

            $result = Open-Test $f -Arguments @{ Directory = $odd; RemoteControl = $true; PrintOnly = $true }

            $result.RemoteControlName | Should -Be 'odd folder · A'
        }

        It 'never offers a way to skip permission checks' {
            (Get-Command Open-ClaudeSession).Parameters.Keys | Should -Not -Contain 'DangerouslySkipPermissions'
            $f = New-Fixture @(@{ Name = 'A' })

            (Open-Test $f -Arguments @{ PrintOnly = $true; Model = 'opus'; Effort = 'max'; RemoteControl = $true }).Sessions[0].Script |
                Should -Not -Match 'dangerously|skip-permissions|bypass'
        }
    }
}
