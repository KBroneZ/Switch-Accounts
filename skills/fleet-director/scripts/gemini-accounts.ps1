# Several Google accounts for Gemini (Antigravity's `agy`), switched with aisw (github.com/burakdede/aisw).
# Dot-sourced by ask-gemini.ps1 and gemini-usage.ps1; defines functions only.
#
# agy keeps ONE Google sign-in per Windows user (in the OS keyring), so "an account" here means
# "an aisw profile made live before agy starts". Only one account is live at a time; a running agy
# keeps the account it started with. Everything that switches runs under one lock (gemini.lock),
# checks the switch before agy starts, never falls back to another account, and puts the default
# account back afterwards so a manual `agy` stays predictable.
#
# Config: ~/.claude-switch/gemini-accounts.json. Without that file nothing here is used and agy
# runs with whatever account is live (the single-account behaviour).

$script:GeminiNamePattern = '^[A-Za-z0-9][A-Za-z0-9._-]{0,29}$'
$script:AiswTimeoutSeconds = 60
# A reading this old is read again before `-Account auto` trusts it.
$script:GeminiAutoMaxAgeHours = 6

function Stop-GeminiAccount {
    <# Throws an error carrying the exit code the calling script should use. #>
    param([Parameter(Mandatory)] [int] $Code, [Parameter(Mandatory)] [string] $Message)
    $err = [System.InvalidOperationException]::new($Message)
    $err.Data['GeminiExitCode'] = $Code
    throw $err
}

function Get-GeminiExitCode {
    param([Parameter(Mandatory)] $ErrorRecord, [int] $Default = 3)
    $exception = $ErrorRecord.Exception
    if ($exception.Data.Contains('GeminiExitCode')) { return [int]$exception.Data['GeminiExitCode'] }
    $Default
}

function Get-GeminiDataDir {
    Join-Path $HOME '.claude-switch'
}

function Get-GeminiAccountConfig {
    <#
    .SYNOPSIS
        The Google accounts declared in gemini-accounts.json, or $null when the file does not exist.
    .DESCRIPTION
        { "aiswPath": null, "defaultAccount": "G1",
          "accounts": [ { "name": "G1", "profile": "g1", "label": "main" }, ... ] }
        Throws (exit code 1) on an invalid file: every account needs a unique name and an aisw
        profile; defaultAccount (default: the first) must be one of them.
    #>
    param([string] $Path = (Join-Path (Get-GeminiDataDir) 'gemini-accounts.json'))
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { $raw = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop }
    catch { Stop-GeminiAccount 1 "${Path}: not valid JSON ($($_.Exception.Message))" }
    $list = @($raw.accounts)
    if ($list.Count -eq 0) { Stop-GeminiAccount 1 "${Path}: needs an `"accounts`" list with at least one account" }
    $accounts = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $list) {
        $n = $accounts.Count + 1
        $name = $item.name
        $profile = $item.profile
        if ($name -isnot [string] -or $name -notmatch $script:GeminiNamePattern) { Stop-GeminiAccount 1 "${Path}: account #$n needs a `"name`" of 1-30 letters, digits, . _ -" }
        if ($name -ieq 'auto') { Stop-GeminiAccount 1 "${Path}: `"auto`" cannot be an account name" }
        if ($profile -isnot [string] -or $profile -notmatch $script:GeminiNamePattern) { Stop-GeminiAccount 1 "${Path}: account $name needs an aisw `"profile`" of 1-30 letters, digits, . _ -" }
        if ($accounts | Where-Object { $_.Name -ieq $name }) { Stop-GeminiAccount 1 "${Path}: the account name $name is used twice" }
        if ($accounts | Where-Object { $_.Profile -ceq $profile }) { Stop-GeminiAccount 1 "${Path}: the aisw profile $profile is used by two accounts" }
        $label = if ($item.label -is [string]) { ($item.label -replace '[\x00-\x1f\x7f]', ' ').Trim() } else { '' }
        if ($label.Length -gt 40) { Stop-GeminiAccount 1 "${Path}: the label of $name is longer than 40 characters" }
        $accounts.Add([pscustomobject]@{ Name = $name; Profile = $profile; Label = $label })
    }
    $defaultName = if ($raw.defaultAccount -is [string] -and $raw.defaultAccount) { $raw.defaultAccount } else { $accounts[0].Name }
    $default = $accounts | Where-Object { $_.Name -ieq $defaultName } | Select-Object -First 1
    if (-not $default) { Stop-GeminiAccount 1 "${Path}: defaultAccount $defaultName is not one of the accounts" }
    $aisw = if ($raw.aiswPath -is [string] -and $raw.aiswPath.Trim()) { $raw.aiswPath.Trim() } else { $null }
    [pscustomobject]@{ Path = $Path; Accounts = $accounts.ToArray(); Default = $default; AiswPath = $aisw }
}

function Resolve-GeminiAccount {
    <# The named account (case-insensitive), or an exit-1 error that lists the known names. #>
    param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)] [string] $Name)
    $found = $Config.Accounts | Where-Object { $_.Name -ieq $Name } | Select-Object -First 1
    if (-not $found) { Stop-GeminiAccount 1 "Unknown Google account: $Name (known: $($Config.Accounts.Name -join ', '), or auto)." }
    $found
}

