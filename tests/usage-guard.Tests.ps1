BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    $fake = Get-FakeClaudePath
    $guard = Join-Path $PSScriptRoot '..' 'scripts' 'usage-guard.ps1'

    function Invoke-Guard {
        param([string] $ConfigDir, [string] $StatePath, [double] $Cap = 70, [double] $Interval = 5, [double] $WeeklyCap = 0)
        $hookInput = '{"hook_event_name":"PreToolUse","tool_name":"Bash"}'
        $extra = if ($WeeklyCap -gt 0) { @('-MaxWeeklyPercent', $WeeklyCap) } else { @() }
        $hookInput | pwsh -NoProfile -NonInteractive -File $guard -ConfigDir $ConfigDir `
            -MaxFiveHourPercent $Cap -StatePath $StatePath -ClaudePath $fake -IntervalMinutes $Interval @extra
    }

    function Set-GuardState {
        param([string] $Path, [string] $Decision, [DateTimeOffset] $LastCheck)
        @{ Decision = $Decision; Reason = 'test'; LastCheck = $LastCheck.ToString('o') } |
            ConvertTo-Json | Set-Content -LiteralPath $Path
    }
}

Describe 'usage-guard.ps1' {
    BeforeEach {
        $state = Join-Path $TestDrive "guard-$([guid]::NewGuid()).json"
    }

    It 'stays silent and skips the CLI when the last check allowed and is recent' {
        $dir = New-FakeAccount -Path (Join-Path $TestDrive "g-$([guid]::NewGuid())") -UsageText (Get-SampleUsageText -Percent '99')
        Set-GuardState -Path $state -Decision 'Allow' -LastCheck ([DateTimeOffset]::Now)

        $out = Invoke-Guard -ConfigDir $dir -StatePath $state

        $out | Should -BeNullOrEmpty
        @(Get-FakeCalls -ConfigDir $dir) | Should -HaveCount 0
    }

    It 're-reads usage after the interval and stays silent below the cap' {
        $dir = New-FakeAccount -Path (Join-Path $TestDrive "g-$([guid]::NewGuid())") -UsageText (Get-SampleUsageText -Percent '30')
        Set-GuardState -Path $state -Decision 'Allow' -LastCheck ([DateTimeOffset]::Now.AddMinutes(-6))

        $out = Invoke-Guard -ConfigDir $dir -StatePath $state

        $out | Should -BeNullOrEmpty
        @(Get-FakeCalls -ConfigDir $dir) | Should -HaveCount 1
        (Get-Content -LiteralPath $state -Raw | ConvertFrom-Json).Decision | Should -Be 'Allow'
    }

    It 'stops the session when usage reaches the cap' {
        $dir = New-FakeAccount -Path (Join-Path $TestDrive "g-$([guid]::NewGuid())") -UsageText (Get-SampleUsageText -Percent '71')

        $out = Invoke-Guard -ConfigDir $dir -StatePath $state | ConvertFrom-Json

        $out.continue | Should -BeFalse
        $out.stopReason | Should -Match '71%'
        (Get-Content -LiteralPath $state -Raw | ConvertFrom-Json).Decision | Should -Be 'Wait'
    }

    It 'stops the session when usage is unknown' {
        $dir = New-FakeAccount -Path (Join-Path $TestDrive "g-$([guid]::NewGuid())") -UsageText 'Not logged in' -IsError

        (Invoke-Guard -ConfigDir $dir -StatePath $state | ConvertFrom-Json).continue | Should -BeFalse
    }

    It 'keeps stopping once it has stopped, without asking again' {
        $dir = New-FakeAccount -Path (Join-Path $TestDrive "g-$([guid]::NewGuid())") -UsageText (Get-SampleUsageText -Percent '10')
        Set-GuardState -Path $state -Decision 'Wait' -LastCheck ([DateTimeOffset]::Now)

        (Invoke-Guard -ConfigDir $dir -StatePath $state | ConvertFrom-Json).continue | Should -BeFalse
        @(Get-FakeCalls -ConfigDir $dir) | Should -HaveCount 0
    }

    It 'reads usage again after the interval once it has stopped, so a new window lets work go on' {
        $dir = New-FakeAccount -Path (Join-Path $TestDrive "g-$([guid]::NewGuid())") -UsageText (Get-SampleUsageText -Percent '10')
        Set-GuardState -Path $state -Decision 'Wait' -LastCheck ([DateTimeOffset]::Now.AddMinutes(-6))

        $out = Invoke-Guard -ConfigDir $dir -StatePath $state

        $out | Should -BeNullOrEmpty
        @(Get-FakeCalls -ConfigDir $dir) | Should -HaveCount 1
        (Get-Content -LiteralPath $state -Raw | ConvertFrom-Json).Decision | Should -Be 'Allow'
    }

    It 'reads usage again when the last check is dated in the future' {
        $dir = New-FakeAccount -Path (Join-Path $TestDrive "g-$([guid]::NewGuid())") -UsageText (Get-SampleUsageText -Percent '99')
        Set-GuardState -Path $state -Decision 'Allow' -LastCheck ([DateTimeOffset]::Now.AddHours(2))

        (Invoke-Guard -ConfigDir $dir -StatePath $state | ConvertFrom-Json).continue | Should -BeFalse
        @(Get-FakeCalls -ConfigDir $dir) | Should -HaveCount 1
    }

    It 'stops the session when the weekly usage reaches its optional cap' {
        $dir = New-FakeAccount -Path (Join-Path $TestDrive "g-$([guid]::NewGuid())") `
            -UsageText (Get-SampleUsageText -Percent '10' -Weekly '92')

        $out = Invoke-Guard -ConfigDir $dir -StatePath $state -WeeklyCap 90 | ConvertFrom-Json

        $out.continue | Should -BeFalse
        $out.stopReason | Should -Match 'weekly'
    }

    It 'leaves no temporary files next to its state file' {
        $dir = New-FakeAccount -Path (Join-Path $TestDrive "g-$([guid]::NewGuid())") -UsageText (Get-SampleUsageText -Percent '10')
        $folder = Join-Path $TestDrive "s-$([guid]::NewGuid())"
        New-Item -ItemType Directory -Path $folder | Out-Null
        $state = Join-Path $folder 'guard.json'

        Invoke-Guard -ConfigDir $dir -StatePath $state | Out-Null

        @(Get-ChildItem -LiteralPath $folder).Name | Should -Be @('guard.json')
    }

    It 'fails closed when its state file is corrupt' {
        $dir = New-FakeAccount -Path (Join-Path $TestDrive "g-$([guid]::NewGuid())") -UsageText (Get-SampleUsageText -Percent '10')
        Set-Content -LiteralPath $state -Value '{ not json'

        (Invoke-Guard -ConfigDir $dir -StatePath $state | ConvertFrom-Json).continue | Should -BeFalse
    }
}
