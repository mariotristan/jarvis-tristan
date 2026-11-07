# Builds tristan.exe (release) and packages it for Windows:
#   dist\Tristan-<version>-windows-x64.zip   tristan.exe, the DLLs it needs that Windows does not have, LICENSE, README.txt
#   dist\Tristan-<version>-windows-x64.zip.sha256   "<sha256>  <zip name>", like the Mac DMG's
# The version (for example 1.2.3, from the tag v1.2.3; release.yml turns any tag into letters, digits, dots and dashes) is
# stamped into Sources\TristanCLICore\BuildVersion.swift for the
# build, so `tristan --version` prints it; the file is restored afterwards.
# Usage: pwsh -File scripts\package-windows.ps1 -Version 1.2.3 [-OutDir dist]
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [string]$OutDir = 'dist'
)
$ErrorActionPreference = 'Stop'
# The version goes into a Swift string literal and a file name: letters, digits, dots and dashes only, starting with a
# letter or digit (no quotes, backslashes, `$`, slashes or spaces).
if ($Version -notmatch '\A[0-9A-Za-z][0-9A-Za-z.-]*\z') {
    throw "Version '$Version' may only contain letters, digits, dots and dashes, and must start with a letter or digit"
}

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
Set-Location $root
$name = "Tristan-$Version-windows-x64"
$OutDir = [System.IO.Path]::GetFullPath((Join-Path $root $OutDir))
$stage = Join-Path $OutDir $name
$zip = Join-Path $OutDir "$name.zip"
# A zip or checksum left from an earlier run must never be mistaken for this one.
foreach ($stale in $zip, "$zip.sha256") { if (Test-Path $stale) { Remove-Item $stale -Force } }

# 1. Stamp the version and build. Not -static-stdlib: the Windows SDK of Swift 6.4.2 has no static curl.lib for
#    FoundationNetworking, so that link fails. The Swift runtime DLLs are shipped next to the exe instead (step 2).
$versionFile = Join-Path $root 'Sources\TristanCLICore\BuildVersion.swift'
$original = [System.IO.File]::ReadAllText($versionFile)
$stamped = $original -replace 'static let value = "[^"]*"', "static let value = `"$Version`""
if (-not $stamped.Contains("`"$Version`"")) { throw "Could not stamp the version into $versionFile" }
$buildArguments = @('-c', 'release', '--product', 'tristan')
try {
    [System.IO.File]::WriteAllText($versionFile, $stamped)
    swift build @buildArguments
    if ($LASTEXITCODE -ne 0) { throw "swift build failed ($LASTEXITCODE)" }
    $bin = (swift build @buildArguments --show-bin-path | Select-Object -Last 1).Trim()
} finally {
    [System.IO.File]::WriteAllText($versionFile, $original)
}
$exe = Join-Path $bin 'tristan.exe'
if (-not (Test-Path $exe)) { throw "No tristan.exe in $bin" }

# 2. Ship every DLL the exe needs (directly or through another shipped DLL) that is not part of Windows: Swift runtime
#    DLLs from the toolchain, and the Visual C++ runtime (app-local copies are allowed and spare a separate install).
$dumpbin = (Get-Command dumpbin.exe -ErrorAction SilentlyContinue).Source
if (-not $dumpbin) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    $dumpbin = & $vswhere -latest -products * -find 'VC\Tools\MSVC\**\bin\Hostx64\x64\dumpbin.exe' | Select-Object -First 1
}
if (-not $dumpbin) { throw 'dumpbin.exe was not found' }
Write-Host "dumpbin: $dumpbin"

function Get-Dependents([string]$file) {
    $lines = & $dumpbin /nologo /dependents $file
    if ($LASTEXITCODE -ne 0) { throw "dumpbin failed on $file" }
    # Only the bare names in the "Image has the following dependencies" list, not "Dump of file <path>.dll".
    @($lines | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '\A[A-Za-z0-9_.+-]+\.dll\z' })
}

$windowsDir = $env:SystemRoot
$system32 = Join-Path $windowsDir 'System32'
$searchDirs = @($bin) + @($env:Path -split ';' | Where-Object { $_ -and -not $_.StartsWith($windowsDir, [StringComparison]::OrdinalIgnoreCase) })
$vcRuntime = '^(vcruntime|msvcp|concrt)[0-9].*\.dll$'

$ship = [ordered]@{}            # dll name -> source path
$system = [System.Collections.Generic.SortedSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$queue = [System.Collections.Generic.Queue[string]]::new()
$queue.Enqueue($exe)
while ($queue.Count -gt 0) {
    $file = $queue.Dequeue()
    foreach ($dll in Get-Dependents $file) {
        if ($ship.Contains($dll) -or $system.Contains($dll)) { continue }
        if ($dll -match $vcRuntime -and (Test-Path (Join-Path $system32 $dll))) {
            $ship[$dll] = Join-Path $system32 $dll
            continue
        }
        if ($dll -like 'api-ms-win-*' -or $dll -like 'ext-ms-*' -or (Test-Path (Join-Path $system32 $dll))) {
            [void]$system.Add($dll)
            continue
        }
        $found = $searchDirs | ForEach-Object { Join-Path $_ $dll } | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $found) { throw "$dll (needed by $file) was not found next to the exe, on PATH or in System32" }
        $ship[$dll] = $found
        $queue.Enqueue($found)
    }
}
Write-Host "Part of Windows (not shipped): $($system -join ', ')"
Write-Host "Shipped next to tristan.exe: $(if ($ship.Count) { $ship.Keys -join ', ' } else { 'none' })"

# 3. Stage, zip and hash.
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Force $stage | Out-Null
Copy-Item $exe $stage
foreach ($entry in $ship.GetEnumerator()) { Copy-Item $entry.Value (Join-Path $stage $entry.Key) }
Copy-Item (Join-Path $root 'LICENSE') (Join-Path $stage 'LICENSE.txt')
$readme = @"
Tristan $Version for Windows (x64): the ``tristan`` command

Keep tristan.exe and the files next to it together, in a folder on your PATH or anywhere you like.
Open a terminal (Windows Terminal, PowerShell or cmd) in that folder and start with:

  tristan --version
  tristan providers                      which providers are ready, and what to set for the others
  tristan config list                    provider settings (models, endpoints, regions)
  tristan secret set azure-openai-key    store the Azure OpenAI key (typed at a hidden prompt)
  tristan run --provider ollama "add a README"

Settings and history live in %APPDATA%\Tristan; secrets in Windows Credential Manager.
Full guide: https://github.com/mariotristan/jarvis-tristan
"@
[System.IO.File]::WriteAllText((Join-Path $stage 'README.txt'), ($readme -replace "`r?`n", "`r`n"))

Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip
$hash = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLowerInvariant()
[System.IO.File]::WriteAllText("$zip.sha256", "$hash  $name.zip`n")
Write-Host "Contents of $name.zip:"
Get-ChildItem $stage | ForEach-Object { Write-Host ("  {0,12:N0}  {1}" -f $_.Length, $_.Name) }
Get-Content "$zip.sha256"
