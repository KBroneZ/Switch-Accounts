BeforeAll {
    $scripts = Join-Path $PSScriptRoot '..' 'skills' 'fleet-director' 'scripts'
    $askScript = Join-Path $scripts 'ask-gemini.ps1'
    $usageScript = Join-Path $scripts 'gemini-usage.ps1'
    . (Join-Path $scripts 'gemini-accounts.ps1')
    $pwshPath = (Get-Process -Id $PID).Path

    function New-Launcher {
        param([string] $Dir, [string] $Name, [string] $Impl)
        Set-Content -LiteralPath (Join-Path $Dir "$Name-impl.ps1") -Value $Impl
        if ($IsWindows) {
            $path = Join-Path $Dir "$Name.cmd"
            Set-Content -LiteralPath $path -Value "@`"$pwshPath`" -NoProfile -File `"%~dp0$Name-impl.ps1`" %*"
        } else {
            $path = Join-Path $Dir $Name
            Set-Content -LiteralPath $path -Value "#!/bin/sh`nexec `"$pwshPath`" -NoProfile -File `"`$(dirname `"`$0`")/$Name-impl.ps1`" `"`$@`"`n" -NoNewline
            & chmod +x $path
        }
        $path
    }

    # Usage the fake agy answers for `/usage`: Gemini and Claude/GPT weekly windows with this much left.
    function New-UsageJson {
        param([double] $GeminiLeft, [double] $OtherLeft = 1, [string] $Reset = '2030-01-15T00:00:00Z')
        @{
            status  = 'SUCCESS'
            command = @{ name = 'usage'; data = @{ groups = @(
                    @{ name = 'Gemini Models'; buckets = @(@{ window = 'weekly'; remaining_fraction = $GeminiLeft; reset_time = $Reset }) }
                    @{ name = 'Claude and GPT models'; buckets = @(@{ window = 'weekly'; remaining_fraction = $OtherLeft; reset_time = $Reset }) }
                ) } }
        } | ConvertTo-Json -Depth 8 -Compress
    }

    # A throwaway home: fake aisw (profiles g1, g2, state in files), fake agy (answers as the live profile),
    # data folder with gemini-accounts.json.
    function New-GeminiEnv {
        param([string[]] $Profiles = @('g1', 'g2'), [string] $Config)
        $root = Join-Path $TestDrive "gem-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
        $state = Join-Path $root 'state'
        $data = Join-Path $root 'data'
        $bin = Join-Path $root 'bin'
        New-Item -ItemType Directory -Path $state, $data, $bin | Out-Null
        Set-Content -LiteralPath (Join-Path $state 'active.txt') -Value 'g1' -NoNewline
        $aisw = New-Launcher $bin 'aisw' @'
$state = $env:FAKE_AISW_DIR
Add-Content -LiteralPath (Join-Path $state 'calls.log') -Value ($args -join ' ')
$profiles = @($env:FAKE_AISW_PROFILES -split ',')
if ($args[0] -eq 'use') {
    $p = $args[2]
    if ($p -notin $profiles) { [Console]::Out.Write('{"ok":false,"error":{"kind":"profile_not_found","message":"profile not found"}}'); exit 2 }
    if ($env:FAKE_AISW_FAIL_SWITCH -eq $p) { [Console]::Error.WriteLine('keyring is locked'); exit 1 }
    if ($env:FAKE_AISW_NOOP_SWITCH -ne $p) { Set-Content -LiteralPath (Join-Path $state 'active.txt') -Value $p -NoNewline }
    [Console]::Out.Write('{"ok":true}'); exit 0
}
if ($args[0] -eq 'status') {
    $active = Get-Content -LiteralPath (Join-Path $state 'active.txt') -Raw
    [Console]::Out.Write((@(@{ tool = 'agy'; active_profile = $active; active_profile_applied = $true }) | ConvertTo-Json -Compress -AsArray)); exit 0
}
exit 9
'@
        $agy = New-Launcher $bin 'agy' @'
$state = $env:FAKE_AISW_DIR
$active = Get-Content -LiteralPath (Join-Path $state 'active.txt') -Raw
Add-Content -LiteralPath (Join-Path $state 'agy-runs.log') -Value "$active :: $($args[1])"
if ($args[1] -eq '/usage') {
    $file = Join-Path $state "usage-$active.json"
    if (-not (Test-Path -LiteralPath $file)) { [Console]::Error.WriteLine('no usage for this account'); exit 1 }
    [Console]::Out.Write((Get-Content -LiteralPath $file -Raw)); exit 0
}
if ($env:FAKE_AGY -eq 'fail') { [Console]::Error.WriteLine('quota exhausted'); exit 1 }
[Console]::Out.Write((@{ status = 'SUCCESS'; response = "ANSWER by $active"; usage = @{ total_tokens = 10 } } | ConvertTo-Json -Compress)); exit 0
'@
        if (-not $Config) {
            $Config = '{"accounts":[{"name":"G1","profile":"g1","label":"main"},{"name":"G2","profile":"g2","label":"second"}]}'
        }
        Set-Content -LiteralPath (Join-Path $data 'gemini-accounts.json') -Value $Config
        [pscustomobject]@{ Root = $root; State = $state; Data = $data; Aisw = $aisw; Agy = $agy; Profiles = ($Profiles -join ',') }
    }

    function Set-FakeUsage {
        param($Env, [string] $Profile, [string] $Json, [switch] $AsReading)
        Set-Content -LiteralPath (Join-Path $Env.State "usage-$Profile.json") -Value $Json -NoNewline
    }

    function Set-Reading {
        # A kept reading for an account, as Fleet or an earlier call left it.
        param($Env, [string] $Name, [string] $Json, [int] $AgeMinutes = 5)
        $path = Join-Path $Env.Data "gemini-usage-$Name.json"
        Set-Content -LiteralPath $path -Value $Json -NoNewline
        (Get-Item -LiteralPath $path).LastWriteTimeUtc = [DateTime]::UtcNow.AddMinutes(-$AgeMinutes)
    }

    function Get-Active($Env) { (Get-Content -LiteralPath (Join-Path $Env.State 'active.txt') -Raw).Trim() }
    function Get-AgyRuns($Env) {
        $log = Join-Path $Env.State 'agy-runs.log'
        if (Test-Path -LiteralPath $log) { @(Get-Content -LiteralPath $log) } else { @() }
    }

    function Invoke-Script {
        param($Env, [string] $Script, [string[]] $Arguments, [hashtable] $Vars = @{})
        $all = @{ FAKE_AISW_DIR = $Env.State; FAKE_AISW_PROFILES = $Env.Profiles } + $Vars
        $previous = @{}
        foreach ($k in $all.Keys) { $previous[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $all[$k]) }
        try {
            $out = & $pwshPath -NoProfile -File $Script @Arguments -AgyPath $Env.Agy -AiswPath $Env.Aisw -DataDir $Env.Data 2>&1
            [pscustomobject]@{ Exit = $LASTEXITCODE; Text = ($out -join "`n") }
        } finally {
            foreach ($k in $all.Keys) { [Environment]::SetEnvironmentVariable($k, $previous[$k]) }
        }
    }

    function Invoke-Ask($Env, [string[]] $Arguments, [hashtable] $Vars = @{}) {
        $out = Join-Path $Env.Root "answer-$([guid]::NewGuid().ToString('N').Substring(0, 6)).md"
        $r = Invoke-Script $Env $askScript (@('-Prompt', 'hello', '-Out', $out) + $Arguments) $Vars
        $r | Add-Member -NotePropertyName OutFile -NotePropertyValue $out -PassThru
    }
}

