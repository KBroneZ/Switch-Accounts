BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'SwitchAccounts.psd1') -Force
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    $script:projectDir = Join-Path $TestDrive 'repo' 'sub'
    New-Item -ItemType Directory -Path $script:projectDir -Force | Out-Null
}

Describe 'Get-AccountOnboardingState' {
    BeforeEach {
        $dir = Join-Path $TestDrive "acc-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path $dir | Out-Null
        $json = Join-Path $dir '.claude.json'
    }

    It 'is FirstRun without a file' {
        InModuleScope SwitchAccounts -Parameters @{ Json = $json; Dir = $script:projectDir } {
            Get-AccountOnboardingState -GlobalConfigPath $Json -WorkingDirectory $Dir | Should -Be 'FirstRun'
        }
    }

    It 'is FirstRun when onboarding is not completed' {
        New-ClaudeJson -ConfigDir $dir -Onboarded $false -Trusted @($script:projectDir)

        InModuleScope SwitchAccounts -Parameters @{ Json = $json; Dir = $script:projectDir } {
            Get-AccountOnboardingState -GlobalConfigPath $Json -WorkingDirectory $Dir | Should -Be 'FirstRun'
        }
    }

    It 'is Unknown when the file cannot be read' {
        Set-Content -LiteralPath $json -Value '{ broken'

        InModuleScope SwitchAccounts -Parameters @{ Json = $json; Dir = $script:projectDir } {
            Get-AccountOnboardingState -GlobalConfigPath $Json -WorkingDirectory $Dir | Should -Be 'Unknown'
        }
    }

    It 'is Untrusted when no folder is marked, or the folder is marked false' {
        New-ClaudeJson -ConfigDir $dir -Untrusted @($script:projectDir)

        InModuleScope SwitchAccounts -Parameters @{ Json = $json; Dir = $script:projectDir } {
            Get-AccountOnboardingState -GlobalConfigPath $Json -WorkingDirectory $Dir | Should -Be 'Untrusted'
        }
    }

    It 'is Untrusted when the file has no projects at all' {
        Set-Content -LiteralPath $json -Value '{"hasCompletedOnboarding": true}'

        InModuleScope SwitchAccounts -Parameters @{ Json = $json; Dir = $script:projectDir } {
            Get-AccountOnboardingState -GlobalConfigPath $Json -WorkingDirectory $Dir | Should -Be 'Untrusted'
        }
    }

    It 'is Ready when the folder, or a parent folder, is trusted' {
        New-ClaudeJson -ConfigDir $dir -Trusted @((Split-Path -Parent $script:projectDir))

        InModuleScope SwitchAccounts -Parameters @{ Json = $json; Dir = $script:projectDir } {
            Get-AccountOnboardingState -GlobalConfigPath $Json -WorkingDirectory $Dir | Should -Be 'Ready'
        }
    }

    It 'is Ready when the trusted key uses forward slashes and a different case' -Skip:(-not $IsWindows) {
        New-ClaudeJson -ConfigDir $dir -Trusted @(($script:projectDir -replace '\\', '/').ToLowerInvariant())

        InModuleScope SwitchAccounts -Parameters @{ Json = $json; Dir = $script:projectDir } {
            Get-AccountOnboardingState -GlobalConfigPath $Json -WorkingDirectory $Dir | Should -Be 'Ready'
        }
    }

    It 'reads a file with names that differ only in case' {
        $trusted = [ordered]@{ ($script:projectDir) = [ordered]@{ hasTrustDialogAccepted = $true } }
        $text = ([ordered]@{ hasCompletedOnboarding = $true; projects = $trusted } | ConvertTo-Json -Depth 5).TrimEnd().TrimEnd('}') + ', "x": {"Key": 1, "key": 2}}'
        Set-Content -LiteralPath $json -Value $text

        InModuleScope SwitchAccounts -Parameters @{ Json = $json; Dir = $script:projectDir } {
            Get-AccountOnboardingState -GlobalConfigPath $Json -WorkingDirectory $Dir | Should -Be 'Ready'
        }
    }

    It 'is not fooled by a sibling folder with the same prefix' {
        New-ClaudeJson -ConfigDir $dir -Trusted @("$($script:projectDir)-other")

        InModuleScope SwitchAccounts -Parameters @{ Json = $json; Dir = $script:projectDir } {
            Get-AccountOnboardingState -GlobalConfigPath $Json -WorkingDirectory $Dir | Should -Be 'Untrusted'
        }
    }
}

