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
        Test-Path -LiteralPath (Join-Path $target 'src' 'SwitchAccounts.psd1') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $target 'src' 'Public' 'Open-ClaudeSession.ps1') | Should -BeTrue
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

        @(Get-ChildItem -LiteralPath (Join-Path $dir 'backups') -Directory) | Should -HaveCount 2
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
    }

    It 'leaves no staging folder behind' {
        $dir = New-ConfigDir

        & $installer -ConfigDir $dir | Out-Null

        @(Get-ChildItem -LiteralPath (Join-Path $dir 'skills') -Force).Name | Should -Be @('switch-account')
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
}
