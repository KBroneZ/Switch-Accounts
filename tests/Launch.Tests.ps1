BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'SwitchAccounts.psd1') -Force
}

Describe 'launch values' {
    It 'quotes any text as one PowerShell literal that reads back unchanged: <Case>' -TestCases @(
        @{ Case = 'plain'; Text = 'hello world' }
        @{ Case = 'ASCII quote'; Text = "it's" }
        @{ Case = 'typographic quotes'; Text = "a $([char]0x2018)b$([char]0x2019) $([char]0x201A)c$([char]0x201B)" }
        @{ Case = 'injection try'; Text = "x'; Remove-Item C:\important -Recurse; '" }
        @{ Case = 'typographic injection'; Text = "x$([char]0x2019); calc; $([char]0x2018)" }
        @{ Case = 'dollar and backtick'; Text = 'a $env:PATH `n $(calc)' }
        @{ Case = 'newline'; Text = "line1`nline2" }
    ) {
        $literal = InModuleScope SwitchAccounts -Parameters @{ Text = $Text } { ConvertTo-PsLiteral $Text }

        [scriptblock]::Create($literal).Invoke()[0] | Should -BeExactly $Text
    }

    It 'accepts models: <Value>' -TestCases @(
        @{ Value = 'opus'; Expected = 'opus' }
        @{ Value = ' Sonnet '; Expected = 'sonnet' }
        @{ Value = 'haiku'; Expected = 'haiku' }
        @{ Value = 'fable'; Expected = 'fable' }
        @{ Value = 'opus[1m]'; Expected = 'opus[1m]' }
        @{ Value = 'claude-opus-5-5'; Expected = 'claude-opus-5-5' }
        @{ Value = ''; Expected = $null }
    ) {
        InModuleScope SwitchAccounts -Parameters @{ Value = $Value; Expected = $Expected } {
            ConvertTo-LaunchModel $Value 'Model' | Should -Be $Expected
        }
    }

    It 'refuses the model <Value>' -TestCases @(
        @{ Value = 'gpt-4' }
        @{ Value = 'opus; calc' }
        @{ Value = "haiku'" }
        @{ Value = 'claude-' }
        @{ Value = '--help' }
        @{ Value = 'opus extra' }
    ) {
        InModuleScope SwitchAccounts -Parameters @{ Value = $Value } {
            { ConvertTo-LaunchModel $Value 'Model' } | Should -Throw -ErrorId 'SwitchAccounts.InvalidArgument'
        }
    }

    It 'accepts every effort and refuses others' {
        InModuleScope SwitchAccounts {
            foreach ($e in 'low', 'medium', 'high', 'xhigh', 'max') { ConvertTo-LaunchEffort $e | Should -Be $e }
            ConvertTo-LaunchEffort 'HIGH' | Should -Be 'high'
            ConvertTo-LaunchEffort '' | Should -BeNullOrEmpty
            { ConvertTo-LaunchEffort 'extreme' } | Should -Throw -ErrorId 'SwitchAccounts.InvalidArgument'
            { ConvertTo-LaunchEffort 'high; calc' } | Should -Throw -ErrorId 'SwitchAccounts.InvalidArgument'
        }
    }

    It 'refuses labels with ; quotes, control characters or too many characters: <Case>' -TestCases @(
        @{ Case = 'semicolon'; Value = 'a; b' }
        @{ Case = 'quote'; Value = "it's" }
        @{ Case = 'newline'; Value = "a`nb" }
        @{ Case = 'dollar'; Value = 'a $b' }
        @{ Case = 'too long'; Value = ('x' * 81) }
    ) {
        InModuleScope SwitchAccounts -Parameters @{ Value = $Value } {
            { ConvertTo-SessionLabel $Value 'Title' } | Should -Throw -ErrorId 'SwitchAccounts.InvalidArgument'
        }
    }

    It 'accepts ordinary labels, also with accents' {
        InModuleScope SwitchAccounts {
            ConvertTo-SessionLabel 'Revisión #3 (B)' 'Title' | Should -Be 'Revisión #3 (B)'
            ConvertTo-SessionLabel '' 'Title' | Should -BeNullOrEmpty
        }
    }

    It 'checks the first prompt: <Case>' -TestCases @(
        @{ Case = 'leading dash'; Value = '--model opus'; Fails = $true }
        @{ Case = 'leading dash after spaces'; Value = '  -x'; Fails = $true }
        @{ Case = 'control character'; Value = "a$([char]7)b"; Fails = $true }
        @{ Case = 'too long'; Value = ('x' * 2001); Fails = $true }
        @{ Case = 'plain'; Value = 'Fix the login test'; Fails = $false }
        @{ Case = 'multiline'; Value = "Do this`nthen that`twith tab"; Fails = $false }
    ) {
        InModuleScope SwitchAccounts -Parameters @{ Value = $Value; Fails = $Fails } {
            if ($Fails) { { Assert-InitialPrompt $Value } | Should -Throw -ErrorId 'SwitchAccounts.InvalidArgument' }
            else { Assert-InitialPrompt $Value | Should -Be $Value }
        }
    }

    It 'checks branch names: <Value>' -TestCases @(
        @{ Value = 'feat/login'; Ok = $true }
        @{ Value = 'fix-1.2'; Ok = $true }
        @{ Value = '-x'; Ok = $false }
        @{ Value = 'a..b'; Ok = $false }
        @{ Value = 'a b'; Ok = $false }
        @{ Value = 'a;b'; Ok = $false }
        @{ Value = 'a//b'; Ok = $false }
        @{ Value = 'x.lock'; Ok = $false }
        @{ Value = 'ends/'; Ok = $false }
        @{ Value = 'ends.'; Ok = $false }
        @{ Value = 'a@{b'; Ok = $false }
    ) {
        InModuleScope SwitchAccounts -Parameters @{ Value = $Value; Ok = $Ok } {
            if ($Ok) { Assert-BranchName $Value | Should -Be $Value }
            else { { Assert-BranchName $Value } | Should -Throw -ErrorId 'SwitchAccounts.InvalidArgument' }
        }
    }
}

