BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'SwitchAccounts.psd1') -Force
    function Write-Config {
        param([string] $Path, $Document)
        New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
        Set-Content -LiteralPath $Path -Value ($Document | ConvertTo-Json -Depth 6)
        $Path
    }
}

Describe 'Get-SwitchAccountConfig' {
    BeforeEach {
        $path = Join-Path $TestDrive "cfg-$([guid]::NewGuid())" 'accounts.json'
    }

    It 'creates the file with two default accounts when it does not exist' {
        $config = Get-SwitchAccountConfig -ConfigPath $path

        $config.Created | Should -BeTrue
        Test-Path -LiteralPath $path | Should -BeTrue
        $config.Accounts.Name | Should -Be @('A', 'B')
        $config.Accounts[0].IsDefaultConfigDir | Should -BeTrue
        $config.Accounts[1].IsDefaultConfigDir | Should -BeFalse
        $config.Accounts[0].MaxFiveHourPercent | Should -Be 80
        $config.Accounts[0].RemoteControl | Should -BeTrue
        $config.Accounts[0].MaxWeeklyPercent | Should -BeNullOrEmpty
        $config.Accounts[0].ConfigDir | Should -Be (Join-Path $HOME '.claude')
    }

    It 'holds no credentials and no keys beyond the documented ones' {
        Get-SwitchAccountConfig -ConfigPath $path | Out-Null

        $json = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $json.accounts[0].PSObject.Properties.Name | Should -Be @(
            'name', 'configDir', 'remoteControl', 'maxFiveHourPercent', 'maxWeeklyPercent',
            'defaultModel', 'defaultEffort', 'defaultSubagentModel')
    }

    It 'does not overwrite an existing file' {
        Get-SwitchAccountConfig -ConfigPath $path | Out-Null
        $edited = (Get-Content -LiteralPath $path -Raw) -replace '"maxFiveHourPercent": 80', '"maxFiveHourPercent": 55'
        Set-Content -LiteralPath $path -Value $edited

        $again = Get-SwitchAccountConfig -ConfigPath $path

        $again.Created | Should -BeFalse
        $again.Accounts[0].MaxFiveHourPercent | Should -Be 55
    }

    It 'returns the defaults without writing with -NoCreate' {
        $config = Get-SwitchAccountConfig -ConfigPath $path -NoCreate

        $config.Created | Should -BeFalse
        $config.Accounts.Count | Should -Be 2
        Test-Path -LiteralPath $path | Should -BeFalse
    }

    It 'reads caps, weekly cap, defaults and Remote Control per account' {
        Write-Config $path ([ordered]@{
                claudePath = 'C:\tools\claude.exe'
                accounts   = @(
                    [ordered]@{
                        name = 'Work'; configDir = '~/.claude-work'; remoteControl = $false; maxFiveHourPercent = 60
                        maxWeeklyPercent = 90; defaultModel = 'Sonnet'; defaultEffort = 'HIGH'; defaultSubagentModel = 'haiku'
                    }
                )
            }) | Out-Null

        $config = Get-SwitchAccountConfig -ConfigPath $path
        $account = $config.Accounts[0]

        $config.ClaudePath | Should -Be 'C:\tools\claude.exe'
        $account.Name | Should -Be 'Work'
        $account.ConfigDir | Should -Be (Join-Path $HOME '.claude-work')
        $account.RemoteControl | Should -BeFalse
        $account.MaxFiveHourPercent | Should -Be 60
        $account.MaxWeeklyPercent | Should -Be 90
        $account.DefaultModel | Should -Be 'sonnet'
        $account.DefaultEffort | Should -Be 'high'
        $account.DefaultSubagentModel | Should -Be 'haiku'
    }

    It 'fills the cap and Remote Control with defaults when they are missing' {
        Write-Config $path @{ accounts = @(@{ name = 'X'; configDir = '~/.claude-x' }) } | Out-Null

        $account = (Get-SwitchAccountConfig -ConfigPath $path).Accounts[0]

        $account.MaxFiveHourPercent | Should -Be 80
        $account.RemoteControl | Should -BeTrue
    }

    It 'refuses a bad file: <Case>' -TestCases @(
        @{ Case = 'not JSON'; Raw = '{ nope' }
        @{ Case = 'no accounts'; Raw = '{"accounts": []}' }
        @{ Case = 'no accounts key'; Raw = '{}' }
        @{ Case = 'bad name'; Raw = '{"accounts":[{"name":"a b;","configDir":"~/x"}]}' }
        @{ Case = 'missing name'; Raw = '{"accounts":[{"configDir":"~/x"}]}' }
        @{ Case = 'missing configDir'; Raw = '{"accounts":[{"name":"A"}]}' }
        @{ Case = 'duplicate names'; Raw = '{"accounts":[{"name":"A","configDir":"~/x"},{"name":"a","configDir":"~/y"}]}' }
        @{ Case = 'same configDir'; Raw = '{"accounts":[{"name":"A","configDir":"~/x"},{"name":"B","configDir":"~/x/"}]}' }
        @{ Case = 'cap 0'; Raw = '{"accounts":[{"name":"A","configDir":"~/x","maxFiveHourPercent":0}]}' }
        @{ Case = 'cap 101'; Raw = '{"accounts":[{"name":"A","configDir":"~/x","maxFiveHourPercent":101}]}' }
        @{ Case = 'cap text'; Raw = '{"accounts":[{"name":"A","configDir":"~/x","maxFiveHourPercent":"80"}]}' }
        @{ Case = 'weekly cap 200'; Raw = '{"accounts":[{"name":"A","configDir":"~/x","maxWeeklyPercent":200}]}' }
        @{ Case = 'rc text'; Raw = '{"accounts":[{"name":"A","configDir":"~/x","remoteControl":"yes"}]}' }
        @{ Case = 'bad model'; Raw = '{"accounts":[{"name":"A","configDir":"~/x","defaultModel":"gpt"}]}' }
        @{ Case = 'bad effort'; Raw = '{"accounts":[{"name":"A","configDir":"~/x","defaultEffort":"insane"}]}' }
        @{ Case = 'bad claudePath'; Raw = '{"claudePath":5,"accounts":[{"name":"A","configDir":"~/x"}]}' }
    ) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        Set-Content -LiteralPath $path -Value $Raw

        { Get-SwitchAccountConfig -ConfigPath $path } | Should -Throw -ErrorId 'SwitchAccounts.InvalidArgument'
    }

    It 'names the account in the error' {
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        Set-Content -LiteralPath $path -Value '{"accounts":[{"name":"A","configDir":"~/x"},{"name":"B","configDir":"~/y","maxFiveHourPercent":500}]}'

        { Get-SwitchAccountConfig -ConfigPath $path } | Should -Throw '*account #2*B*maxFiveHourPercent*'
    }
}
