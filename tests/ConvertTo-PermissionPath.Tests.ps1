BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' 'src' 'SwitchAccounts.psd1') -Force
}

Describe 'ConvertTo-PermissionPath' {
    It 'turns a Windows path into an absolute POSIX rule path' -Skip:(-not $IsWindows) {
        ConvertTo-PermissionPath -Path 'C:\Users\me\.claude' | Should -Be '//c/Users/me/.claude/**'
    }

    It 'turns a Unix path into an absolute rule path' -Skip:($IsWindows) {
        ConvertTo-PermissionPath -Path '/home/me/.claude' | Should -Be '//home/me/.claude/**'
    }

    It 'drops a trailing separator' {
        $p = if ($IsWindows) { 'C:\x\' } else { '/x/' }
        ConvertTo-PermissionPath -Path $p | Should -BeLike '//*x/**'
    }
}
