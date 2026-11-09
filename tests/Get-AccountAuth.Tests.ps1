BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'SwitchAccounts.psd1') -Force
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    $fake = Get-FakeClaudePath
}

Describe 'Get-AccountAuth' {
    BeforeEach {
        $dir = Join-Path $TestDrive "a-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path $dir | Out-Null
    }

    It 'reads login, method, plan, tier and expiry, and nothing else' {
        Set-Content -LiteralPath (Join-Path $dir 'fake-auth.json') -Value '{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"max","planTier":"max_5x","loginExpiresAt":"2030-02-03T04:05:06.000Z","email":"someone@example.invalid","orgId":"synthetic-org"}'

        $auth = Get-AccountAuth -ConfigDir $dir -ClaudePath $fake

        $auth.Status | Should -Be 'LoggedIn'
        $auth.Method | Should -Be 'claude.ai'
        $auth.Plan | Should -Be 'max'
        $auth.Tier | Should -Be 'max_5x'
        $auth.ExpiresAt.UtcDateTime | Should -Be ([datetime]::new(2030, 2, 3, 4, 5, 6, [DateTimeKind]::Utc))
        ($auth | ConvertTo-Json) | Should -Not -Match 'example.invalid|synthetic-org'
        (Get-FakeCalls -ConfigDir $dir)[0].args | Should -Be @('auth', 'status', '--json')
    }

    It 'is LoggedOut when the CLI says so, whatever its exit code' {
        Set-Content -LiteralPath (Join-Path $dir 'fake-auth.json') -Value '{"loggedIn":false,"authMethod":"none","loginExpiresAt":null}'
        Set-Content -LiteralPath (Join-Path $dir 'fake-auth-exit-code.txt') -Value 1 -NoNewline

        $auth = Get-AccountAuth -ConfigDir $dir -ClaudePath $fake

        $auth.Status | Should -Be 'LoggedOut'
        $auth.ExpiresAt | Should -BeNullOrEmpty
        $auth.Reason | Should -BeLike 'not logged in*'
    }

    It 'is Unknown, not LoggedOut, when the answer is not the expected JSON' -TestCases @(
        @{ Body = 'error: unknown option --json' }
        @{ Body = '{"authMethod":"none"}' }
        @{ Body = '{"loggedIn":"yes"}' }
    ) {
        Set-Content -LiteralPath (Join-Path $dir 'fake-auth.json') -Value $Body

        (Get-AccountAuth -ConfigDir $dir -ClaudePath $fake).Status | Should -Be 'Unknown'
    }

    It 'drops values that are not short plain words' {
        Set-Content -LiteralPath (Join-Path $dir 'fake-auth.json') -Value '{"loggedIn":true,"subscriptionType":"max; rm -rf /","planTier":"max_5x"}'

        $auth = Get-AccountAuth -ConfigDir $dir -ClaudePath $fake

        $auth.Plan | Should -BeNullOrEmpty
        $auth.Tier | Should -Be 'max_5x'
    }

    It 'is Unknown when the config dir does not exist' {
        (Get-AccountAuth -ConfigDir (Join-Path $dir 'missing') -ClaudePath $fake).Status | Should -Be 'Unknown'
    }
}

Describe 'Get-AccountAuth expiry with an offset' {
    It 'keeps the instant of an expiry written with a UTC offset' {
        $dir = Join-Path $TestDrive "o-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path $dir | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'fake-auth.json') -Value '{"loggedIn":true,"loginExpiresAt":"2030-02-03T06:05:06+02:00"}'

        $auth = Get-AccountAuth -ConfigDir $dir -ClaudePath (Get-FakeClaudePath)

        $auth.ExpiresAt.UtcDateTime | Should -Be ([datetime]::new(2030, 2, 3, 4, 5, 6, [DateTimeKind]::Utc))
    }
}