Describe 'Get-GeminiAccountConfig' {
    It 'is $null without the file (single-account behaviour) and reads the accounts with a default' {
        Get-GeminiAccountConfig -Path (Join-Path $TestDrive 'none.json') | Should -BeNullOrEmpty
        $env1 = New-GeminiEnv -Config '{"defaultAccount":"g2x","accounts":[{"name":"G1","profile":"g1"},{"name":"g2x","profile":"g2","label":"second"}]}'
        $c = Get-GeminiAccountConfig -Path (Join-Path $env1.Data 'gemini-accounts.json')
        $c.Accounts.Name | Should -Be @('G1', 'g2x')
        $c.Default.Profile | Should -Be 'g2'
        $c.Accounts[1].Label | Should -Be 'second'
        $first = New-GeminiEnv
        (Get-GeminiAccountConfig -Path (Join-Path $first.Data 'gemini-accounts.json')).Default.Name | Should -Be 'G1'
    }

    It 'refuses bad files with exit code 1' -ForEach @(
        @{ Json = 'not json'; Match = 'not valid JSON' }
        @{ Json = '{"accounts":[]}'; Match = 'at least one account' }
        @{ Json = '{"accounts":[{"name":"auto","profile":"g1"}]}'; Match = 'auto' }
        @{ Json = '{"accounts":[{"name":"G1"}]}'; Match = 'aisw "profile"' }
        @{ Json = '{"accounts":[{"name":"G1","profile":"g1"},{"name":"g1","profile":"g2"}]}'; Match = 'used twice' }
        @{ Json = '{"accounts":[{"name":"G1","profile":"g1"},{"name":"G2","profile":"g1"}]}'; Match = 'used by two' }
        @{ Json = '{"defaultAccount":"X","accounts":[{"name":"G1","profile":"g1"}]}'; Match = 'defaultAccount X' }
        @{ Json = '{"accounts":[{"name":"-x","profile":"g1"}]}'; Match = '"name"' }
    ) {
        $e = New-GeminiEnv -Config $Json
        $thrown = $null
        try { Get-GeminiAccountConfig -Path (Join-Path $e.Data 'gemini-accounts.json') } catch { $thrown = $_ }
        $thrown | Should -Not -BeNullOrEmpty
        $thrown.Exception.Message | Should -Match $Match
        $thrown.Exception.Data['GeminiExitCode'] | Should -Be 1
    }
}

