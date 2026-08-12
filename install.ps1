# RitCode installer for Windows.
#
# Proprietary. (c) 2026 Ritik Sharma. All rights reserved.
#
# Downloads the prebuilt ritcode.exe from GitHub Releases, verifies its SHA256
# and detached publisher signature
# before trusting it, and installs it user-local with no admin:
#
#     irm https://raw.githubusercontent.com/ritiksharmma/ritcode-dist/main/install.ps1 | iex
#
# Environment:
#   RITCODE_HOME            install root (default: %USERPROFILE%\.ritcode)
#   RITCODE_VERSION         install a specific tag (e.g. v0.1.0) instead of latest
#   RITCODE_NO_MODIFY_PATH  when "1", never edit the user PATH; only print help

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Repo = 'ritiksharmma/ritcode-dist'
$Api = "https://api.github.com/repos/$Repo"
$HomeDir = if ($env:RITCODE_HOME) { $env:RITCODE_HOME } else { Join-Path $env:USERPROFILE '.ritcode' }
$BinDir = Join-Path $HomeDir 'bin'

function Fail($msg) { Write-Error "error: $msg"; exit 1 }
function Say($msg) { Write-Host $msg }

# ---- 1. detect architecture, map to a target triple --------------------------

function Get-Target {
    switch ($env:PROCESSOR_ARCHITECTURE) {
        'AMD64' { return 'x86_64-pc-windows-msvc' }
        'ARM64' { Fail 'arm64 Windows is not supported yet (wave 1 ships x86_64 only)' }
        default { Fail "unsupported architecture: $($env:PROCESSOR_ARCHITECTURE)" }
    }
}

# ---- 2. resolve the release --------------------------------------------------

function Resolve-Release {
    if ($env:RITCODE_VERSION) {
        $tag = $env:RITCODE_VERSION
        if ($tag -notmatch '^v') { $tag = "v$tag" }
        $url = "$Api/releases/tags/$tag"
    }
    else {
        $url = "$Api/releases/latest"
    }
    try {
        return Invoke-RestMethod -Uri $url -Headers @{
            'User-Agent' = 'ritcode-installer'
            'Accept'     = 'application/vnd.github+json'
        }
    }
    catch {
        Fail "could not reach the GitHub Releases API at $url ($($_.Exception.Message))"
    }
}

# ---- 3. path-traversal guard for the zip -------------------------------------

function Assert-SafeZip($zipPath) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName
            if ($name -match '(^|[\\/])\.\.([\\/]|$)' -or
                $name -match '^[\\/]' -or
                $name -match '^[A-Za-z]:') {
                Fail "unsafe archive entry rejected: $name"
            }
        }
    }
    finally {
        $zip.Dispose()
    }
}

function Verify-PublisherSignature($archive, $signature, $publicKey) {
    $openssl = Get-Command openssl -ErrorAction SilentlyContinue
    if (-not $openssl) { Fail 'OpenSSL is required to verify the publisher signature' }
    & $openssl.Source pkeyutl -verify -rawin -pubin -inkey $publicKey -in $archive -sigfile $signature | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail 'publisher signature verification failed (refusing to install)' }
}

# ---- 4. PATH handling --------------------------------------------------------

function Set-UserPath {
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    if ($userPath -and ($userPath -split ';' | Where-Object { $_ -eq $BinDir })) {
        return
    }
    if ($env:RITCODE_NO_MODIFY_PATH -ne '1') {
        $newPath = if ($userPath) { "$BinDir;$userPath" } else { $BinDir }
        [Environment]::SetEnvironmentVariable('Path', $newPath, 'User')
        $env:PATH = "$BinDir;$env:PATH"
        Say "RitCode: added $BinDir to your user PATH (open a new terminal to pick it up)"
    }
    else {
        Say ''
        Say "Add $BinDir to your PATH:"
        Say "  PowerShell  [Environment]::SetEnvironmentVariable('Path', `"`$env:PATH;$BinDir`", 'User')"
    }
}

