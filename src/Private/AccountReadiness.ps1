# Can an account open a session in a folder without a person at the keyboard?
# Only two facts are read from the account's .claude.json: hasCompletedOnboarding and the
# trust mark of folders. Nothing else is read, kept or printed.

function Get-AccountGlobalConfigPath {
    <# .claude.json of an account: ~/.claude.json for the default dir, otherwise inside the dir. #>
    param([Parameter(Mandatory)] [string] $ConfigDir, [Parameter(Mandatory)] [bool] $IsDefault)
    if ($IsDefault) { Join-Path $HOME '.claude.json' } else { Join-Path $ConfigDir '.claude.json' }
}

function Get-AccountOnboardingState {
    <#
      Ready | FirstRun (no file, or theme/login not done) | Untrusted (folder not accepted yet) |
      Unknown (file unreadable). A folder is trusted when it or a parent folder is marked.
      Read with System.Text.Json: names that differ only in case are legal there, and nothing
      but the two facts above is looked at.
    #>
    param([Parameter(Mandatory)] [string] $GlobalConfigPath, [Parameter(Mandatory)] [string] $WorkingDirectory)
    if (-not (Test-Path -LiteralPath $GlobalConfigPath -PathType Leaf)) { return 'FirstRun' }
    try { $document = [System.Text.Json.JsonDocument]::Parse([IO.File]::ReadAllText($GlobalConfigPath)) }
    catch { return 'Unknown' }
    try {
        $trusted = Get-TrustedProjectPath -Root $document.RootElement
        if ($null -eq $trusted) { return 'FirstRun' }
    } finally {
        $document.Dispose()
    }
    $dir = [IO.Path]::GetFullPath((Resolve-HomePath $WorkingDirectory))
    while ($dir) {
        if ($trusted -contains (ConvertTo-ComparablePath $dir)) { return 'Ready' }
        $dir = [IO.Path]::GetDirectoryName($dir)
    }
    'Untrusted'
}

function Get-TrustedProjectPath {
    <# Comparable paths of the trusted folders; $null when first start is not completed. #>
    param([Parameter(Mandatory)] [System.Text.Json.JsonElement] $Root)
    $value = [System.Text.Json.JsonElement]::new()
    if ($Root.ValueKind -ne 'Object' -or -not $Root.TryGetProperty('hasCompletedOnboarding', [ref]$value) -or $value.ValueKind -ne 'True') {
        return $null
    }
    $paths = [System.Collections.Generic.List[string]]::new()
    $projects = [System.Text.Json.JsonElement]::new()
    if (-not $Root.TryGetProperty('projects', [ref]$projects) -or $projects.ValueKind -ne 'Object') { return , $paths.ToArray() }
    foreach ($project in $projects.EnumerateObject()) {
        $flag = [System.Text.Json.JsonElement]::new()
        if ($project.Value.ValueKind -eq 'Object' -and $project.Value.TryGetProperty('hasTrustDialogAccepted', [ref]$flag) -and $flag.ValueKind -eq 'True') {
            try { $paths.Add((ConvertTo-ComparablePath $project.Name)) } catch { Write-Verbose "skipped project key: $($_.Exception.Message)" }
        }
    }
    , $paths.ToArray()
}
function Get-AccountReadiness {
    <# Ready | Missing (config dir absent) | FirstRun | Untrusted | Unknown, for one config entry. #>
    param([Parameter(Mandatory)] $Account, [Parameter(Mandatory)] [string] $WorkingDirectory)
    if (-not (Test-Path -LiteralPath $Account.ConfigDir -PathType Container)) { return 'Missing' }
    $global = Get-AccountGlobalConfigPath -ConfigDir $Account.ConfigDir -IsDefault $Account.IsDefaultConfigDir
    Get-AccountOnboardingState -GlobalConfigPath $global -WorkingDirectory $WorkingDirectory
}

function Get-NotReadyAdvice {
    <# What is missing and what the user can do about it. #>
    param([Parameter(Mandatory)] $Account, [Parameter(Mandatory)] [string] $State, [Parameter(Mandatory)] [string] $Directory)
    $login = if ($Account.IsDefaultConfigDir) { 'claude' } else { "`$env:CLAUDE_CONFIG_DIR = '$($Account.ConfigDir)'; claude" }
    switch ($State) {
        'Missing' { "config dir $($Account.ConfigDir) does not exist. Log in once: $login auth login" }
        'FirstRun' { "first start not finished (theme, login). Run once by hand: $login" }
        'Untrusted' { "folder $Directory is not trusted yet; the tab would stop at the trust question. Open it once by hand, or repeat with -TrustDirectory." }
        default { "its .claude.json could not be read, so readiness is unknown." }
    }
}