Describe 'usage windows and the choice of account' {
    It 'reads the windows of agy /usage; a window whose reset has passed is unknown, never 0 %' {
        $w = ConvertFrom-AgyUsage -Text (New-UsageJson -GeminiLeft 0.75) -Now ([DateTimeOffset]::Parse('2030-01-10T00:00:00Z'))
        @($w | ForEach-Object { "$($_.Group) $($_.Window) $($_.Pct)" }) | Should -Be @('Gemini weekly 25', 'Claude/GPT weekly 0')
        $past = ConvertFrom-AgyUsage -Text (New-UsageJson -GeminiLeft 0.75) -Now ([DateTimeOffset]::Parse('2030-01-16T00:00:00Z'))
        $past[0].Pct | Should -BeNullOrEmpty
        $past[0].ResetsAt | Should -BeNullOrEmpty
        ConvertFrom-AgyUsage -Text 'You are not logged in.' | Should -BeNullOrEmpty
        ConvertFrom-AgyUsage -Text '{"status":"ERROR"}' | Should -BeNullOrEmpty
    }

    It 'reads whole-number fractions (Int64) and a window that has not started (reset printed as 1970) as known use' {
        $text = '{"status":"SUCCESS","command":{"data":{"groups":[{"name":"Claude and GPT models","buckets":[{"window":"weekly","remaining_fraction":1,"reset_time":"1970-01-01T00:00:00Z"},{"window":"5h","remaining_fraction":0,"reset_time":"1970-01-01T00:00:00Z"}]}]}}}'
        $w = ConvertFrom-AgyUsage -Text $text -Now ([DateTimeOffset]::Parse('2030-01-10T00:00:00Z'))
        @($w | ForEach-Object { "$($_.Group) $($_.Window) $($_.Pct)" }) | Should -Be @('Claude/GPT weekly 0', 'Claude/GPT 5h 100')
        $w[0].ResetsAt | Should -BeNullOrEmpty
    }

    It 'gives each model its own group, and unknown never counts as room' {
        $e = New-GeminiEnv
        $config = Get-GeminiAccountConfig -Path (Join-Path $e.Data 'gemini-accounts.json')
        Set-Reading $e 'G1' (New-UsageJson -GeminiLeft 0.1 -OtherLeft 0.9)
        (Read-GeminiUsage -DataDir $e.Data -Account $config.Accounts[0] -Model 'gemini-3.8-flash-high').Room | Should -Be 10
        (Read-GeminiUsage -DataDir $e.Data -Account $config.Accounts[0] -Model 'claude-opus-4-6-thinking').Room | Should -Be 90
        $none = Read-GeminiUsage -DataDir $e.Data -Account $config.Accounts[1] -Model 'gemini-3.8-flash-high'
        $none.Room | Should -BeNullOrEmpty
        $none.Why | Should -Be 'never read'
        Set-Reading $e 'G2' (New-UsageJson -GeminiLeft 0.5 -Reset '2020-01-01T00:00:00Z')
        (Read-GeminiUsage -DataDir $e.Data -Account $config.Accounts[1] -Model 'gemini-3.8-flash-high').Room | Should -BeNullOrEmpty
    }

    It 'picks the most room, ties go to the first account, and none with unknown or no room' {
        $a = [pscustomobject]@{ Name = 'A' }
        $b = [pscustomobject]@{ Name = 'B' }
        $c = [pscustomobject]@{ Name = 'C' }
        (Select-GeminiAccount -Readings @([pscustomobject]@{ Account = $a; Room = 20 }, [pscustomobject]@{ Account = $b; Room = 60 }, [pscustomobject]@{ Account = $c; Room = $null })).Account.Name | Should -Be 'B'
        (Select-GeminiAccount -Readings @([pscustomobject]@{ Account = $a; Room = 50 }, [pscustomobject]@{ Account = $b; Room = 50 })).Account.Name | Should -Be 'A'
        Select-GeminiAccount -Readings @([pscustomobject]@{ Account = $a; Room = $null }, [pscustomobject]@{ Account = $b; Room = 0 }) | Should -BeNullOrEmpty
    }
}