function Find-Aisw {
    <#
    aisw.exe: the -Override, else the config's aiswPath (whichever is set is the only one tried: a wrong
    path is "aisw missing", never a different aisw), else ~/.aisw/bin, else PATH. $null when none exists.
    #>
    param([string] $Override, $Config)
    $exe = if ($IsWindows) { 'aisw.exe' } else { 'aisw' }
    $given = if ($Override) { $Override } else { $Config.AiswPath }
    if ($given) { return $(if (Test-Path -LiteralPath $given -PathType Leaf) { $given } else { $null }) }
    $userAisw = Join-Path $HOME '.aisw' 'bin' $exe
    if (Test-Path -LiteralPath $userAisw -PathType Leaf) { return $userAisw }
    (Get-Command aisw -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
}

function Invoke-GeminiTool {
    <# Runs a program with stdin closed and a timeout; agy's folder is put first on PATH for aisw. #>
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [string[]] $Arguments = @(),
        [string] $PathPrefix,
        [int] $TimeoutSeconds = $script:AiswTimeoutSeconds
    )
    $info = [System.Diagnostics.ProcessStartInfo]::new($FilePath)
    foreach ($a in $Arguments) { $info.ArgumentList.Add($a) }
    if ($PathPrefix) { $info.Environment['PATH'] = "$PathPrefix$([IO.Path]::PathSeparator)$($info.Environment['PATH'])" }
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.RedirectStandardInput = $true
    $process = [System.Diagnostics.Process]::Start($info)
    $process.StandardInput.Close()
    $out = $process.StandardOutput.ReadToEndAsync()
    $err = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        $process.Kill($true)
        return [pscustomobject]@{ ExitCode = -1; Output = "timed out after $TimeoutSeconds s"; TimedOut = $true }
    }
    $process.WaitForExit()
    [pscustomobject]@{ ExitCode = $process.ExitCode; Output = ($out.GetAwaiter().GetResult() + "`n" + $err.GetAwaiter().GetResult()).Trim(); TimedOut = $false }
}

function Get-AiswLiveProfile {
    <# The profile aisw says is live for Antigravity, or throws. Used to check every switch. #>
    param([Parameter(Mandatory)] [string] $Aisw, [string] $AgyDir)
    $r = Invoke-GeminiTool -FilePath $Aisw -Arguments @('status', '--tool', 'antigravity', '--json', '--non-interactive', '--no-color') -PathPrefix $AgyDir
    if ($r.ExitCode -ne 0) { Stop-GeminiAccount 6 "aisw status failed (exit $($r.ExitCode)): $(Limit-GeminiText $r.Output)" }
    try { $status = @($r.Output | ConvertFrom-Json -ErrorAction Stop) }
    catch { Stop-GeminiAccount 6 "aisw status did not answer JSON: $(Limit-GeminiText $r.Output)" }
    $row = $status | Where-Object { $_.tool -eq 'agy' } | Select-Object -First 1
    if (-not $row) { $row = $status | Select-Object -First 1 }
    if (-not $row -or -not $row.active_profile) { Stop-GeminiAccount 6 'aisw reports no live Antigravity profile.' }
    if ($row.active_profile_applied -eq $false) { Stop-GeminiAccount 6 "aisw: the live Antigravity sign-in does not match profile $($row.active_profile)." }
    [string]$row.active_profile
}

