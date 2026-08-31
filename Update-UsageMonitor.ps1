#Requires -Version 5.1
<#
.SYNOPSIS
    Updates UsageMonitorForClaude.exe to the latest GitHub release and restarts it.

.DESCRIPTION
    Steps:
      1. Reads the latest release of the given GitHub repository.
      2. Compares it with the version of the installed executable. If they match,
         asks whether to re-download and re-apply it anyway.
      3. Prints the release notes (changelog) of the new version.
      4. Closes every running instance of the executable.
      5. Downloads the matching asset for the current CPU architecture, verifies it
         (SHA-256 digest published by GitHub and/or Authenticode signature), then
         moves it over the installed copy.
      6. Restarts the main instance plus any additional instances defined by
         "<exe-name> - *.lnk" shortcuts sitting next to the executable.

    The changelog stays readable while the download runs: the progress indicator is a
    single line redrawn in place below the text, instead of Write-Progress, which
    Windows PowerShell renders as a banner over the top of the console.

.PARAMETER Repo
    GitHub repository in "owner/name" form. Defaults to the Usage Monitor for Claude
    repository.

.PARAMETER InstallDir
    Folder holding the executable. Defaults to the folder containing this script.

.PARAMETER ExeName
    File name of the executable to update. Defaults to UsageMonitorForClaude.exe.

.PARAMETER Force
    Reinstall even when the installed version already matches the latest release,
    without asking for confirmation.

.PARAMETER SkipChangelog
    Do not print the release notes.

.PARAMETER NonInteractive
    Never prompt. Questions resolve to their default answer (usually "no"), which makes
    the script safe to run from Task Scheduler or CI.

.PARAMETER SkipSignatureCheck
    Skip the Authenticode signature check on the downloaded file. The SHA-256 digest
    check still runs. Rarely needed: an unsigned file whose digest matches is already
    accepted without prompting.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Update-UsageMonitor.ps1

.EXAMPLE
    .\Update-UsageMonitor.ps1 -InstallDir 'C:\Tools\UsageMonitor' -NonInteractive

.NOTES
    Windows only. Requires Windows PowerShell 5.1 or PowerShell 7+ on Windows.

    Exit codes:
      0  success (updated, or already up to date and nothing to do)
      1  unexpected error
      2  unsupported platform or bad configuration
      3  network / GitHub API problem (including rate limiting)
      4  integrity verification of the downloaded file failed
      5  the installed file could not be replaced (locked or not writable)

    This script is not affiliated with the author of Usage Monitor for Claude, nor
    with Anthropic. See README.md.
#>

