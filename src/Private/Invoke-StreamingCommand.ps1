function Invoke-StreamingCommand {
    <#
    .SYNOPSIS
        Runs a program, writes StdIn to it, and hands each stdout line to OnLine as it arrives.
    .DESCRIPTION
        OnLine returns a non-empty string to stop the run (the string becomes StoppedBy); the
        process tree is then killed. Passing the timeout also kills it (StoppedBy = Timeout).
    #>
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [string[]] $ArgumentList = @(),
        [hashtable] $Environment = @{},
        [string] $WorkingDirectory,
        [string] $StdIn = '',
        [Parameter(Mandatory)] [double] $TimeoutSeconds,
        [scriptblock] $OnLine = { param($line) $null }
    )
    $psi = New-ProcessStartInfo -FilePath $FilePath -ArgumentList $ArgumentList `
        -Environment $Environment -WorkingDirectory $WorkingDirectory
    $process = [System.Diagnostics.Process]::Start($psi)
    $lines = [System.Collections.Generic.List[string]]::new()
    $stoppedBy = $null
    try {
        $process.StandardInput.Write($StdIn)
        $process.StandardInput.Close()
        $stderr = $process.StandardError.ReadToEndAsync()
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
        while (-not $stoppedBy) {
            $read = $process.StandardOutput.ReadLineAsync()
            while (-not $read.Wait(200)) {
                if ([DateTime]::UtcNow -ge $deadline) { $stoppedBy = 'Timeout'; break }
            }
            if ($stoppedBy) { break }
            $line = $read.GetAwaiter().GetResult()
            if ($null -eq $line) { break }
            $lines.Add($line)
            $stop = & $OnLine $line
            if ($stop) { $stoppedBy = [string]$stop }
        }
        if ($stoppedBy) {
            try { $process.Kill($true) } catch { Write-Verbose "Kill failed: $($_.Exception.Message)" }
        }
        $process.WaitForExit()
        [pscustomobject]@{
            ExitCode  = if ($stoppedBy) { $null } else { $process.ExitCode }
            Lines     = $lines.ToArray()
            StdErr    = $stderr.GetAwaiter().GetResult()
            StoppedBy = $stoppedBy
        }
    } finally {
        $process.Dispose()
    }
}
