BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'SwitchAccounts.psd1') -Force

    function New-SourceConfig {
        param([string] $Path)
        foreach ($d in 'rules', 'skills', 'agents', 'commands', 'projects') {
            New-Item -ItemType Directory -Path (Join-Path $Path $d) -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $Path $d 'marker.txt') -Value "source-$d"
        }
        Set-Content -LiteralPath (Join-Path $Path 'CLAUDE.md') -Value '# global rules'
        Set-Content -LiteralPath (Join-Path $Path '.credentials.json') -Value '{"synthetic":"source-secret"}'
        Set-Content -LiteralPath (Join-Path $Path 'settings.json') -Value '{}'
        $Path
    }

    function New-TargetConfig {
        param([string] $Path)
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $Path '.credentials.json') -Value '{"synthetic":"target-secret"}'
        Set-Content -LiteralPath (Join-Path $Path '.claude.json') -Value '{"synthetic":true}'
        $Path
    }

    function Get-TreeHash {
        param([string] $Path)
        Get-ChildItem -LiteralPath $Path -Recurse -File -Force |
            Where-Object { -not ($_.FullName -match '[\\/](rules|skills|agents|commands)[\\/]') } |
            Sort-Object FullName |
            ForEach-Object { "$($_.FullName)=$((Get-FileHash -LiteralPath $_.FullName).Hash)" }
    }
}