[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [ValidatePattern('^[\w.-]+/[\w.-]+$')]
    [string] $Repo = 'jens-duttke/usage-monitor-for-claude',

    [string] $InstallDir,

    [ValidatePattern('\.exe$')]
    [string] $ExeName = 'UsageMonitorForClaude.exe',

    [switch] $Force,
    [switch] $SkipChangelog,
    [switch] $NonInteractive,
    [switch] $SkipSignatureCheck
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # keep the built-in banner off the changelog

#region ------------------------------------------------------------- constants

# Exit codes, also documented in the comment-based help above.
$Script:ExitOk           = 0
$Script:ExitError        = 1
$Script:ExitPlatform     = 2
$Script:ExitNetwork      = 3
$Script:ExitVerification = 4
$Script:ExitReplace      = 5

$Script:UserAgent = 'update-usage-monitor-script'
$Script:ApiRoot   = 'https://api.github.com'

#endregion

#region -------------------------------------------------------------------- ui

function Write-Rule {
    param([string] $Title)

    $width = 64
    if ($Title) {
        $line = "-- $Title " + ('-' * [math]::Max(0, $width - $Title.Length - 4))
    }
    else {
        $line = '-' * $width
    }
    Write-Host $line -ForegroundColor DarkGray
}

function Write-Step {
    param([Parameter(Mandatory)][string] $Message)
    Write-Host '==> ' -ForegroundColor Cyan -NoNewline
    Write-Host $Message
}

function Write-Detail {
    param(
        [Parameter(Mandatory)][string] $Message,
        [ConsoleColor] $Color = [ConsoleColor]::DarkGray
    )
    Write-Host "    $Message" -ForegroundColor $Color
}

function Write-Ok   { param([string] $Message) Write-Host "[ok]   $Message" -ForegroundColor Green }
function Write-Warn { param([string] $Message) Write-Host "[!]    $Message" -ForegroundColor Yellow }
function Write-Fail { param([string] $Message) Write-Host "[x]    $Message" -ForegroundColor Red }

function Format-Size {
    param([Parameter(Mandatory)][double] $Bytes)

    if ($Bytes -ge 1MB) { return '{0:N1} MB' -f ($Bytes / 1MB) }
    if ($Bytes -ge 1KB) { return '{0:N0} KB' -f ($Bytes / 1KB) }
    return "$([int] $Bytes) B"
}

<#
    Yes/no prompt. With -NonInteractive, or when no console is attached, it answers
    with the default instead of blocking forever (Task Scheduler, CI, ...).
#>
function Read-YesNo {
    param(
        [Parameter(Mandatory)][string] $Question,
        [switch] $DefaultYes
    )

    $default = [bool] $DefaultYes
    $suffix  = if ($default) { '[Y/n]' } else { '[y/N]' }

    if ($NonInteractive -or -not [Environment]::UserInteractive) {
        Write-Warn "$Question $suffix -> non-interactive session, assuming '$(if ($default) { 'yes' } else { 'no' })'."
        return $default
    }

    while ($true) {
        Write-Host "?      $Question $suffix " -ForegroundColor Yellow -NoNewline
        $answer = (Read-Host).Trim().ToLowerInvariant()

        if ([string]::IsNullOrEmpty($answer))  { return $default }
        if ($answer -in @('y', 'yes'))         { return $true }
        if ($answer -in @('n', 'no'))          { return $false }

        Write-Detail "Please answer 'y' or 'n'." ([ConsoleColor]::DarkYellow)
    }
}

<#
    Prints the release notes with minimal markdown rendering. Called BEFORE the
    download starts; the progress indicator below is a single line redrawn in place,
    so this text stays on screen and readable for the whole download.
#>
function Show-Changelog {
    param([Parameter(Mandatory)] $Release)

    Write-Host ''
    Write-Rule "What's new in $($Release.tag_name)"

    if ([string]::IsNullOrWhiteSpace($Release.body)) {
        Write-Detail 'No release notes were published for this version.'
    }
    else {
        $inCodeBlock = $false

        foreach ($raw in ($Release.body -split "`r?`n")) {
            $line = $raw.TrimEnd()

            if ($line -match '^\s*```') {
                $inCodeBlock = -not $inCodeBlock
                continue
            }
            if ($inCodeBlock) {
                Write-Host "    $($line.TrimEnd())" -ForegroundColor DarkGreen
                continue
            }

            switch -Regex ($line) {
                '^\s*#{1,6}\s*(.+)$' {
                    Write-Host ''
                    Write-Host "  $($Matches[1].Trim())" -ForegroundColor Cyan
                    break
                }
                '^\s*[-*+]\s+(.+)$' {
                    Write-Host '  - ' -ForegroundColor DarkCyan -NoNewline
                    Write-Host $Matches[1].Trim()
                    break
                }
                '^\s*$' {
                    Write-Host ''
                    break
                }
                default {
                    Write-Host "  $($line.Trim())"
                }
            }
        }
    }

    if ($Release.html_url) {
        Write-Host ''
        Write-Detail "Full release page: $($Release.html_url)"
    }
    Write-Rule
    Write-Host ''
}

<#
    Single-line progress indicator, redrawn with a carriage return. Deliberately not
    Write-Progress: in Windows PowerShell that paints a banner across the top of the
    console and would hide the changelog printed just above.
#>
function Write-ProgressBar {
    param(
        [Parameter(Mandatory)][long] $Current,
        [long] $Total,
        [int]  $Width = 34
    )

    if ($Total -gt 0) {
        $ratio  = [math]::Min(1.0, $Current / $Total)
        $filled = [int][math]::Round($Width * $ratio)
        $bar    = ('#' * $filled).PadRight($Width, '.')
        $text   = '    [{0}] {1,3:N0}%  {2} / {3}' -f $bar, ($ratio * 100), (Format-Size $Current), (Format-Size $Total)
    }
    else {
        # No Content-Length header: show downloaded bytes only.
        $text = '    [{0}] {1} downloaded' -f ('.' * $Width), (Format-Size $Current)
    }

    Write-Host "`r$($text.PadRight(76))" -NoNewline -ForegroundColor DarkCyan
}

#endregion

#region --------------------------------------------------------- environment

function Test-Windows {
    # $IsWindows only exists in PowerShell 6+; 5.1 is Windows-only by definition.
    if ($PSVersionTable.PSVersion.Major -lt 6) { return $true }
    return [bool] $IsWindows
}

function Initialize-Tls {
    # Windows PowerShell defaults to SSL3/TLS1.0 on older systems, which GitHub rejects.
    try {
        $wanted = [Net.SecurityProtocolType]::Tls12
        if ([enum]::GetNames([Net.SecurityProtocolType]) -contains 'Tls13') {
            $wanted = $wanted -bor [Net.SecurityProtocolType]::Tls13
        }
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor $wanted
    }
    catch {
        Write-Warn "Could not raise the TLS version: $($_.Exception.Message)"
    }
}

function Test-DirectoryWritable {
    param([Parameter(Mandatory)][string] $Path)

    $probe = Join-Path $Path ".write-test-$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [System.IO.File]::WriteAllText($probe, 'x')
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue -WhatIf:$false
        return $true
    }
    catch {
        return $false
    }
}