Describe 'gemini-usage.ps1' {
    It 'switches to the account, reads its usage into its own file, and puts the default back' {
        $e = New-GeminiEnv
        Set-FakeUsage $e 'g2' (New-UsageJson -GeminiLeft 0.6)

        $r = Invoke-Script $e $usageScript @('-Account', 'G2')

        $r.Exit | Should -Be 0
        (Get-Content -LiteralPath (Join-Path $e.Data 'gemini-usage-G2.json') -Raw) | Should -Match '"remaining_fraction":0.6'
        Test-Path -LiteralPath (Join-Path $e.Data 'gemini-usage-G1.json') | Should -BeFalse
        Get-AgyRuns $e | Should -Be @('g2 :: /usage')
        Get-Active $e | Should -Be 'g1'
        $calls = Get-Content -LiteralPath (Join-Path $e.State 'calls.log')
        $calls[0] | Should -BeLike 'use antigravity g2*'
        $calls[1] | Should -BeLike 'status*'
    }

    It 'keeps the last answer and says why when agy fails' {
        $e = New-GeminiEnv
        Set-Reading $e 'G2' (New-UsageJson -GeminiLeft 0.3) 600

        $r = Invoke-Script $e $usageScript @('-Account', 'G2')

        $r.Exit | Should -Be 3
        (Get-Content -LiteralPath (Join-Path $e.Data 'gemini-usage-G2.json') -Raw) | Should -Match '0.3'
        (Get-Content -LiteralPath (Join-Path $e.Data 'gemini-error-G2.txt') -Raw) | Should -BeLike 'agy /usage failed (1): *no usage*'
        Get-Active $e | Should -Be 'g1'
    }

    It 'says the account is unavailable (exit 6) for a missing profile, a failed switch and a switch aisw does not confirm, and never reads another account' {
        $e = New-GeminiEnv -Profiles @('g1')
        Set-FakeUsage $e 'g1' (New-UsageJson -GeminiLeft 0.9)
        $missing = Invoke-Script $e $usageScript @('-Account', 'G2')
        $missing.Exit | Should -Be 6
        $missing.Text | Should -BeLike '*G2 is unavailable*'
        Get-AgyRuns $e | Should -HaveCount 0

        $e2 = New-GeminiEnv
        $failed = Invoke-Script $e2 $usageScript @('-Account', 'G2') @{ FAKE_AISW_FAIL_SWITCH = 'g2' }
        $failed.Exit | Should -Be 6
        $failed.Text | Should -BeLike '*keyring is locked*'
        Get-AgyRuns $e2 | Should -HaveCount 0

        $unconfirmed = Invoke-Script $e2 $usageScript @('-Account', 'G2') @{ FAKE_AISW_NOOP_SWITCH = 'g2' }
        $unconfirmed.Exit | Should -Be 6
        $unconfirmed.Text | Should -BeLike '*reports g1 live, not g2*'
        Get-AgyRuns $e2 | Should -HaveCount 0
    }

    It 'says aisw is missing (exit 6) and an unknown account is a bad argument (exit 1)' {
        $e = New-GeminiEnv
        $missing = & $pwshPath -NoProfile -File $usageScript -Account G2 -AgyPath $e.Agy -AiswPath (Join-Path $e.Root 'no-aisw.exe') -DataDir $e.Data 2>&1
        $LASTEXITCODE | Should -Be 6
        ($missing -join ' ') | Should -BeLike '*aisw was not found*'
        (Invoke-Script $e $usageScript @('-Account', 'G9')).Exit | Should -Be 1
    }

    It 'does not run while another Gemini run holds the lock (exit 4), and leaves the accounts alone' {
        $e = New-GeminiEnv
        $lock = Enter-GeminiLock -Path (Join-Path $e.Data 'gemini.lock')
        try {
            $r = Invoke-Script $e $usageScript @('-Account', 'G2')
            $r.Exit | Should -Be 4
            Get-AgyRuns $e | Should -HaveCount 0
            Test-Path -LiteralPath (Join-Path $e.State 'calls.log') | Should -BeFalse
        } finally { Exit-GeminiLock $lock }
        (Invoke-Script $e $usageScript @()).Exit | Should -Not -Be 4
    }
}

