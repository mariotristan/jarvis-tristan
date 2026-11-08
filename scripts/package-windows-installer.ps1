# Builds the Windows installer from the staging folder that scripts\package-windows.ps1 made the zip from, so the
# installer and the zip carry exactly the same files:
#   dist\Tristan-<version>-windows-x64-setup.exe          Inno Setup 6 installer (scripts\windows\tristan.iss)
#   dist\Tristan-<version>-windows-x64-setup.exe.sha256   "<sha256>  <installer name>", like the zip's
# Run package-windows.ps1 with the same version first. Uses Inno Setup 6.7.3 exactly: an ISCC.exe of that version
# under Program Files is used as it is; otherwise the official 6.7.3 installer is downloaded from the Inno Setup
# GitHub release, its SHA-256 checked against the pinned value below, and installed into a private folder.
# Usage: pwsh -File scripts\package-windows-installer.ps1 -Version 1.2.3 [-StageDir <folder>] [-OutDir dist]
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [string]$StageDir,
    [string]$OutDir = 'dist'
)
$ErrorActionPreference = 'Stop'
# The same allowlist as package-windows.ps1 (case-sensitive, so a non-ASCII letter such as U+212A cannot pass).
if ($Version -cnotmatch '\A[0-9A-Za-z][0-9A-Za-z.-]*\z') {
    throw "Version '$Version' may only contain letters, digits, dots and dashes, and must start with a letter or digit"
}

# Pinned compiler. To move to a newer 6.x: change all three values, taking the SHA-256 from the release page (GitHub
# shows each asset's digest) and checking it against a download of your own.
$innoVersion = '6.7.3'
$innoUrl = 'https://github.com/jrsoftware/issrc/releases/download/is-6_7_3/innosetup-6.7.3.exe'
$innoSha256 = '9c73c3bae7ed48d44112a0f48e66742c00090bdb5bef71d9d3c056c66e97b732'

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $root
$name = "Tristan-$Version-windows-x64"
# Path.Combine (unlike Join-Path) keeps an absolute second path as it is.
$OutDir = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($root, $OutDir))
if (-not $StageDir) { $StageDir = Join-Path $OutDir $name }
$StageDir = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($root, $StageDir))
$iss = Join-Path $root 'scripts\windows\tristan.iss'
$setupName = "$name-setup.exe"
$setup = Join-Path $OutDir $setupName