function Get-AiswError {
    <# aisw --json prints {"error":{"message":...}}: that message, else the plain output. #>
    param([string] $Output)
    try {
        $message = ($Output | ConvertFrom-Json -ErrorAction Stop).error.message
        if ($message) { return (Limit-GeminiText (($message -split "`n")[0])) }
    } catch { }
    Limit-GeminiText $Output
}

function Switch-GeminiAccount {
    <#
    .SYNOPSIS
        Makes the account's aisw profile live and checks it. Throws (exit 6) on any failure; never tries another account.
    #>
    param([Parameter(Mandatory)] $Account, [Parameter(Mandatory)] [string] $Aisw, [string] $AgyDir)
    $r = Invoke-GeminiTool -FilePath $Aisw -Arguments @('use', 'antigravity', $Account.Profile, '--json', '--non-interactive', '--no-color') -PathPrefix $AgyDir
    if ($r.ExitCode -ne 0) {
        Stop-GeminiAccount 6 "Google account $($Account.Name) is unavailable: 'aisw use antigravity $($Account.Profile)' failed (exit $($r.ExitCode)): $(Get-AiswError $r.Output)"
    }
    $live = Get-AiswLiveProfile -Aisw $Aisw -AgyDir $AgyDir
    if ($live -cne $Account.Profile) {
        Stop-GeminiAccount 6 "Google account $($Account.Name) is unavailable: after the switch aisw reports $live live, not $($Account.Profile)."
    }
}

function Limit-GeminiText {
    <# One short plain line: no escapes, no control characters, no token-looking values. #>
    param([string] $Text, [int] $Length = 300)
    $clean = ($Text -replace '\x1b\[[0-9;]*[A-Za-z]', '' -replace '[\x00-\x1f\x7f]+', ' ').Trim()
    $clean = $clean -replace '(?i)(bearer\s+)[A-Za-z0-9\-._~+/]{8,}=*', '$1***' -replace '(sk-|AIza|ghp_|xox[abprs]-)[A-Za-z0-9_\-]{8,}', '$1***'
    if ($clean.Length -gt $Length) { $clean = $clean.Substring($clean.Length - $Length) }
    $clean
}

function Enter-GeminiLock {
    <#
    .SYNOPSIS
        Takes gemini.lock exclusively (an open file handle: the OS frees it if the process dies).
    .DESCRIPTION
        Waits up to -WaitSeconds for another run to finish. Throws exit 4 when it stays busy.
        Pass the returned handle to Exit-GeminiLock.
    #>
    param([string] $Path = (Join-Path (Get-GeminiDataDir) 'gemini.lock'), [int] $WaitSeconds = 0)
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    $deadline = [DateTime]::UtcNow.AddSeconds($WaitSeconds)
    while ($true) {
        try {
            $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            $stream.SetLength(0)
            $note = [System.Text.Encoding]::UTF8.GetBytes("pid $PID at $([DateTime]::UtcNow.ToString('o'))")
            $stream.Write($note, 0, $note.Length)
            $stream.Flush()
            return $stream
        } catch [System.IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) { Stop-GeminiAccount 4 'Another Gemini run holds the account lock (gemini.lock); try again when it finishes.' }
            Start-Sleep -Milliseconds 500
        }
    }
}

function Exit-GeminiLock {
    param($Lock)
    if ($Lock) { $Lock.Dispose() }
}