function Test-Elevated {
    try {
        $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

#endregion

#region ------------------------------------------------------------- releases

<#
    Fetches the latest release, translating the GitHub failure modes people actually
    hit (rate limiting, no releases, no network) into readable messages.
#>
function Get-LatestRelease {
    param([Parameter(Mandatory)][string] $Repository)

    $uri = "$($Script:ApiRoot)/repos/$Repository/releases/latest"
    try {
        return Invoke-RestMethod -Uri $uri -Headers @{
            'User-Agent' = $Script:UserAgent
            'Accept'     = 'application/vnd.github+json'
        } -TimeoutSec 30
    }
    catch [System.Net.WebException] {
        $response = $_.Exception.Response
        $status   = if ($response) { [int] $response.StatusCode } else { 0 }

        switch ($status) {
            403 {
                $resetHeader = $response.Headers['X-RateLimit-Reset']
                $hint = 'GitHub rejected the request (HTTP 403).'
                if ($resetHeader) {
                    $reset   = [DateTimeOffset]::FromUnixTimeSeconds([long] $resetHeader).ToLocalTime()
                    $minutes = [math]::Max(1, [int]($reset - [DateTimeOffset]::Now).TotalMinutes)
                    $hint    = "GitHub API rate limit reached (60 requests/hour per IP). Try again in about $minutes minute(s), around $($reset.ToString('HH:mm'))."
                }
                throw [System.Exception]::new($hint, $_.Exception)
            }
            404 { throw [System.Exception]::new("Repository '$Repository' has no published release, or does not exist.", $_.Exception) }
            0   { throw [System.Exception]::new("Could not reach $($Script:ApiRoot). Check your internet connection or proxy settings.", $_.Exception) }
            default { throw [System.Exception]::new("GitHub returned HTTP $status for $uri.", $_.Exception) }
        }
    }
}

<#
    Picks the .exe asset matching this machine's CPU architecture. Releases that ship
    both x64 and arm64 builds would otherwise be installed at random.
#>
function Select-ReleaseAsset {
    param([Parameter(Mandatory)] $Release)

    $exeAssets = @($Release.assets | Where-Object { $_.name -like '*.exe' })
    if ($exeAssets.Count -eq 0) {
        throw "No .exe asset found in release $($Release.tag_name)."
    }
    if ($exeAssets.Count -eq 1) { return $exeAssets[0] }

    $arch = $env:PROCESSOR_ARCHITECTURE
    $patterns = switch ($arch) {
        'ARM64' { @('arm64', 'aarch64') }
        'AMD64' { @('x64', 'amd64', 'win64') }
        'x86'   { @('x86', 'win32', 'ia32') }
        default { @() }
    }

    foreach ($pattern in $patterns) {
        $match = $exeAssets | Where-Object { $_.name -match [regex]::Escape($pattern) } | Select-Object -First 1
        if ($match) { return $match }
    }

    # No architecture hint in any name: prefer one that does not advertise a foreign
    # architecture, otherwise fall back to the first asset.
    $foreign = if ($arch -eq 'ARM64') { 'x86|x64|amd64|win32|win64|ia32' } else { 'arm64|aarch64' }
    $neutral = $exeAssets | Where-Object { $_.name -notmatch $foreign } | Select-Object -First 1
    if ($neutral) { return $neutral }

    Write-Warn "No asset clearly matches architecture $arch - using $($exeAssets[0].name)."
    return $exeAssets[0]
}

function Get-InstalledVersion {
    param([Parameter(Mandatory)][string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $null }

    $raw = (Get-Item -LiteralPath $Path).VersionInfo.ProductVersion
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }

    $parsed = $null
    if ([Version]::TryParse($raw.Trim(), [ref] $parsed)) { return $parsed }
    return $null
}

<#
    Executables usually carry four version fields (1.20.0.0) while release tags carry
    three (v1.20.0); normalise both before comparing.
#>
function ConvertTo-ComparableVersion {
    param([Parameter(Mandatory)][Version] $Version)
    [Version]::new($Version.Major, [math]::Max(0, $Version.Minor), [math]::Max(0, $Version.Build))
}

#endregion

#region -------------------------------------------------------------- process

function Stop-RunningInstances {
    param([Parameter(Mandatory)][string] $Name)

    $running = @(Get-Process -Name $Name -ErrorAction SilentlyContinue)
    if ($running.Count -eq 0) {
        Write-Detail 'No running instance.'
        return
    }

    if (-not $PSCmdlet.ShouldProcess("$($running.Count) instance(s) of $Name", 'Stop process')) { return }

    $running | Stop-Process -Force -ErrorAction SilentlyContinue
    $running | Wait-Process -Timeout 15 -ErrorAction SilentlyContinue
    Write-Ok "Closed $($running.Count) instance(s)."
}

function Start-Instances {
    param(
        [Parameter(Mandatory)][string] $Path,
        [object[]] $Shortcuts = @()
    )

    Write-Step 'Starting the main instance...'
    if ($PSCmdlet.ShouldProcess($Path, 'Start process')) {
        Start-Process -FilePath $Path
    }

    if (@($Shortcuts).Count -eq 0) {
        Write-Detail 'No additional-instance shortcut found - started the main instance only.'
        return
    }

    Start-Sleep -Seconds 2
    foreach ($shortcut in $Shortcuts) {
        Write-Step "Starting additional instance: $($shortcut.Name)..."
        if ($PSCmdlet.ShouldProcess($shortcut.FullName, 'Start process')) {
            Start-Process -FilePath $shortcut.FullName
        }
    }
}

#endregion

#region ------------------------------------------------------- download & verify

<#
    Streams the download so the single-line progress indicator can be drawn as bytes
    arrive. Returns the number of bytes written.
#>
function Save-Asset {
    param(
        [Parameter(Mandatory)][string] $Uri,
        [Parameter(Mandatory)][string] $Destination,
        [long] $ExpectedSize = 0
    )

    $request                  = [System.Net.HttpWebRequest]::Create($Uri)
    $request.UserAgent        = $Script:UserAgent
    $request.Timeout          = 60000
    $request.ReadWriteTimeout = 120000
    $request.AllowAutoRedirect = $true
    if ([System.Net.WebRequest]::DefaultWebProxy) {
        $request.Proxy = [System.Net.WebRequest]::DefaultWebProxy
        $request.Proxy.Credentials = [System.Net.CredentialCache]::DefaultCredentials
    }

    $response = $null; $stream = $null; $output = $null
    try {
        $response = $request.GetResponse()
        $total    = if ($response.ContentLength -gt 0) { $response.ContentLength } else { $ExpectedSize }
        $stream   = $response.GetResponseStream()
        $output   = [System.IO.File]::Create($Destination)

        $buffer     = New-Object byte[] 131072
        $downloaded = 0L
        $lastDrawn  = -1

        while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $output.Write($buffer, 0, $read)
            $downloaded += $read

            # Redraw once per percentage point to avoid flicker.
            $pct = if ($total -gt 0) { [int](100 * $downloaded / $total) } else { -1 }
            if ($pct -ne $lastDrawn) {
                Write-ProgressBar -Current $downloaded -Total $total
                $lastDrawn = $pct
            }
        }

        Write-ProgressBar -Current $downloaded -Total $total
        Write-Host ''

        if ($total -gt 0 -and $downloaded -ne $total) {
            throw "Incomplete download: got $downloaded of $total bytes."
        }
        return $downloaded
    }
    catch [System.Net.WebException] {
        throw [System.Exception]::new("Download failed: $($_.Exception.Message)", $_.Exception)
    }
    finally {
        if ($output)   { $output.Dispose() }
        if ($stream)   { $stream.Dispose() }
        if ($response) { $response.Dispose() }
    }
}

<#
    Integrity check on the downloaded file, in two independent layers:
      - SHA-256 against the digest GitHub publishes for the asset;
      - Authenticode signature.

    Policy: a matching SHA-256 proves the bytes are exactly the ones GitHub serves for
    this release, so an *unsigned* file is only a warning - many open-source projects
    ship unsigned builds, and blocking there would break unattended runs for no gain.
    A file that is signed but whose signature does not validate (tampered, revoked,
    untrusted chain) is a different matter and always needs a human answer, as does an
    unsigned file when GitHub published no digest to check against.

    Returns $true when it is safe to proceed.
#>
function Test-DownloadedFile {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)] $Asset
    )

    $digest = $Asset.PSObject.Properties['digest'] | ForEach-Object { $_.Value }
    $hashVerified = $false

    if ($digest -and $digest -match '^sha256:([0-9a-fA-F]{64})$') {
        $expected = $Matches[1].ToLowerInvariant()
        $actual   = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()

        if ($actual -ne $expected) {
            Write-Fail 'SHA-256 mismatch: the downloaded file does not match the digest published by GitHub.'
            Write-Detail "expected $expected"
            Write-Detail "actual   $actual"
            return $false
        }
        Write-Ok 'SHA-256 digest matches the one published by GitHub.'
        $hashVerified = $true
    }
    else {
        Write-Warn 'GitHub published no SHA-256 digest for this asset - hash check not possible.'
    }

    if ($SkipSignatureCheck) {
        Write-Warn 'Authenticode check skipped (-SkipSignatureCheck).'
        return $true
    }

    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    switch ($signature.Status) {
        'Valid' {
            Write-Ok "Signed by: $($signature.SignerCertificate.Subject)"
            return $true
        }
        'NotSigned' {
            if ($hashVerified) {
                Write-Warn 'Not digitally signed - accepted because the SHA-256 digest matched.'
                return $true
            }
            Write-Warn 'The downloaded executable is neither signed nor covered by a published digest.'
        }
        default {
            Write-Fail "Authenticode status: $($signature.Status) - $($signature.StatusMessage)"
        }
    }

    return (Read-YesNo -Question 'Install this executable anyway?')
}

