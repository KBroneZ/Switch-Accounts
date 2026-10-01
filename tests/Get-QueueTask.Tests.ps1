BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'SwitchAccounts.psd1') -Force

    function New-Task {
        param([string] $Dir, [string] $Name, [string] $Header, [string] $Body = 'Do the thing.')
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        $text = if ($null -ne $Header) { "---`n$Header`n---`n`n$Body`n" } else { "$Body`n" }
        Set-Content -LiteralPath (Join-Path $Dir $Name) -Value $text -NoNewline
    }
}

Describe 'Get-QueueTask' {
    BeforeEach { $queue = Join-Path $TestDrive "q-$([guid]::NewGuid())" }

    It 'parses number, slug, header fields and body' {
        New-Task $queue '007-add-login.md' "status: ready`ntier: R1`nauto: true`ngates: []" 'Implement login.'

        $task = Get-QueueTask -QueueDir $queue

        $task.Number | Should -Be 7
        $task.Id | Should -Be '007'
        $task.Slug | Should -Be 'add-login'
        $task.Status | Should -Be 'ready'
        $task.Tier | Should -Be 'R1'
        $task.Auto | Should -BeTrue
        $task.Body | Should -Match 'Implement login'
        $task.Eligible | Should -BeTrue
    }

    It 'returns tasks ordered by number' {
        New-Task $queue '010-b.md' "status: ready`nauto: true"
        New-Task $queue '002-a.md' "status: ready`nauto: true"

        (Get-QueueTask -QueueDir $queue).Number | Should -Be @(2, 10)
    }

    It 'marks a task ineligible when <Case>' -TestCases @(
        @{ Case = 'status is not ready'; Header = "status: draft`nauto: true" }
        @{ Case = 'auto is false'; Header = "status: ready`nauto: false" }
        @{ Case = 'auto is missing'; Header = 'status: ready' }
        @{ Case = 'tier is R3'; Header = "status: ready`nauto: true`ntier: R3" }
        @{ Case = 'it has open gates'; Header = "status: ready`nauto: true`ngates: [publish]" }
        @{ Case = 'auto is not a boolean'; Header = "status: ready`nauto: yes" }
    ) {
        New-Task $queue '001-x.md' $Header

        $task = Get-QueueTask -QueueDir $queue

        $task.Eligible | Should -BeFalse
        $task.Reason | Should -Not -BeNullOrEmpty
    }

    It 'reports files without a header or with a bad name as invalid, not eligible' {
        New-Task $queue '001-ok.md' $null
        New-Task $queue 'notes.md' "status: ready`nauto: true"

        $tasks = Get-QueueTask -QueueDir $queue

        $tasks | Should -HaveCount 2
        @($tasks | Where-Object Eligible) | Should -HaveCount 0
    }

    It 'fails when the queue folder does not exist' {
        { Get-QueueTask -QueueDir (Join-Path $TestDrive 'missing') } | Should -Throw
    }
}