function Restore-GeminiDefaultAccount {
    <# Puts the default account back. Returns $null, or the warning to show when that did not work (it never throws). #>
    param([Parameter(Mandatory)] $Config, [Parameter(Mandatory)] [string] $Aisw, [string] $AgyDir)
    try {
        Switch-GeminiAccount -Account $Config.Default -Aisw $Aisw -AgyDir $AgyDir
        $null
    } catch {
        "Could not put the default Google account back ($($_.Exception.Message)). Run: aisw use antigravity $($Config.Default.Profile)"
    }
}

# --- usage per account ---------------------------------------------------------------------

function Get-GeminiUsagePath {
    param([Parameter(Mandatory)] [string] $DataDir, [Parameter(Mandatory)] [string] $Name, [switch] $ErrorFile)
    Join-Path $DataDir $(if ($ErrorFile) { "gemini-error-$Name.txt" } else { "gemini-usage-$Name.json" })
}

function Get-AgyWindowLabel([string] $Group) {
    $short = ($Group -replace '\s*models?\s*$', '' -replace '\s+and\s+', '/' -replace '[^A-Za-z0-9/.-]', '')
    if ($short.Length -gt 12) { $short = $short.Substring(0, 12) }
    if ($short) { $short } else { '?' }
}

function ConvertFrom-AgyUsage {
    <#
    .SYNOPSIS
        The windows in what `agy -p /usage --output-format json` printed, or $null when it is not a usage answer.
    .DESCRIPTION
        One object per bucket: Group (`Gemini`, `Claude/GPT`), Window (hourly/daily/weekly/monthly),
        Pct (used, 0-100; $null once its reset has passed: unknown until read again) and ResetsAt.
    #>
    param([string] $Text, [DateTimeOffset] $Now = [DateTimeOffset]::UtcNow)
    $lines = @($Text -split "`r?`n")
    $answer = $null
    foreach ($candidate in @($Text.Trim(), ($lines | Where-Object { $_.TrimStart().StartsWith('{') } | Select-Object -Last 1))) {
        if ($candidate -and $candidate.TrimStart().StartsWith('{')) {
            try { $answer = $candidate | ConvertFrom-Json -ErrorAction Stop; break } catch { }
        }
    }
    if (-not $answer -or $answer.status -ne 'SUCCESS' -or -not $answer.command.data.groups) { return $null }
    $windows = foreach ($group in @($answer.command.data.groups)) {
        if ($group.name -isnot [string]) { continue }
        foreach ($bucket in @($group.buckets)) {
            # ConvertFrom-Json gives a whole number (0, 1) as Int64, a fraction as Double.
            if ($bucket.remaining_fraction -isnot [double] -and $bucket.remaining_fraction -isnot [long] -and $bucket.remaining_fraction -isnot [int]) { continue }
            $reset = $null
            if ($bucket.reset_time -is [string] -or $bucket.reset_time -is [datetime]) {
                $parsed = [DateTimeOffset]::MinValue
                if ([DateTimeOffset]::TryParse([string]$bucket.reset_time, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) { $reset = $parsed }
            }
            # Antigravity prints 1970-01-01 for a window that has not started (nothing used yet): known, with no reset.
            if ($reset -and $reset.Year -lt 2000) { $reset = $null }
            $isPast = $reset -and $reset -le $Now
            $used = [math]::Round([math]::Max([double]0, [math]::Min([double]1, 1 - [double]$bucket.remaining_fraction)) * 100, 1)
            [pscustomobject]@{
                Group    = Get-AgyWindowLabel $group.name
                Window   = [string]$bucket.window
                Pct      = if ($isPast) { $null } else { $used }
                ResetsAt = if ($isPast -or -not $reset) { $null } else { $reset }
            }
        }
    }
    $windows = @($windows)
    if ($windows.Count -eq 0) { return $null }
    $windows
}

function Get-GeminiModelGroup {
    <# Which usage group a model draws from: gemini-* is `Gemini`; claude-* and gpt-oss-* are `Claude/GPT`. #>
    param([Parameter(Mandatory)] [string] $Model)
    if ($Model -like 'gemini*') { 'gemini' } else { 'other' }
}

function Read-GeminiUsage {
    <#
    .SYNOPSIS
        What is known about one account's room for a model: Room (percent left, $null = unknown), ReadAt, Resets.
    .DESCRIPTION
        Unknown is never 0 % used: no file, an answer that does not parse, a window of the model's
        group whose reset has passed, or no window for that group all give Room = $null.
    #>
    param([Parameter(Mandatory)] [string] $DataDir, [Parameter(Mandatory)] $Account, [Parameter(Mandatory)] [string] $Model, [DateTimeOffset] $Now = [DateTimeOffset]::UtcNow)
    $path = Get-GeminiUsagePath -DataDir $DataDir -Name $Account.Name
    $unknown = { param($why) [pscustomobject]@{ Account = $Account; Room = $null; ReadAt = $null; ResetsAt = $null; Why = $why } }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return (& $unknown 'never read') }
    $readAt = [DateTimeOffset](Get-Item -LiteralPath $path).LastWriteTimeUtc
    $windows = ConvertFrom-AgyUsage -Text (Get-Content -LiteralPath $path -Raw) -Now $Now
    if (-not $windows) { return (& $unknown 'unreadable answer') }
    $wanted = Get-GeminiModelGroup $Model
    $mine = @($windows | Where-Object { (($_.Group -like 'Gemini*') -eq ($wanted -eq 'gemini')) })
    if ($mine.Count -eq 0) { return (& $unknown "no window for $Model") }
    $result = [pscustomobject]@{ Account = $Account; Room = $null; ReadAt = $readAt; ResetsAt = $null; Why = '' }
    if ($mine | Where-Object { $null -eq $_.Pct }) { $result.Why = 'a window reset since the last read'; return $result }
    $result.Room = [math]::Round(100 - ($mine | Measure-Object -Property Pct -Maximum).Maximum, 1)
    $result.ResetsAt = ($mine | Where-Object { $_.ResetsAt } | Sort-Object ResetsAt | Select-Object -First 1).ResetsAt
    $result
}

