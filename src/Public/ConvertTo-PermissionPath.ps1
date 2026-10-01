function ConvertTo-PermissionPath {
    <#
    .SYNOPSIS
        Turns a folder path into an absolute Claude Code permission pattern covering everything in it.
    .DESCRIPTION
        Permission rules use POSIX paths; "//" anchors at the filesystem root and Windows drives
        become "/c/...". Example: C:\Users\me\.claude -> //c/Users/me/.claude/**
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] [string] $Path)
    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    if ($full -match '^(?<drive>[A-Za-z]):(?<rest>.*)$') {
        $full = '/' + $Matches['drive'].ToLowerInvariant() + ($Matches['rest'] -replace '\\', '/')
    }
    "/$full/**"
}