Describe 'Get-AccountReadiness and advice' {
    It 'is Missing when the config dir does not exist' {
        InModuleScope SwitchAccounts -Parameters @{ Dir = $script:projectDir; Missing = (Join-Path $TestDrive 'nope') } {
            $account = [pscustomobject]@{ ConfigDir = $Missing; IsDefaultConfigDir = $false }
            Get-AccountReadiness -Account $account -WorkingDirectory $Dir | Should -Be 'Missing'
        }
    }

    It 'looks for .claude.json inside a non-default config dir' {
        $dir = Join-Path $TestDrive "acc-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path $dir | Out-Null
        New-ClaudeJson -ConfigDir $dir -Trusted @($script:projectDir)

        InModuleScope SwitchAccounts -Parameters @{ Dir = $script:projectDir; Config = $dir } {
            $account = [pscustomobject]@{ ConfigDir = $Config; IsDefaultConfigDir = $false }
            Get-AccountReadiness -Account $account -WorkingDirectory $Dir | Should -Be 'Ready'
        }
    }

    It 'says what to do for each state' {
        InModuleScope SwitchAccounts {
            $second = [pscustomobject]@{ ConfigDir = 'C:\cfg\b'; IsDefaultConfigDir = $false }
            $main = [pscustomobject]@{ ConfigDir = 'C:\cfg\a'; IsDefaultConfigDir = $true }
            Get-NotReadyAdvice -Account $second -State 'FirstRun' -Directory 'D:\x' | Should -BeLike "*CLAUDE_CONFIG_DIR = 'C:\cfg\b'*claude*"
            Get-NotReadyAdvice -Account $main -State 'FirstRun' -Directory 'D:\x' | Should -Not -BeLike '*CLAUDE_CONFIG_DIR*'
            Get-NotReadyAdvice -Account $second -State 'Untrusted' -Directory 'D:\x' | Should -BeLike '*D:\x*-TrustDirectory*'
            Get-NotReadyAdvice -Account $second -State 'Missing' -Directory 'D:\x' | Should -BeLike '*does not exist*'
            Get-NotReadyAdvice -Account $second -State 'Unknown' -Directory 'D:\x' | Should -BeLike '*could not be read*'
        }
    }
}