function Select-GeminiAccount {
    <#
    .SYNOPSIS
        The account with the most room among readings, or $null when none has known room left.
    .DESCRIPTION
        Ties go to the account listed first. An account with unknown room or none left is never picked.
    #>
    param([Parameter(Mandatory)] [object[]] $Readings)
    $Readings | Where-Object { $null -ne $_.Room -and $_.Room -gt 0 } | Sort-Object -Property @{ Expression = 'Room'; Descending = $true }, @{ Expression = { [array]::IndexOf($Readings, $_) } } | Select-Object -First 1
}

function Update-GeminiUsage {
    <#
    .SYNOPSIS
        Asks agy for /usage in the account that is live now and keeps the answer in that account's usage file.
    .DESCRIPTION
        Call it under the lock after the switch. A failed run keeps the last answer and writes why to the
        account's error file; a good run clears it. Returns $true when the answer was kept.
    #>
    param([Parameter(Mandatory)] $Account, [Parameter(Mandatory)] [string] $AgyPath, [Parameter(Mandatory)] [string] $DataDir, [int] $TimeoutSeconds = 90)
    New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
    $usagePath = Get-GeminiUsagePath -DataDir $DataDir -Name $Account.Name
    $errorPath = Get-GeminiUsagePath -DataDir $DataDir -Name $Account.Name -ErrorFile
    $r = Invoke-GeminiTool -FilePath $AgyPath -Arguments @('-p', '/usage', '--output-format', 'json', '--print-timeout', '60s', '--log-file', (Join-Path $DataDir 'agy-usage.log')) -TimeoutSeconds $TimeoutSeconds
    if ($r.ExitCode -eq 0 -and (ConvertFrom-AgyUsage -Text $r.Output)) {
        $temp = "$usagePath.$PID.tmp"
        [System.IO.File]::WriteAllText($temp, $r.Output.Trim(), [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temp -Destination $usagePath -Force
        [System.IO.File]::WriteAllText($errorPath, '', [System.Text.UTF8Encoding]::new($false))
        return $true
    }
    $note = "agy /usage failed ($($r.ExitCode)): $(Limit-GeminiText $r.Output 100)"
    [System.IO.File]::WriteAllText($errorPath, $note, [System.Text.UTF8Encoding]::new($false))
    $false
}