Describe 'ask-gemini.ps1 with several Google accounts' {
    It 'runs agy in the named account, marks it, reads its usage again and puts g1 back' {
        $e = New-GeminiEnv
        Set-FakeUsage $e 'g2' (New-UsageJson -GeminiLeft 0.4)

        $r = Invoke-Ask $e @('-Account', 'g2')

        $r.Exit | Should -Be 0
        $r.Text | Should -BeLike '*account: G2*'
        $text = Get-Content -LiteralPath $r.OutFile -Raw
        $text | Should -Match '(?m)^account: G2$'
        $text | Should -Match 'ANSWER by g2'
        $text | Should -Match '(?m)^status: UNVERIFIED$'
        Get-AgyRuns $e | Should -Be @('g2 :: hello', 'g2 :: /usage')
        (Get-Content -LiteralPath (Join-Path $e.Data 'gemini-usage-G2.json') -Raw) | Should -Match '0.4'
        Get-Active $e | Should -Be 'g1'
    }

    It '-NoUsageRefresh skips the extra /usage call' {
        $e = New-GeminiEnv
        $r = Invoke-Ask $e @('-Account', 'G2', '-NoUsageRefresh')
        $r.Exit | Should -Be 0
        Get-AgyRuns $e | Should -Be @('g2 :: hello')
    }

    It 'auto picks the account with the most room for the model from the kept readings' {
        $e = New-GeminiEnv
        Set-Reading $e 'G1' (New-UsageJson -GeminiLeft 0.2 -OtherLeft 0.9)
        Set-Reading $e 'G2' (New-UsageJson -GeminiLeft 0.7 -OtherLeft 0.1)
        Set-FakeUsage $e 'g1' (New-UsageJson -GeminiLeft 0.2 -OtherLeft 0.9)
        Set-FakeUsage $e 'g2' (New-UsageJson -GeminiLeft 0.7 -OtherLeft 0.1)

        $gemini = Invoke-Ask $e @('-Model', 'gemini-3.8-flash-high')
        $gemini.Text | Should -BeLike '*account: G2*'

        $other = Invoke-Ask $e @('-Model', 'claude-opus-4-6-thinking')
        $other.Text | Should -BeLike '*account: G1*'
        # Readings were fresh: only the calls and their own refreshes ran, no extra reads.
        (Get-AgyRuns $e) | Should -Be @('g2 :: hello', 'g2 :: /usage', 'g1 :: hello', 'g1 :: /usage')
        Get-Active $e | Should -Be 'g1'
    }

    It 'auto reads an account whose usage is unknown first, and never counts it as 0 % used' {
        $e = New-GeminiEnv
        Set-Reading $e 'G1' (New-UsageJson -GeminiLeft 0.3)
        Set-FakeUsage $e 'g2' (New-UsageJson -GeminiLeft 0.8)

        $r = Invoke-Ask $e @()

        $r.Text | Should -BeLike '*account: G2*'
        Get-AgyRuns $e | Should -Be @('g2 :: /usage', 'g2 :: hello', 'g2 :: /usage')
    }

    It 'auto skips an unavailable account out loud, and stops when no account has known room' {
        $e = New-GeminiEnv -Profiles @('g1')
        Set-Reading $e 'G1' (New-UsageJson -GeminiLeft 0.5)
        $one = Invoke-Ask $e @()
        $one.Exit | Should -Be 0
        $one.Text | Should -BeLike '*Skipped Google account G2: usage unknown*'
        $one.Text | Should -BeLike '*account: G1*'

        $none = New-GeminiEnv
        $r = Invoke-Ask $none @()
        $r.Exit | Should -Be 3
        $r.Text | Should -BeLike '*No Google account has known room*'
        Test-Path -LiteralPath $r.OutFile | Should -BeFalse
        Get-Active $none | Should -Be 'g1'
    }

    It 'auto stops, naming the resets, when every account is at its limit' {
        $e = New-GeminiEnv
        Set-Reading $e 'G1' (New-UsageJson -GeminiLeft 0)
        Set-Reading $e 'G2' (New-UsageJson -GeminiLeft 0)
        $r = Invoke-Ask $e @()
        $r.Exit | Should -Be 3
        $r.Text | Should -BeLike '*G1 resets 2030-01-15*'
        Get-AgyRuns $e | Should -HaveCount 0
    }

    It 'stops with exit 6 when the named account cannot be switched to, and runs agy nowhere' {
        $e = New-GeminiEnv -Profiles @('g1')
        $r = Invoke-Ask $e @('-Account', 'G2')
        $r.Exit | Should -Be 6
        $r.Text | Should -BeLike '*G2 is unavailable*'
        Get-AgyRuns $e | Should -HaveCount 0
        Get-Active $e | Should -Be 'g1'
        Test-Path -LiteralPath $r.OutFile | Should -BeFalse
    }

    It 'keeps every safety rule: a secret-looking prompt is blocked before any switch' {
        $e = New-GeminiEnv
        $out = Join-Path $e.Root 'x.md'
        $r = Invoke-Script $e $askScript @('-Prompt', 'key sk-ant-abcdefghijklmnopqrstuvwxyz123', '-Out', $out, '-Account', 'G2')
        $r.Exit | Should -Be 2
        Test-Path -LiteralPath (Join-Path $e.State 'calls.log') | Should -BeFalse
    }

    It 'reports a failed agy with exit 3, still reads usage and puts g1 back' {
        $e = New-GeminiEnv
        Set-FakeUsage $e 'g2' (New-UsageJson -GeminiLeft 0.1)
        $r = Invoke-Ask $e @('-Account', 'G2') @{ FAKE_AGY = 'fail' }
        $r.Exit | Should -Be 3
        $r.Text | Should -BeLike '*quota exhausted*'
        (Get-Content -LiteralPath (Join-Path $e.Data 'gemini-usage-G2.json') -Raw) | Should -Match '0.1'
        Get-Active $e | Should -Be 'g1'
    }

    It 'waits for the lock, then reports exit 4 while it stays busy' {
        $e = New-GeminiEnv
        $lock = Enter-GeminiLock -Path (Join-Path $e.Data 'gemini.lock')
        try {
            $r = Invoke-Ask $e @('-Account', 'G2', '-LockWaitSeconds', '1')
            $r.Exit | Should -Be 4
            Get-AgyRuns $e | Should -HaveCount 0
            # Not the lock holder: no aisw call at all, so the holder's account is not switched under it.
            Test-Path -LiteralPath (Join-Path $e.State 'calls.log') | Should -BeFalse
        } finally { Exit-GeminiLock $lock }
    }

    It 'refuses -Account without gemini-accounts.json, and an unknown name' {
        $e = New-GeminiEnv
        Remove-Item -LiteralPath (Join-Path $e.Data 'gemini-accounts.json')
        $r = Invoke-Ask $e @('-Account', 'G2')
        $r.Exit | Should -Be 1
        $r.Text | Should -BeLike '*gemini-accounts.json*'
        # No file: the single-account behaviour, agy runs with whatever is live and no aisw is called.
        $plain = Invoke-Ask $e @()
        $plain.Exit | Should -Be 0
        Test-Path -LiteralPath (Join-Path $e.State 'calls.log') | Should -BeFalse

        $e2 = New-GeminiEnv
        $unknown = Invoke-Ask $e2 @('-Account', 'G9')
        $unknown.Exit | Should -Be 1
        $unknown.Text | Should -BeLike '*Unknown Google account: G9*'
    }
}