# 1. The staging folder: the files the zip was made from.
foreach ($file in 'tristan.exe', 'LICENSE.txt', 'README.txt', 'THIRD-PARTY-NOTICES.txt') {
    if (-not (Test-Path -LiteralPath (Join-Path $StageDir $file))) {
        throw "$StageDir has no $file; run scripts\package-windows.ps1 -Version $Version first"
    }
}
$staged = @(Get-ChildItem -LiteralPath $StageDir -Recurse -File)
# When the zip is next to the staging folder, the two must hold the same files, byte for byte.
$zip = Join-Path $OutDir "$name.zip"
if (Test-Path -LiteralPath $zip) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
    try {
        $inZip = @{}
        foreach ($entry in $archive.Entries) {
            if ($entry.FullName.EndsWith('/') -or $entry.FullName.EndsWith('\')) { continue }
            $stream = $entry.Open()
            try {
                $sha = [System.Security.Cryptography.SHA256]::Create()
                $inZip[$entry.FullName.Replace('/', '\')] = [System.Convert]::ToHexString($sha.ComputeHash($stream))
            } finally { $stream.Dispose() }
        }
    } finally { $archive.Dispose() }
    $inStage = @{}
    foreach ($file in $staged) {
        $inStage[$file.FullName.Substring($StageDir.TrimEnd('\').Length + 1)] = (Get-FileHash -Algorithm SHA256 -LiteralPath $file.FullName).Hash
    }
    $different = @(@($inZip.Keys) + @($inStage.Keys) | Sort-Object -Unique | Where-Object { $inZip[$_] -ne $inStage[$_] })
    if ($different.Count -gt 0) { throw "The staging folder and $name.zip differ: $($different -join ', ')" }
    Write-Host "The staging folder holds the same $($inStage.Count) files as $name.zip (names and SHA-256)."
} else {
    Write-Warning "$zip is not there, so the staging folder could not be compared with it"
}

# 2. Inno Setup 6.7.3.
# ISCC.exe has no numeric version resource (it reads 0.0.0), so the version strings of ISCC.exe and of the compiler
# DLL next to it are tried too. Returns '' when none of them names a version.
function Get-InnoVersion([string]$iscc) {
    $dir = Split-Path -Parent $iscc
    foreach ($file in @($iscc) + @(Get-ChildItem -LiteralPath $dir -Filter 'ISCmplr*.dll' -ErrorAction SilentlyContinue | ForEach-Object FullName)) {
        $info = (Get-Item -LiteralPath $file).VersionInfo
        foreach ($text in "$($info.FileMajorPart).$($info.FileMinorPart).$($info.FileBuildPart)", $info.ProductVersion, $info.FileVersion) {
            if ($text -and $text -match '\A\s*([1-9]\d*\.\d+\.\d+)') { return $Matches[1] }
        }
    }
    return ''
}
# On a CI runner RUNNER_TEMP is a short path without spaces; elsewhere the user's temp folder.
$tempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
$privateDir = Join-Path $tempRoot "innosetup-$innoVersion"
$candidates = @(
    (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
    (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
    (Join-Path $privateDir 'ISCC.exe')
)
$iscc = $null
foreach ($candidate in $candidates) {
    if (-not (Test-Path -LiteralPath $candidate)) { continue }
    $found = Get-InnoVersion $candidate
    if ($found -eq $innoVersion) { $iscc = $candidate; break }
    Write-Host "Not used: $candidate (version '$found', not $innoVersion)"
}
if (-not $iscc) {
    $download = Join-Path $tempRoot "innosetup-$innoVersion-$([System.Guid]::NewGuid().ToString('N')).exe"
    Write-Host "Downloading $innoUrl"
    Invoke-WebRequest -Uri $innoUrl -OutFile $download -UseBasicParsing
    $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $download).Hash.ToLowerInvariant()
    if ($actual -ne $innoSha256) {
        Remove-Item -LiteralPath $download -Force
        throw "The Inno Setup download has SHA-256 $actual, expected $innoSha256; not running it"
    }
    Write-Host "SHA-256 matches the pinned value: $actual"
    $signature = Get-AuthenticodeSignature -LiteralPath $download
    Write-Host "Authenticode: $($signature.Status), signer: $($signature.SignerCertificate.Subject)"
    $log = Join-Path $tempRoot "innosetup-$innoVersion-install.log"
    $arguments = "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /NOICONS /DIR=`"$privateDir`" /LOG=`"$log`""
    $process = Start-Process -FilePath $download -ArgumentList $arguments -Wait -PassThru
    Remove-Item -LiteralPath $download -Force
    if ($process.ExitCode -ne 0) {
        if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log -Tail 40 | ForEach-Object { Write-Host "  $_" } }
        throw "The Inno Setup installer failed (exit $($process.ExitCode))"
    }
    $iscc = Join-Path $privateDir 'ISCC.exe'
    if (-not (Test-Path -LiteralPath $iscc)) { throw "No ISCC.exe in $privateDir after installing Inno Setup" }
    # The SHA-256 above already pins what was installed; a version that can be read must still agree.
    $found = Get-InnoVersion $iscc
    if ($found -and $found -ne $innoVersion) { throw "Installed Inno Setup reports $found, expected $innoVersion" }
}
Write-Host "Inno Setup compiler: $iscc (pinned $innoVersion; version resource: '$(Get-InnoVersion $iscc)')"

# 3. Compile and hash. A setup or checksum left from an earlier run must never be mistaken for this one.
foreach ($stale in $setup, "$setup.sha256") { if (Test-Path -LiteralPath $stale) { Remove-Item -LiteralPath $stale -Force } }
$ErrorActionPreference = 'Continue'   # ISCC may write to stderr; its exit code is checked below
$compilerOutput = @(& $iscc "/DAppVersion=$Version" "/DStageDir=$StageDir" "/O$OutDir" $iss 2>&1 | ForEach-Object { $line = "$_"; Write-Host $line; $line })
$isccExit = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
if ($isccExit -ne 0) { throw "ISCC.exe failed ($isccExit)" }
# The compiler names its own version in its output ("Inno Setup 6.7.3" or similar); it must be the pinned one.
$named = @($compilerOutput | Select-String -Pattern 'Inno Setup (\d+\.\d+\.\d+)' -AllMatches | ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
Write-Host "Versions named by ISCC.exe: $(if ($named) { $named -join ', ' } else { 'none' })"
if ($named | Where-Object { $_ -ne $innoVersion }) { throw "ISCC.exe reports Inno Setup $($named -join ', '), expected $innoVersion" }
if (-not (Test-Path -LiteralPath $setup)) { throw "ISCC.exe did not write $setup" }
$size = (Get-Item -LiteralPath $setup).Length
if ($size -le 0) { throw "$setup is empty" }
$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $setup).Hash.ToLowerInvariant()
[System.IO.File]::WriteAllText("$setup.sha256", "$hash  $setupName`n")
Write-Host ("{0}: {1:N0} bytes" -f $setupName, $size)
Get-Content -LiteralPath "$setup.sha256"