Describe 'Set-DirectoryTrust' {
    BeforeEach {
        $dir = Join-Path $TestDrive "acc-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path $dir | Out-Null
        $json = Join-Path $dir '.claude.json'
        $document = @'
{
  "hasCompletedOnboarding": true,
  "userID": "synthetic-user",
  "bigNumber": 12345678901234567890,
  "unicode": "caf\u00e9 \u00b7 ok",
  "nested": { "list": [1, 2, { "a": null }], "Key": 1, "key": 2 },
  "projects": {
    "C:/other/place": { "hasTrustDialogAccepted": false, "allowedTools": ["x"] }
  }
}
'@
        Set-Content -LiteralPath $json -Value $document -NoNewline
    }

    It 'marks the folder and keeps every other value as it was' {
        InModuleScope SwitchAccounts -Parameters @{ Json = $json; Dir = $script:projectDir } {
            Set-DirectoryTrust -GlobalConfigPath $Json -Directory $Dir | Should -BeTrue
        }

        $text = Get-Content -LiteralPath $json -Raw
        $text | Should -Match '12345678901234567890'
        $text | Should -Match 'café · ok'
        $text | Should -Match '"Key": 1'
        $text | Should -Match '"key": 2'
        $after = $text | ConvertFrom-Json -AsHashtable
        $after['userID'] | Should -Be 'synthetic-user'
        $after['nested']['list'][2].ContainsKey('a') | Should -BeTrue
        $after['projects']['C:/other/place']['allowedTools'] | Should -Be @('x')
        $after['projects']['C:/other/place']['hasTrustDialogAccepted'] | Should -BeFalse
        InModuleScope SwitchAccounts -Parameters @{ Json = $json; Dir = $script:projectDir } {
            Get-AccountOnboardingState -GlobalConfigPath $Json -WorkingDirectory $Dir | Should -Be 'Ready'
        }
    }

    It 'keeps a backup of the file as it was' {
        $before = Get-Content -LiteralPath $json -Raw

        InModuleScope SwitchAccounts -Parameters @{ Json = $json; Dir = $script:projectDir } {
            Set-DirectoryTrust -GlobalConfigPath $Json -Directory $Dir | Out-Null
        }

        Get-Content -LiteralPath "$json.switch-backup" -Raw | Should -Be $before
    }

    It 'updates the existing key of a folder instead of adding a second one' {
        Set-Content -LiteralPath $json -Value (@{
                hasCompletedOnboarding = $true
                projects               = @{ ($script:projectDir -replace '\\', '/') = @{ hasTrustDialogAccepted = $false; keep = 1 } }
            } | ConvertTo-Json -Depth 5)

        InModuleScope SwitchAccounts -Parameters @{ Json = $json; Dir = $script:projectDir } {
            Set-DirectoryTrust -GlobalConfigPath $Json -Directory $Dir | Out-Null
        }

        $projects = (Get-Content -LiteralPath $json -Raw | ConvertFrom-Json).projects
        @($projects.PSObject.Properties).Count | Should -Be 1
        @($projects.PSObject.Properties)[0].Value.hasTrustDialogAccepted | Should -BeTrue
        @($projects.PSObject.Properties)[0].Value.keep | Should -Be 1
    }

    It 'changes nothing under -WhatIf' {
        $before = Get-FileHash -LiteralPath $json

        InModuleScope SwitchAccounts -Parameters @{ Json = $json; Dir = $script:projectDir } {
            Set-DirectoryTrust -GlobalConfigPath $Json -Directory $Dir -WhatIf | Should -BeFalse
        }

        (Get-FileHash -LiteralPath $json).Hash | Should -Be $before.Hash
        Test-Path -LiteralPath "$json.switch-backup" | Should -BeFalse
    }

    It 'refuses the parents of the home folder, system folders and configured config dirs' {
        $configured = Join-Path $TestDrive 'elsewhere' 'acc-b'
        New-Item -ItemType Directory -Path $configured -Force | Out-Null
        $broad = @((Split-Path -Parent $HOME), (Join-Path $configured 'sub')) | Where-Object { $_ }
        if ($IsWindows) { $broad += $env:windir }
        foreach ($folder in $broad) {
            InModuleScope SwitchAccounts -Parameters @{ Json = $json; Dir = $folder; Protected = @($configured) } {
                { Set-DirectoryTrust -GlobalConfigPath $Json -Directory $Dir -ProtectedPaths $Protected } | Should -Throw -ErrorId 'SwitchAccounts.InvalidArgument'
            }
        }
    }

    It 'accepts a project folder next to a protected one' {
        $configured = Join-Path $TestDrive 'elsewhere2' 'acc-b'
        InModuleScope SwitchAccounts -Parameters @{ Json = $json; Dir = $script:projectDir; Protected = @($configured) } {
            Set-DirectoryTrust -GlobalConfigPath $Json -Directory $Dir -ProtectedPaths $Protected | Should -BeTrue
        }
    }

    It 'survives a projects key that is not a path' {
        Set-Content -LiteralPath $json -Value '{"hasCompletedOnboarding": true, "projects": {"": {"x": 1}}}'

        InModuleScope SwitchAccounts -Parameters @{ Json = $json; Dir = $script:projectDir } {
            Set-DirectoryTrust -GlobalConfigPath $Json -Directory $Dir | Should -BeTrue
        }
    }

    It 'refuses a drive root, the home folder and config dirs' {
        $second = Join-Path $HOME '.claude-account2'
        $broad = @([IO.Path]::GetPathRoot($script:projectDir), $HOME, (Join-Path $HOME '.claude'), (Join-Path $HOME '.claude' 'skills'), $second)
        foreach ($folder in $broad) {
            InModuleScope SwitchAccounts -Parameters @{ Json = $json; Dir = $folder; Protected = @($second) } {
                { Set-DirectoryTrust -GlobalConfigPath $Json -Directory $Dir -ProtectedPaths $Protected } | Should -Throw -ErrorId 'SwitchAccounts.InvalidArgument'
            }
        }
    }

    It 'does not mistake a folder that merely starts like a config dir for one' {
        $sibling = Join-Path $HOME '.claude-projects' 'app'
        InModuleScope SwitchAccounts -Parameters @{ Dir = $sibling } {
            Test-BroadTrustTarget -Path $Dir -ProtectedPaths @((Join-Path $HOME '.claude-account2')) | Should -BeFalse
        }
    }

    It 'refuses an account that has not finished its first start' {
        Set-Content -LiteralPath $json -Value '{"hasCompletedOnboarding": false}'

        InModuleScope SwitchAccounts -Parameters @{ Json = $json; Dir = $script:projectDir } {
            { Set-DirectoryTrust -GlobalConfigPath $Json -Directory $Dir } | Should -Throw -ErrorId 'SwitchAccounts.NotReady'
        }
        InModuleScope SwitchAccounts -Parameters @{ Missing = (Join-Path $TestDrive 'missing.json'); Dir = $script:projectDir } {
            { Set-DirectoryTrust -GlobalConfigPath $Missing -Directory $Dir } | Should -Throw -ErrorId 'SwitchAccounts.NotReady'
        }
    }
}
