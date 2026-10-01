function Resolve-ExecutablePath {
    param([Parameter(Mandatory)] [string] $FilePath)
    $command = Get-Command -Name $FilePath -CommandType Application, ExternalScript -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $command) { throw "Executable not found: $FilePath" }
    $command.Source
}

function New-ProcessStartInfo {
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [string[]] $ArgumentList = @(),
        [hashtable] $Environment = @{},
        [string] $WorkingDirectory
    )
    $resolved = Resolve-ExecutablePath -FilePath $FilePath
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    if ($resolved -like '*.ps1') {
        # Test doubles are PowerShell scripts; run them with the current pwsh.
        $psi.FileName = (Get-Process -Id $PID).Path
        foreach ($a in @('-NoProfile', '-NonInteractive', '-File', $resolved)) { $psi.ArgumentList.Add($a) }
    } else {
        $psi.FileName = $resolved
    }
    foreach ($a in $ArgumentList) { $psi.ArgumentList.Add($a) }
    foreach ($key in $Environment.Keys) {
        if ($null -eq $Environment[$key]) { [void]$psi.Environment.Remove($key) }
        else { $psi.Environment[$key] = [string]$Environment[$key] }
    }
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $psi
}

function Invoke-ExternalCommand {
    <#
    .SYNOPSIS
        Runs a program with a timeout and returns exit code, stdout and stderr.
        On timeout the whole process tree is killed and TimedOut is $true.
    #>
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [string[]] $ArgumentList = @(),
        [hashtable] $Environment = @{},
        [string] $WorkingDirectory,
        [ValidateRange(1, 86400)] [int] $TimeoutSeconds = 60
    )
    $psi = New-ProcessStartInfo -FilePath $FilePath -ArgumentList $ArgumentList `
        -Environment $Environment -WorkingDirectory $WorkingDirectory
    $process = [System.Diagnostics.Process]::Start($psi)
    try {
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $timedOut = -not $process.WaitForExit($TimeoutSeconds * 1000)
        if ($timedOut) {
            $process.Kill($true)
        }
        $process.WaitForExit()
        [pscustomobject]@{
            ExitCode = if ($timedOut) { $null } else { $process.ExitCode }
            StdOut   = $stdout.GetAwaiter().GetResult()
            StdErr   = $stderr.GetAwaiter().GetResult()
            TimedOut = $timedOut
        }
    } finally {
        $process.Dispose()
    }
}