Describe 'Initialize-SecondaryAccount' {
    BeforeEach {
        $source = New-SourceConfig -Path (Join-Path $TestDrive "src-$([guid]::NewGuid())")
        $target = New-TargetConfig -Path (Join-Path $TestDrive "dst-$([guid]::NewGuid())")
    }

    It 'links rules, skills and agents by default' {
        $result = Initialize-SecondaryAccount -SourceConfigDir $source -TargetConfigDir $target

        foreach ($item in 'rules', 'skills', 'agents') {
            ($result | Where-Object Item -EQ $item).Action | Should -Be 'Linked'
            Get-Content -LiteralPath (Join-Path $target $item 'marker.txt') | Should -Be "source-$item"
            (Get-Item -LiteralPath (Join-Path $target $item)).LinkTarget | Should -Not -BeNullOrEmpty
        }
        Test-Path -LiteralPath (Join-Path $target 'commands') | Should -BeFalse
    }

    It 'writes a CLAUDE.md that imports the source one instead of copying it' {
        Initialize-SecondaryAccount -SourceConfigDir $source -TargetConfigDir $target | Out-Null

        $content = Get-Content -LiteralPath (Join-Path $target 'CLAUDE.md') -Raw
        $content | Should -Match ([regex]::Escape('@' + (Join-Path (Resolve-Path $source).Path 'CLAUDE.md').Replace('\', '/')))
        $content | Should -Not -Match 'global rules'
    }

    It 'escapes spaces in the imported path' {
        $spaced = New-SourceConfig -Path (Join-Path $TestDrive "my config $([guid]::NewGuid())")

        Initialize-SecondaryAccount -SourceConfigDir $spaced -TargetConfigDir $target | Out-Null

        $line = (Get-Content -LiteralPath (Join-Path $target 'CLAUDE.md'))[1]
        $line | Should -BeLike '@*my\ config\ *'
        $line | Should -Match 'CLAUDE\.md$'
    }

    It 'never touches credentials, account state or settings' {
        $before = Get-TreeHash -Path $target
        $sourceBefore = Get-TreeHash -Path $source

        Initialize-SecondaryAccount -SourceConfigDir $source -TargetConfigDir $target -Items rules, skills, agents, commands | Out-Null

        $after = Get-TreeHash -Path $target | Where-Object { $_ -notmatch 'CLAUDE\.md=' }
        $after | Should -Be $before
        Get-TreeHash -Path $source | Should -Be $sourceBefore
        Get-Content -LiteralPath (Join-Path $target '.credentials.json') | Should -Match 'target-secret'
    }

    It 'refuses items outside the allow-list: <Item>' -TestCases @(
        @{ Item = '.credentials.json' }, @{ Item = 'projects' }, @{ Item = 'settings.json' },
        @{ Item = '../rules' }, @{ Item = 'rules/../projects' }, @{ Item = '' }
    ) {
        { Initialize-SecondaryAccount -SourceConfigDir $source -TargetConfigDir $target -Items $Item } |
            Should -Throw
        Test-Path -LiteralPath (Join-Path $target 'projects') | Should -BeFalse
    }

    It 'is idempotent' {
        Initialize-SecondaryAccount -SourceConfigDir $source -TargetConfigDir $target | Out-Null

        $second = Initialize-SecondaryAccount -SourceConfigDir $source -TargetConfigDir $target

        @($second | Where-Object Action -NE 'AlreadyLinked') | Should -HaveCount 0
    }

    It 'reports a conflict and leaves an existing real folder alone' {
        New-Item -ItemType Directory -Path (Join-Path $target 'skills') | Out-Null
        Set-Content -LiteralPath (Join-Path $target 'skills' 'mine.txt') -Value 'keep me'

        $result = Initialize-SecondaryAccount -SourceConfigDir $source -TargetConfigDir $target -ErrorAction SilentlyContinue

        ($result | Where-Object Item -EQ 'skills').Action | Should -Be 'Conflict'
        Get-Content -LiteralPath (Join-Path $target 'skills' 'mine.txt') | Should -Be 'keep me'
        ($result | Where-Object Item -EQ 'rules').Action | Should -Be 'Linked'
    }

    It 'writes an error when there is a conflict' {
        Set-Content -LiteralPath (Join-Path $target 'CLAUDE.md') -Value 'my own rules'

        { Initialize-SecondaryAccount -SourceConfigDir $source -TargetConfigDir $target -ErrorAction Stop } |
            Should -Throw '*CLAUDE.md*'
        Get-Content -LiteralPath (Join-Path $target 'CLAUDE.md') | Should -Be 'my own rules'
    }

    It 'reports a missing source item without creating anything' {
        Remove-Item -LiteralPath (Join-Path $source 'agents') -Recurse

        $result = Initialize-SecondaryAccount -SourceConfigDir $source -TargetConfigDir $target -ErrorAction SilentlyContinue

        ($result | Where-Object Item -EQ 'agents').Action | Should -Be 'Missing'
        Test-Path -LiteralPath (Join-Path $target 'agents') | Should -BeFalse
    }

    It 'changes nothing with -WhatIf' {
        $result = Initialize-SecondaryAccount -SourceConfigDir $source -TargetConfigDir $target -WhatIf

        @($result | Where-Object Action -NE 'WouldLink') | Should -HaveCount 0
        Test-Path -LiteralPath (Join-Path $target 'rules') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $target 'CLAUDE.md') | Should -BeFalse
    }

    It 'refuses when source and target are the same folder' {
        { Initialize-SecondaryAccount -SourceConfigDir $source -TargetConfigDir $source } | Should -Throw
    }

    It 'refuses when the target folder does not exist' {
        { Initialize-SecondaryAccount -SourceConfigDir $source -TargetConfigDir (Join-Path $TestDrive 'none') } |
            Should -Throw '*log in*'
    }
}

Describe 'Test-SecondaryAccount' {
    BeforeEach {
        $source = New-SourceConfig -Path (Join-Path $TestDrive "src-$([guid]::NewGuid())")
        $target = New-TargetConfig -Path (Join-Path $TestDrive "dst-$([guid]::NewGuid())")
    }

    It 'passes after setup' {
        Initialize-SecondaryAccount -SourceConfigDir $source -TargetConfigDir $target | Out-Null

        $check = Test-SecondaryAccount -SourceConfigDir $source -TargetConfigDir $target

        $check.Ok | Should -BeTrue
        @($check.Items | Where-Object { -not $_.Ok }) | Should -HaveCount 0
    }

    It 'fails before setup and names each missing item' {
        $check = Test-SecondaryAccount -SourceConfigDir $source -TargetConfigDir $target

        $check.Ok | Should -BeFalse
        ($check.Items | Where-Object { -not $_.Ok } | ForEach-Object Item) | Should -Contain 'skills'
        ($check.Items | Where-Object { -not $_.Ok } | ForEach-Object Item) | Should -Contain 'CLAUDE.md'
    }

    It 'fails when a link points somewhere else' {
        $elsewhere = New-Item -ItemType Directory -Path (Join-Path $TestDrive "other-$([guid]::NewGuid())")
        Initialize-SecondaryAccount -SourceConfigDir $source -TargetConfigDir $target -Items rules, agents | Out-Null
        $linkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
        New-Item -ItemType $linkType -Path (Join-Path $target 'skills') -Target $elsewhere.FullName | Out-Null

        $check = Test-SecondaryAccount -SourceConfigDir $source -TargetConfigDir $target

        $check.Ok | Should -BeFalse
        ($check.Items | Where-Object Item -EQ 'skills').Ok | Should -BeFalse
    }
}