function Warn-IfShadowed($installed) {
    $active = Get-Command ritcode -ErrorAction SilentlyContinue
    if (-not $active) { return }
    if ($active.Source -ieq $installed) { return }
    Write-Warning "another 'ritcode' is already on your PATH and will run instead of the one just installed:"
    Write-Warning "    $($active.Source)"
    Write-Warning "the binary just installed is at:"
    Write-Warning "    $installed"
    Write-Warning "remove the other one, or make sure $BinDir comes first in PATH."
    Write-Warning "open a new terminal to pick up the updated PATH."
}

# ---- 5. main -----------------------------------------------------------------

$target = Get-Target
Say "RitCode: resolving the latest release for $target"

$release = Resolve-Release
$archiveAsset = $release.assets | Where-Object { $_.name -eq "ritcode-$($release.tag_name)-$target.zip" } | Select-Object -First 1
if (-not $archiveAsset) {
    $archiveAsset = $release.assets | Where-Object { $_.name -like "*$target.zip" } | Select-Object -First 1
}
if (-not $archiveAsset) { Fail "no archive asset found for $target in the release" }
$shaAsset = $release.assets | Where-Object { $_.name -eq "$($archiveAsset.name).sha256" } | Select-Object -First 1
if (-not $shaAsset) { Fail "no checksum asset found for $($archiveAsset.name)" }
$sigAsset = $release.assets | Where-Object { $_.name -eq "$($archiveAsset.name).sig" } | Select-Object -First 1
if (-not $sigAsset) { Fail "no publisher signature found for $($archiveAsset.name)" }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("ritcode-" + [System.Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $archive = Join-Path $tmp $archiveAsset.name
    $shaFile = Join-Path $tmp $shaAsset.name
    $sigFile = Join-Path $tmp $sigAsset.name
    $keyFile = Join-Path $tmp 'release-signing-public.pem'

    Say "RitCode: downloading $($archiveAsset.name)"
    Invoke-WebRequest -Uri $archiveAsset.browser_download_url -OutFile $archive -Headers @{ 'User-Agent' = 'ritcode-installer' }
    Invoke-WebRequest -Uri $shaAsset.browser_download_url -OutFile $shaFile -Headers @{ 'User-Agent' = 'ritcode-installer' }
    Invoke-WebRequest -Uri $sigAsset.browser_download_url -OutFile $sigFile -Headers @{ 'User-Agent' = 'ritcode-installer' }
    @'
-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEAI56hp9iLXPr1x0u8HFsVsQ1PmtmF93gAJpwojrwBMX8=
-----END PUBLIC KEY-----
'@ | Set-Content -Path $keyFile -NoNewline

    $expected = ((Get-Content $shaFile -Raw).Trim() -split '\s+')[0]
    $actual = (Get-FileHash -Algorithm SHA256 -Path $archive).Hash.ToLower()
    if (-not $expected) { Fail 'empty checksum file' }
    if ($expected.ToLower() -ne $actual) {
        Fail "checksum mismatch: expected $expected, got $actual (refusing to install)"
    }
    Say 'RitCode: checksum verified'
    Verify-PublisherSignature $archive $sigFile $keyFile
    Say 'RitCode: publisher signature verified'

    Assert-SafeZip $archive
    $extract = Join-Path $tmp 'extract'
    Expand-Archive -Path $archive -DestinationPath $extract -Force

    $binSrc = Get-ChildItem -Path $extract -Recurse -Filter 'ritcode.exe' | Select-Object -First 1
    if (-not $binSrc) { Fail 'no ritcode.exe inside the archive' }

    # ---- install user-local, no admin ----
    New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
    $dest = Join-Path $BinDir 'ritcode.exe'
    Copy-Item -Path $binSrc.FullName -Destination $dest -Force
    Say "RitCode: installed to $dest"

    Set-UserPath
    Warn-IfShadowed $dest
    Say ''
    Say 'Done. Start RitCode with:'
    Say '  ritcode'
}
finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