function Test-BroadTrustTarget {
    <# Folders that must never be marked as trusted: roots, the home folder and its parents, system folders, config dirs. #>
    param([Parameter(Mandatory)] [string] $Path, [string[]] $ProtectedPaths = @())
    if ([IO.Path]::GetPathRoot($Path) -eq [IO.Path]::GetFullPath($Path)) { return $true }
    $homeDir = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($HOME))
    $inside = {
        param($child, $parent)
        $p = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($parent))
        (Test-SamePath $child $p) -or $child.StartsWith($p + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -or
        $child.StartsWith($p + [IO.Path]::AltDirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
    }
    if ((& $inside $homeDir $Path)) { return $true }
    $system = if ($IsWindows) { @($env:windir, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData) }
    else { @('/usr', '/etc', '/bin', '/sbin', '/boot', '/proc', '/sys') }
    $protected = @($system) + @($ProtectedPaths) + @(Join-Path $homeDir '.claude')
    foreach ($folder in $protected) {
        if ($folder -and (& $inside $Path $folder)) { return $true }
    }
    $false
}

function Set-DirectoryTrust {
    <#
      Marks a folder as trusted in the account's .claude.json (hasTrustDialogAccepted). Only for an
      explicit -TrustDirectory. A trusted folder runs its own hooks, MCP servers and settings, so
      drive roots, the home folder and config dirs are refused. The file is edited as a JSON tree
      so that every other value stays as it was, a backup is kept, and the swap is atomic.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)] [string] $GlobalConfigPath,
        [Parameter(Mandatory)] [string] $Directory,
        [string[]] $ProtectedPaths = @()
    )

    $full = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($Directory))
    if (Test-BroadTrustTarget -Path $full -ProtectedPaths $ProtectedPaths) {
        Stop-WithSwitchError InvalidArgument "-TrustDirectory refuses '$full' (a drive root, the home folder or a parent of it, a system folder, or a config dir). Use the project folder."
    }
    if (-not (Test-Path -LiteralPath $GlobalConfigPath -PathType Leaf)) {
        Stop-WithSwitchError NotReady "Cannot trust a folder: $GlobalConfigPath does not exist (first start not finished)."
    }
    if (-not $PSCmdlet.ShouldProcess($GlobalConfigPath, "Mark $full as trusted")) { return $false }

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $before = Get-Item -LiteralPath $GlobalConfigPath -Force
        try { $root = [System.Text.Json.Nodes.JsonNode]::Parse([IO.File]::ReadAllText($GlobalConfigPath)) }
        catch { Stop-WithSwitchError Environment "Cannot trust a folder: $GlobalConfigPath could not be parsed ($(Get-ShortText $_.Exception.Message 120))." }
        if ($root -isnot [System.Text.Json.Nodes.JsonObject] -or $root['hasCompletedOnboarding']?.ToJsonString() -ne 'true') {
            Stop-WithSwitchError NotReady 'Cannot trust a folder: the first start of this account is not finished.'
        }
        if ($root['projects'] -isnot [System.Text.Json.Nodes.JsonObject]) { $root['projects'] = [System.Text.Json.Nodes.JsonObject]::new() }
        $projects = $root['projects']
        $wanted = ConvertTo-ComparablePath $full
        $key = $projects | ForEach-Object { $_.Key } | Where-Object { try { (ConvertTo-ComparablePath $_) -eq $wanted } catch { $false } } | Select-Object -First 1
        if (-not $key) { $key = $full; $projects[$key] = [System.Text.Json.Nodes.JsonObject]::new() }
        if ($projects[$key] -isnot [System.Text.Json.Nodes.JsonObject]) { $projects[$key] = [System.Text.Json.Nodes.JsonObject]::new() }
        $projects[$key]['hasTrustDialogAccepted'] = [System.Text.Json.Nodes.JsonValue]::Create($true)

        $options = [System.Text.Json.JsonSerializerOptions]::new()
        $options.WriteIndented = $true
        $options.Encoder = [System.Text.Encodings.Web.JavaScriptEncoder]::UnsafeRelaxedJsonEscaping
        $temp = "$GlobalConfigPath.$PID.tmp"
        [IO.File]::WriteAllText($temp, $root.ToJsonString($options), [System.Text.UTF8Encoding]::new($false))
        if (-not $IsWindows) { [IO.File]::SetUnixFileMode($temp, [IO.File]::GetUnixFileMode($GlobalConfigPath)) }
        $after = Get-Item -LiteralPath $GlobalConfigPath -Force
        if ($after.LastWriteTimeUtc -ne $before.LastWriteTimeUtc -or $after.Length -ne $before.Length) {
            # A running session wrote the file meanwhile; read it again instead of overwriting.
            Remove-Item -LiteralPath $temp -Force
            continue
        }
        $backup = "$GlobalConfigPath.switch-backup"
        if ($IsWindows) {
            # Replace swaps in one step and keeps the file it replaced as the backup (same ACL).
            [IO.File]::Replace($temp, $GlobalConfigPath, $backup)
        } else {
            # File.Replace is not dependable on Unix; a rename over the target is atomic there.
            [IO.File]::Copy($GlobalConfigPath, $backup, $true)
            [IO.File]::SetUnixFileMode($backup, [IO.File]::GetUnixFileMode($GlobalConfigPath))
            [IO.File]::Move($temp, $GlobalConfigPath, $true)
        }
        return $true
    }
    Stop-WithSwitchError Environment "Cannot trust a folder: $GlobalConfigPath keeps changing (a session is writing it). Try again."
}