<#
    Antivirus scanners and lingering handles can keep the old executable locked for a
    few seconds after the process exits, so retry before giving up.
#>
function Move-WithRetry {
    param(
        [Parameter(Mandatory)][string] $Source,
        [Parameter(Mandatory)][string] $Destination,
        [int] $Attempts = 5,
        [int] $DelaySeconds = 2
    )

    for ($i = 1; $i -le $Attempts; $i++) {
        try {
            Move-Item -LiteralPath $Source -Destination $Destination -Force
            return
        }
        catch {
            if ($i -eq $Attempts) { throw }
            Write-Detail "Target file still locked - retrying ($i/$Attempts)..." ([ConsoleColor]::DarkYellow)
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

#endregion

#region ----------------------------------------------------------------- main

function Invoke-Update {
    Write-Host ''
    Write-Rule 'Usage Monitor for Claude - updater'

    if (-not (Test-Windows)) {
        Write-Fail 'This script updates a Windows executable and only runs on Windows.'
        return $Script:ExitPlatform
    }

    Initialize-Tls

    # Resolve paths.
    if (-not $InstallDir) {
        if (-not $PSScriptRoot) {
            Write-Fail 'Cannot determine the script folder - pass -InstallDir explicitly.'
            return $Script:ExitPlatform
        }
        $InstallDir = $PSScriptRoot
    }
    $InstallDir = (Resolve-Path -LiteralPath $InstallDir -ErrorAction Stop).Path

    $exePath     = Join-Path $InstallDir $ExeName
    $processName = [System.IO.Path]::GetFileNameWithoutExtension($ExeName)

    Write-Step "Checking the latest release on GitHub ($Repo)..."
    try {
        $release = Get-LatestRelease -Repository $Repo
        $asset   = Select-ReleaseAsset -Release $release
    }
    catch {
        Write-Fail $_.Exception.Message
        return $Script:ExitNetwork
    }

    $tagVersion = $null
    if (-not [Version]::TryParse($release.tag_name.TrimStart('v', 'V'), [ref] $tagVersion)) {
        Write-Fail "Release tag '$($release.tag_name)' is not a version number this script can compare."
        return $Script:ExitError
    }

    $installedVersion = Get-InstalledVersion -Path $exePath
    if ($installedVersion) {
        Write-Detail "Installed: $($installedVersion.ToString(3))   Latest release: $($tagVersion.ToString(3))"

        if ((ConvertTo-ComparableVersion $installedVersion) -eq (ConvertTo-ComparableVersion $tagVersion)) {
            if ($Force) {
                Write-Warn 'Same version, but -Force was given: reinstalling.'
            }
            else {
                Write-Ok 'Already on the latest version.'
                if (-not (Read-YesNo -Question 'Download and re-apply it anyway?')) {
                    Write-Detail 'Nothing to do.'
                    return $Script:ExitOk
                }
                Write-Warn 'Reinstalling the same version on request.'
            }
        }
    }
    elseif (Test-Path -LiteralPath $exePath) {
        Write-Detail "$exePath carries no readable version - reinstalling."
    }
    else {
        Write-Detail "No executable at $exePath - performing a fresh install."
    }

    if (-not (Test-DirectoryWritable -Path $InstallDir)) {
        Write-Fail "No write permission on $InstallDir."
        if (-not (Test-Elevated)) {
            Write-Detail 'Run this script as Administrator, or install to a folder you own.'
        }
        return $Script:ExitReplace
    }

    if (-not $SkipChangelog) {
        Show-Changelog -Release $release
    }

    Write-Step "Closing running instances of $processName..."
    Stop-RunningInstances -Name $processName

    $tempExe = Join-Path ([System.IO.Path]::GetTempPath()) "$processName-$($tagVersion.ToString(3))-$([guid]::NewGuid().ToString('N')).exe"
    try {
        Write-Step "Downloading $($asset.name) ($(Format-Size $asset.size))..."
        if ($PSCmdlet.ShouldProcess($asset.browser_download_url, 'Download asset')) {
            Save-Asset -Uri $asset.browser_download_url -Destination $tempExe -ExpectedSize $asset.size | Out-Null

            Write-Step 'Verifying the downloaded file...'
            if (-not (Test-DownloadedFile -Path $tempExe -Asset $asset)) {
                Write-Fail 'Verification failed - the installed executable was left untouched.'
                return $Script:ExitVerification
            }

            Write-Step "Replacing $exePath..."
            try {
                Move-WithRetry -Source $tempExe -Destination $exePath
            }
            catch {
                Write-Fail "Could not replace the executable: $($_.Exception.Message)"
                Write-Detail 'Close any process still using it and run the script again.'
                return $Script:ExitReplace
            }
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempExe) {
            Remove-Item -LiteralPath $tempExe -Force -ErrorAction SilentlyContinue -WhatIf:$false
        }
    }

    $shortcutFilter = "$ExeName - *.lnk"
    $extraShortcuts = @(Get-ChildItem -LiteralPath $InstallDir -Filter $shortcutFilter -ErrorAction SilentlyContinue)
    Start-Instances -Path $exePath -Shortcuts $extraShortcuts

    Write-Host ''
    Write-Ok "Update complete: version $($tagVersion.ToString(3))."
    Write-Host ''
    return $Script:ExitOk
}

try {
    exit (Invoke-Update)
}
catch {
    Write-Host ''
    Write-Fail $_.Exception.Message
    if ($_.ScriptStackTrace) {
        Write-Detail 'Run with -Verbose for details, or report the trace below.'
        Write-Detail ($_.ScriptStackTrace -replace "`r?`n", ' | ')
    }
    Write-Host ''
    if (-not $NonInteractive -and [Environment]::UserInteractive -and $Host.Name -eq 'ConsoleHost') {
        # Keep the window open when launched by double-click.
        Write-Host 'Press Enter to close...' -ForegroundColor DarkGray -NoNewline
        [void] (Read-Host)
    }
    exit $Script:ExitError
}

#endregion