Describe 'New-LaunchCommand' {
    BeforeAll {
        function Get-Launch {
            param([hashtable] $Override = @{})
            $arguments = @{
                AccountName = 'B'; ConfigDir = 'C:\cfg\b'; ClaudePath = 'C:\bin\claude.exe'; WorkingDirectory = 'C:\work'
                Title = 'Claude B'; RemoteControlName = $null; Model = $null; Effort = $null; SubagentModel = $null; InitialPrompt = $null
            }
            foreach ($key in $Override.Keys) { $arguments[$key] = $Override[$key] }
            InModuleScope SwitchAccounts -Parameters @{ Arguments = $arguments } { New-LaunchCommand @Arguments }
        }
        function Get-LastCommand {
            # The CLI invocation: last statement of the script, parsed (never run).
            param([string] $Script)
            $ast = [System.Management.Automation.Language.Parser]::ParseInput($Script, [ref]$null, [ref]$null)
            $ast.EndBlock.Statements[-1].PipelineElements[0]
        }
    }

    It 'sets the account dir and cleans inherited variables first' {
        $launch = Get-Launch

        $lines = $launch.Script -split "`n"
        $lines[0] | Should -BeLike '*Get-ChildItem Env:*'
        $lines[0] | Should -BeLike '*CLAUDE_\w**'
        $lines[1] | Should -Be "`$env:CLAUDE_CONFIG_DIR = 'C:\cfg\b'"
        $launch.Script | Should -Match "Set-Location -LiteralPath 'C:\\work'"
    }

    It 'removes CLAUDE_CONFIG_DIR for the default account dir' {
        $launch = Get-Launch @{ ConfigDir = $null }

        $launch.Script | Should -Match 'Remove-Item Env:CLAUDE_CONFIG_DIR'
        $launch.Script | Should -Not -Match '\$env:CLAUDE_CONFIG_DIR ='
    }

    It 'adds model, effort, subagent model and a named Remote Control only when asked' {
        $plain = Get-Launch
        $full = Get-Launch @{ Model = 'sonnet'; Effort = 'high'; SubagentModel = 'haiku'; RemoteControlName = 'my name' }

        $plain.Script | Should -Not -Match '--model|--effort|--remote-control|SUBAGENT'
        $full.Script | Should -Match "CLAUDE_CODE_SUBAGENT_MODEL = 'haiku'"
        (Get-LastCommand $full.Script).Extent.Text | Should -Be "& 'C:\bin\claude.exe' --remote-control 'my name' --model 'sonnet' --effort 'high'"
    }

    It 'passes the first prompt as the last, quoted argument' {
        $launch = Get-Launch @{ InitialPrompt = "say 'hi'" }

        (Get-LastCommand $launch.Script).Extent.Text | Should -Be "& 'C:\bin\claude.exe' 'say ''hi'''"
    }

    It 'keeps an injection attempt in the prompt as plain text' {
        $evil = "x'; Remove-Item C:\important -Recurse; '"
        $launch = Get-Launch @{ InitialPrompt = $evil }

        $ast = [System.Management.Automation.Language.Parser]::ParseInput($launch.Script, [ref]$null, [ref]$null)
        $commands = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
        # Only the fixed commands of the script exist; nothing comes from the prompt.
        @($commands | ForEach-Object { $_.GetCommandName() }) |
            Should -Be @('Get-ChildItem', 'Where-Object', 'ForEach-Object', 'Remove-Item', 'Set-Location', 'C:\bin\claude.exe')
        $last = Get-LastCommand $launch.Script
        $last.CommandElements.Count | Should -Be 2
        $last.CommandElements[1].Value | Should -BeExactly $evil
    }

    It 'never carries a flag that skips permission checks' {
        $launch = Get-Launch @{ Model = 'opus'; Effort = 'max'; RemoteControlName = 'x'; InitialPrompt = 'go' }

        $launch.Script | Should -Not -Match 'dangerously|skip-permissions|bypassPermissions'
    }

    It 'ships the script encoded, with a title wt cannot split' {
        $launch = Get-Launch @{ Title = 'Claude B' }

        $launch.WtArguments[0..4] | Should -Be @('-w', '0', 'new-tab', '--title', 'Claude B')
        $launch.WtArguments | Should -Contain '--suppressApplicationTitle'
        $encoded = $launch.WtArguments[-1]
        [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encoded)) | Should -Be $launch.Script
        $launch.WtArguments[-3..-2] | Should -Be @('-NoExit', '-EncodedCommand')
        ($launch.WtArguments | Where-Object { $_ -like '*;*' }) | Should -BeNullOrEmpty
    }

    It 'drops inherited session variables but keeps those the user stored' {
        InModuleScope SwitchAccounts {
            $names = 'CLAUDECODE', 'CLAUDE_CODE_ENTRYPOINT', 'ANTHROPIC_API_KEY', 'MCP_TOKEN', 'OTEL_X', 'PATH', 'HOME', 'MY_VAR', 'CLAUDE_CODE_SUBAGENT_MODEL'
            $stored = { param($n) $n -eq 'ANTHROPIC_API_KEY' }

            $drop = Get-InheritedSessionVariable -Names $names -IsPersistent $stored

            $drop | Should -Be @('CLAUDE_CODE_ENTRYPOINT', 'CLAUDE_CODE_SUBAGENT_MODEL', 'CLAUDECODE', 'MCP_TOKEN', 'OTEL_X')
        }
    }

    It 'runs the cleaning line without touching variables outside the pattern' {
        $launch = Get-Launch
        $env:SWITCH_TEST_KEEP = 'keep'
        $env:CLAUDE_CODE_SWITCH_TEST = 'drop'
        try {
            $clean = ($launch.Script -split "`n")[0]
            & ([scriptblock]::Create($clean))

            $env:SWITCH_TEST_KEEP | Should -Be 'keep'
            $env:CLAUDE_CODE_SWITCH_TEST | Should -BeNullOrEmpty
        } finally {
            Remove-Item Env:SWITCH_TEST_KEEP, Env:CLAUDE_CODE_SWITCH_TEST -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Start-TerminalTab' {
    BeforeAll {
        $pwshPath = (Get-Process -Id $PID).Path
    }

    It 'returns when wt hands the tab over and exits 0' {
        InModuleScope SwitchAccounts -Parameters @{ Wt = $pwshPath } {
            { Start-TerminalTab -WtPath $Wt -Arguments @('-NoProfile', '-Command', 'exit 0') } | Should -Not -Throw
        }
    }

    It 'fails when wt exits with an error' {
        InModuleScope SwitchAccounts -Parameters @{ Wt = $pwshPath } {
            { Start-TerminalTab -WtPath $Wt -Arguments @('-NoProfile', '-Command', 'exit 3') } | Should -Throw '*exited with code 3*'
        }
    }
}

Describe 'Find-ClaudeCli' {
    It 'returns the claude found on PATH' {
        $dir = Join-Path $TestDrive "bin-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path $dir | Out-Null
        $name = if ($IsWindows) { 'claude.exe' } else { 'claude' }
        Copy-Item -LiteralPath (Get-Process -Id $PID).Path -Destination (Join-Path $dir $name)
        if (-not $IsWindows) { chmod +x (Join-Path $dir $name) }
        $oldPath = $env:PATH
        try {
            $env:PATH = $dir + [IO.Path]::PathSeparator + $env:PATH
            InModuleScope SwitchAccounts { Find-ClaudeCli } | Should -Be (Join-Path $dir $name)
        } finally {
            $env:PATH = $oldPath
        }
    }

    It 'picks the newest desktop-app binary when claude is not on PATH' -Skip:(-not $IsWindows) {
        $appData = Join-Path $TestDrive "appdata-$([guid]::NewGuid())"
        foreach ($version in '2.1.9', '2.1.10', '2.0.99') {
            $folder = Join-Path $appData 'Claude' 'claude-code' $version
            New-Item -ItemType Directory -Path $folder -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $folder 'claude.exe') -Value 'x'
        }
        $oldPath = $env:PATH; $oldAppData = $env:APPDATA; $oldLocal = $env:LOCALAPPDATA
        try {
            $env:PATH = Join-Path $TestDrive 'empty'
            $env:APPDATA = $appData
            $env:LOCALAPPDATA = Join-Path $TestDrive 'no-local'
            InModuleScope SwitchAccounts { Find-ClaudeCli } | Should -Be (Join-Path $appData 'Claude' 'claude-code' '2.1.10' 'claude.exe')
        } finally {
            $env:PATH = $oldPath; $env:APPDATA = $oldAppData; $env:LOCALAPPDATA = $oldLocal
        }
    }
}
