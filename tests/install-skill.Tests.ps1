BeforeAll {
    $installer = Join-Path $PSScriptRoot '..' 'scripts' 'install-skill.ps1'
    $repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

    function New-ConfigDir {
        $dir = Join-Path $TestDrive "cfg-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path (Join-Path $dir 'skills') -Force | Out-Null
        $dir
    }
}

Describe 'scripts/install-skill.ps1' {
    It 'installs the skill, the wrapper and the module' {
        $dir = New-ConfigDir

        & $installer -ConfigDir $dir | Out-Null

        $target = Join-Path $dir 'skills' 'switch-account'
        Get-Content -LiteralPath (Join-Path $target 'SKILL.md') -Raw | Should -Be (Get-Content -LiteralPath (Join-Path $repo 'skills' 'switch-account' 'SKILL.md') -Raw)
        Test-Path -LiteralPath (Join-Path $target 'scripts' 'open-session.ps1') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $target 'scripts' 'usage-report.ps1') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $target 'src' 'SwitchAccounts.psd1') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $target 'src' 'Public' 'Open-ClaudeSession.ps1') | Should -BeTrue
    }

    It 'installs the fleet-director skill with its routing table and the Gemini script' {
        $dir = New-ConfigDir

        & $installer -ConfigDir $dir | Out-Null

        $target = Join-Path $dir 'skills' 'fleet-director'
        Get-Content -LiteralPath (Join-Path $target 'SKILL.md') -Raw | Should -Be (Get-Content -LiteralPath (Join-Path $repo 'skills' 'fleet-director' 'SKILL.md') -Raw)
        $table = Get-Content -LiteralPath (Join-Path $target 'director.default.json') -Raw | ConvertFrom-Json
        $table.schema | Should -Be 1
        Test-Path -LiteralPath (Join-Path $target 'scripts' 'ask-gemini.ps1') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $target 'LIMITS.md') | Should -BeTrue
    }

    It 'leaves a working copy: the installed wrapper runs against the installed module' {
        $dir = New-ConfigDir
        & $installer -ConfigDir $dir | Out-Null
        $path = Join-Path $TestDrive "inst-$([guid]::NewGuid())" 'accounts.json'

        $previous = $env:SWITCH_ACCOUNTS_ALLOW_OVERRIDES
        try {
            $env:SWITCH_ACCOUNTS_ALLOW_OVERRIDES = '1'
            $out = & (Get-Process -Id $PID).Path -NoProfile -File (Join-Path $dir 'skills' 'switch-account' 'scripts' 'open-session.ps1') -ShowConfig -ConfigPath $path
            $exit = $LASTEXITCODE
        } finally {
            if ($null -eq $previous) { Remove-Item Env:SWITCH_ACCOUNTS_ALLOW_OVERRIDES -ErrorAction SilentlyContinue } else { $env:SWITCH_ACCOUNTS_ALLOW_OVERRIDES = $previous }
        }

        $exit | Should -Be 0
        ($out -join "`n") | Should -BeLike '*created with defaults*'
    }

    It 'saves the previous skill under backups before replacing it' {
        $dir = New-ConfigDir
        $old = Join-Path $dir 'skills' 'switch-account'
        New-Item -ItemType Directory -Path $old | Out-Null
        Set-Content -LiteralPath (Join-Path $old 'SKILL.md') -Value 'old skill'

        & $installer -ConfigDir $dir | Out-Null

        $backup = @(Get-ChildItem -LiteralPath (Join-Path $dir 'backups') -Directory -Filter 'switch-account-*')
        $backup | Should -HaveCount 1
        Get-Content -LiteralPath (Join-Path $backup[0].FullName 'SKILL.md') | Should -Be 'old skill'
        Get-Content -LiteralPath (Join-Path $old 'SKILL.md') -Raw | Should -Not -BeLike 'old skill*'
    }

    It 'keeps every earlier version when run several times in a row' {
        $dir = New-ConfigDir
        & $installer -ConfigDir $dir | Out-Null
        & $installer -ConfigDir $dir | Out-Null
        & $installer -ConfigDir $dir | Out-Null

        @(Get-ChildItem -LiteralPath (Join-Path $dir 'backups') -Directory -Filter 'switch-account-*') | Should -HaveCount 2
        @(Get-ChildItem -LiteralPath (Join-Path $dir 'backups') -Directory -Filter 'fleet-director-*') | Should -HaveCount 2
    }

    It 'can be run again, and -NoBackup keeps no copy' {
        $dir = New-ConfigDir
        & $installer -ConfigDir $dir | Out-Null

        & $installer -ConfigDir $dir -NoBackup | Out-Null

        Test-Path -LiteralPath (Join-Path $dir 'backups') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $dir 'skills' 'switch-account' 'SKILL.md') | Should -BeTrue
    }

    It 'changes nothing with -WhatIf' {
        $dir = New-ConfigDir

        & $installer -ConfigDir $dir -WhatIf | Out-Null

        Test-Path -LiteralPath (Join-Path $dir 'skills' 'switch-account') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $dir 'skills' 'fleet-director') | Should -BeFalse
    }

    It 'leaves no staging folder behind' {
        $dir = New-ConfigDir

        & $installer -ConfigDir $dir | Out-Null

        @(Get-ChildItem -LiteralPath (Join-Path $dir 'skills') -Force).Name | Sort-Object | Should -Be @('fleet-director', 'switch-account')
    }

    It 'fails when the config dir does not exist' {
        { & $installer -ConfigDir (Join-Path $TestDrive 'missing') } | Should -Throw '*Config dir not found*'
    }

    It 'reaches the second account through a linked skills folder' -Skip:(-not $IsWindows) {
        $main = New-ConfigDir
        $second = Join-Path $TestDrive "second-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path $second | Out-Null
        New-Item -ItemType Junction -Path (Join-Path $second 'skills') -Target (Join-Path $main 'skills') | Out-Null

        & $installer -ConfigDir $main | Out-Null

        Test-Path -LiteralPath (Join-Path $second 'skills' 'switch-account' 'SKILL.md') | Should -BeTrue
    }

    It 'ships a skill that names the script, the triggers and the exit codes' {
        $skill = Get-Content -LiteralPath (Join-Path $repo 'skills' 'switch-account' 'SKILL.md') -Raw

        $skill | Should -Match '(?m)^name: switch-account$'
        foreach ($trigger in '/switch-account', 'cambiar de cuenta', 'abre otra sesión', 'abre con /rc', 'me quedé sin tokens') {
            $skill | Should -Match ([regex]::Escape($trigger))
        }
        $skill | Should -Match 'scripts/open-session.ps1'
        $skill | Should -Match 'AskUserQuestion'
        $skill | Should -Match 'auto \(Recomendado\)'
        $skill | Should -Match 'Never pass `--dangerously-skip-permissions`'
    }

    It 'ships a director skill that keeps the guardrails' {
        $skill = Get-Content -LiteralPath (Join-Path $repo 'skills' 'fleet-director' 'SKILL.md') -Raw
        $table = Get-Content -LiteralPath (Join-Path $repo 'skills' 'fleet-director' 'director.default.json') -Raw | ConvertFrom-Json

        $skill | Should -Match '(?m)^name: fleet-director$'
        $skill | Should -Match 'AskUserQuestion'
        $skill | Should -Match 'Never rotate Claude accounts'
        $skill | Should -Match 'Never pass `--dangerously-skip-permissions`'
        $skill | Should -Match 'fleet_status'
        $skill | Should -Match 'scripts/ask-gemini.ps1'
        $skill | Should -Match 'LIMITS.md'
        $limits = Get-Content -LiteralPath (Join-Path $repo 'skills' 'fleet-director' 'LIMITS.md') -Raw
        foreach ($section in '## The hub', '## Claude workers', '## ChatGPT', '## Gemini', '## What no executor does', '## A brief that gets finished') {
            $limits | Should -Match ([regex]::Escape($section))
        }
        @($table.levels.PSObject.Properties.Name) | Should -Be @('high', 'medium', 'low')
        $table.executors.chatgpt.canWrite | Should -BeFalse
        $table.executors.gemini.canWrite | Should -BeFalse
        $table.atCap.never | Should -Match 'Never move a task to another Claude account'
        $skill | Should -Match 'every other option with `"provider": "anthropic"` is skipped too'
        $table.executors.'claude-hub'.provider | Should -Be 'anthropic'
        $table.executors.'claude-worker'.provider | Should -Be 'anthropic'
        $table.executors.chatgpt.provider | Should -Be 'openai'
        $table.executors.gemini.provider | Should -Be 'google'
        foreach ($level in $table.levels.PSObject.Properties.Value) {
            foreach ($option in $level.options) {
                $table.executors.PSObject.Properties.Name | Should -Contain $option.executor
                if ($option.PSObject.Properties.Name -contains 'effort') {
                    $table.executors.($option.executor).efforts | Should -Contain $option.effort
                    # An agy id that ends in its effort carries it; no second effort beside it.
                    $option.model | Should -Not -Match '-(low|medium|high)$'
                }
            }
        }
    }
}
