Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

foreach ($folder in 'Private', 'Public') {
    $path = Join-Path $PSScriptRoot $folder
    if (-not (Test-Path -LiteralPath $path)) { continue }
    foreach ($file in Get-ChildItem -LiteralPath $path -Filter '*.ps1' | Sort-Object Name) {
        . $file.FullName
    }
}

$public = Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'Public') -Filter '*.ps1' |
    ForEach-Object { $_.BaseName }
Export-ModuleMember -Function $public
