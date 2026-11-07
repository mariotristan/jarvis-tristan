# Installs, upgrades and uninstalls the Windows installer silently on this machine and checks the result. Used by
# windows.yml and release.yml, so the two cannot drift. Meant for a disposable CI runner that is an administrator:
# it writes to HKCU and HKLM Path (through the installer) and puts everything back in a `finally`.
#
#   pwsh -File scripts/ci/test-installer.ps1 -Installer dist/Tristan-1.2.3-windows-x64-setup.exe -Version 1.2.3 `
#        [-StageDir dist/Tristan-1.2.3-windows-x64] [-LogDir <folder for the /LOG files>]
#
# Scenarios: per user with the PATH task (then the same installer again as an upgrade, then uninstall, with a dummy
# settings file that must survive), per user without the PATH task, and all users. Every check prints PASS or FAIL;
# the exit code is 1 if any check failed. The Path values themselves are never printed, only their type and length.
param(
  [Parameter(Mandatory = $true)][string]$Installer,
  [Parameter(Mandatory = $true)][string]$Version,
  [string]$StageDir,
  [string]$LogDir
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3

$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Installer = (Resolve-Path -LiteralPath $Installer).Path
if ($StageDir) { $StageDir = (Resolve-Path -LiteralPath $StageDir).Path }
$tempRoot = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
if (-not $LogDir) { $LogDir = Join-Path $tempRoot 'installer-logs' }
New-Item -ItemType Directory -Force $LogDir | Out-Null
$LogDir = (Resolve-Path -LiteralPath $LogDir).Path

# The AppId comes from the script the installer was built from, so the two cannot disagree.
$issText = [System.IO.File]::ReadAllText((Join-Path $root 'scripts\windows\tristan.iss'))
if ($issText -notmatch '(?m)^AppId=\{\{([0-9A-Fa-f-]{36})\}') { throw 'No AppId={{<GUID>} line in scripts\windows\tristan.iss' }
$uninstallKeyName = "{$($Matches[1])}_is1"
$uninstallSubKey = "Software\Microsoft\Windows\CurrentVersion\Uninstall\$uninstallKeyName"
$userEnvironment = 'Environment'
$machineEnvironment = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment'

$script:failures = 0
function Check([string]$label, [bool]$ok) {
  if ($ok) { Write-Host "PASS: $label" } else { Write-Host "FAIL: $label"; $script:failures++ }
}

function Open-Base([string]$hive) {
  $which = if ($hive -eq 'HKCU') { [Microsoft.Win32.RegistryHive]::CurrentUser } else { [Microsoft.Win32.RegistryHive]::LocalMachine }
  return [Microsoft.Win32.RegistryKey]::OpenBaseKey($which, [Microsoft.Win32.RegistryView]::Registry64)
}

# The raw (unexpanded) Path value of HKCU or HKLM, with its registry type.
function Get-PathValue([string]$hive) {
  $base = Open-Base $hive
  try {
    $key = $base.OpenSubKey($(if ($hive -eq 'HKCU') { $userEnvironment } else { $machineEnvironment }))
    if (-not $key) { return [pscustomobject]@{ Exists = $false; Value = $null; Kind = 'None' } }
    try {
      if (@($key.GetValueNames() | Where-Object { $_ -eq 'Path' }).Count -eq 0) {
        return [pscustomobject]@{ Exists = $false; Value = $null; Kind = 'None' }
      }
      $value = [string]$key.GetValue('Path', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
      return [pscustomobject]@{ Exists = $true; Value = $value; Kind = $key.GetValueKind('Path').ToString() }
    } finally { $key.Dispose() }
  } finally { $base.Dispose() }
}

function Set-PathValue([string]$hive, $saved) {
  $base = Open-Base $hive
  try {
    $key = $base.OpenSubKey($(if ($hive -eq 'HKCU') { $userEnvironment } else { $machineEnvironment }), $true)
    try {
      if ($saved.Exists) { $key.SetValue('Path', $saved.Value, [Microsoft.Win32.RegistryValueKind]($saved.Kind)) }
      else { $key.DeleteValue('Path', $false) }
    } finally { $key.Dispose() }
  } finally { $base.Dispose() }
}

function Describe($pathValue) {
  if (-not $pathValue.Exists) { return 'absent' }
  return "$($pathValue.Kind), $($pathValue.Value.Length) characters, $(@($pathValue.Value -split ';').Count) entries"
}

# Exactly the same value: present or absent alike, same type, same characters (ordinal comparison).
function Test-SamePath($a, $b) {
  if ($a.Exists -ne $b.Exists) { return $false }
  if (-not $a.Exists) { return $true }
  return ($a.Kind -eq $b.Kind) -and [string]::Equals($a.Value, $b.Value, [System.StringComparison]::Ordinal)
}

# How often Dir appears in a Path value: case-insensitive, ignoring trailing backslashes (the installer's own rule).
function Get-EntryCount([string]$pathValue, [string]$dir) {
  if ($null -eq $pathValue) { return 0 }
  $target = $dir.TrimEnd('\')
  return @($pathValue -split ';' | Where-Object { [string]::Equals($_.TrimEnd('\'), $target, [System.StringComparison]::OrdinalIgnoreCase) }).Count
}

# The value the installer must write: the old one, a ';', the folder (or only the folder when there was none).
function Get-ExpectedPath($before, [string]$dir) {
  if (-not $before.Exists -or $before.Value -eq '') { return [pscustomobject]@{ Exists = $true; Value = $dir; Kind = $(if ($before.Exists) { $before.Kind } else { 'ExpandString' }) } }
  return [pscustomobject]@{ Exists = $true; Value = "$($before.Value);$dir"; Kind = $before.Kind }
}

function Test-UninstallKey([string]$hive) {
  $base = Open-Base $hive
  try {
    $key = $base.OpenSubKey($uninstallSubKey)
    if ($key) { $key.Dispose(); return $true }
    return $false
  } finally { $base.Dispose() }
}

function Get-UninstallValue([string]$hive, [string]$name) {
  $base = Open-Base $hive
  try {
    $key = $base.OpenSubKey($uninstallSubKey)
    if (-not $key) { return $null }
    try { return $key.GetValue($name) } finally { $key.Dispose() }
  } finally { $base.Dispose() }
}

# Starts a program with a raw argument string and waits for that process (not its children).
function Invoke-Program([string]$file, [string]$arguments, [int]$seconds = 600) {
  Write-Host "> $file $arguments"
  $info = [System.Diagnostics.ProcessStartInfo]::new($file, $arguments)
  $info.UseShellExecute = $false
  $process = [System.Diagnostics.Process]::Start($info)
  if (-not $process.WaitForExit($seconds * 1000)) {
    try { $process.Kill($true) } catch { }
    throw "$file did not finish within $seconds s"
  }
  return $process.ExitCode
}

function Install([string]$label, [string]$arguments) {
  $log = Join-Path $LogDir "$label.log"
  return Invoke-Program $Installer "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART $arguments /LOG=`"$log`""
}

# The uninstaller copies itself to a temporary file, starts that copy and exits at once, so its exit code only says the
# copy started. Wait until the folder and the Add/Remove Programs entry are gone and no process mentions the folder.
function Uninstall([string]$label, [string]$dir, [string]$hive, [int]$seconds = 180) {
  $log = Join-Path $LogDir "$label.log"
  $code = Invoke-Program (Join-Path $dir 'unins000.exe') "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG=`"$log`""
  $deadline = (Get-Date).AddSeconds($seconds)
  do {
    $busy = @(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -and $_.CommandLine.IndexOf($dir, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 })
    $done = (-not (Test-Path -LiteralPath $dir)) -and (-not (Test-UninstallKey $hive)) -and $busy.Count -eq 0
    if (-not $done) { Start-Sleep -Milliseconds 500 }
  } while (-not $done -and (Get-Date) -lt $deadline)
  return [pscustomobject]@{ Code = $code; Finished = $done; Seconds = [int]($seconds - ($deadline - (Get-Date)).TotalSeconds) }
}

function Test-InstalledFiles([string]$label, [string]$dir) {
  foreach ($file in 'tristan.exe', 'LICENSE.txt', 'README.txt', 'THIRD-PARTY-NOTICES.txt', 'unins000.exe') {
    Check "$label has $file" (Test-Path -LiteralPath (Join-Path $dir $file))
  }
  if ($StageDir) {
    # The installed program files are the staging folder (which the zip was made from), byte for byte; Inno Setup's
    # own uninstaller files are the only additions.
    $installed = @{}
    Get-ChildItem -LiteralPath $dir -Recurse -File | Where-Object { $_.Name -notmatch '\Aunins\d{3}\.(exe|dat)\z' } | ForEach-Object {
      $installed[$_.FullName.Substring($dir.Length + 1)] = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash
    }
    $staged = @{}
    Get-ChildItem -LiteralPath $StageDir -Recurse -File | ForEach-Object {
      $staged[$_.FullName.Substring($StageDir.TrimEnd('\').Length + 1)] = (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash
    }
    $different = @(@($installed.Keys) + @($staged.Keys) | Sort-Object -Unique | Where-Object { $installed[$_] -ne $staged[$_] })
    Check "$label holds exactly the $($staged.Count) staged files, byte for byte$(if ($different) { " (differ: $($different -join ', '))" })" ($different.Count -eq 0)
  }
  $exe = Join-Path $dir 'tristan.exe'
  $printed = (& $exe --version 2>&1 | Out-String).Trim()
  $code = $LASTEXITCODE
  Check "$label tristan.exe --version prints '$Version' (got '$printed', exit $code)" ($printed -eq $Version -and $code -eq 0)
}

# --- Self-test of the comparison helpers, before anything is installed ---
Check 'self-test: entry count ignores case and trailing backslashes' ((Get-EntryCount 'C:\A;c:\a\;C:\AB;;D:\a' 'C:\a') -eq 2)
Check 'self-test: entry count of an absent value is 0' ((Get-EntryCount $null 'C:\a') -eq 0)
$sample = [pscustomobject]@{ Exists = $true; Value = 'X;Y;'; Kind = 'ExpandString' }
Check 'self-test: expected value appends ;dir and keeps the type' ((Test-SamePath (Get-ExpectedPath $sample 'C:\t') ([pscustomobject]@{ Exists = $true; Value = 'X;Y;;C:\t'; Kind = 'ExpandString' })))
Check 'self-test: an absent Path becomes REG_EXPAND_SZ holding only the folder' ((Test-SamePath (Get-ExpectedPath ([pscustomobject]@{ Exists = $false; Value = $null; Kind = 'None' }) 'C:\t') ([pscustomobject]@{ Exists = $true; Value = 'C:\t'; Kind = 'ExpandString' })))
Check 'self-test: a different type is not the same value' (-not (Test-SamePath $sample ([pscustomobject]@{ Exists = $true; Value = 'X;Y;'; Kind = 'String' })))
Check 'self-test: a different case is not the same value' (-not (Test-SamePath $sample ([pscustomobject]@{ Exists = $true; Value = 'x;Y;'; Kind = 'ExpandString' })))

# --- The machine before ---
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Check 'the runner is an administrator (needed for the all-users scenario)' $isAdmin
$originalUser = Get-PathValue 'HKCU'
$originalMachine = Get-PathValue 'HKLM'
Write-Host "HKCU Path before: $(Describe $originalUser)"
Write-Host "HKLM Path before: $(Describe $originalMachine)"
Check 'no earlier per-user install of this AppId' (-not (Test-UninstallKey 'HKCU'))
Check 'no earlier all-users install of this AppId' (-not (Test-UninstallKey 'HKLM'))
Write-Host ("Installer: {0} ({1:N0} bytes)" -f (Split-Path $Installer -Leaf), (Get-Item -LiteralPath $Installer).Length)

$suffix = [System.Guid]::NewGuid().ToString('N').Substring(0, 8)
$userDir = Join-Path $tempRoot "tristan-user-$suffix"
$noPathDir = Join-Path $tempRoot "tristan-nopath-$suffix"
$machineDir = Join-Path $tempRoot "tristan-allusers-$suffix"
$settingsDir = Join-Path $env:APPDATA 'Tristan'
$settings = Join-Path $settingsDir 'settings.json'
$settingsDirExisted = Test-Path -LiteralPath $settingsDir
$settingsBefore = if (Test-Path -LiteralPath $settings) { [System.IO.File]::ReadAllBytes($settings) } else { $null }

try {
  # --- (a) per user, with the PATH task ---
  Write-Host '== per user, with "Add Tristan to my PATH"'
  $code = Install 'user-install' "/CURRENTUSER /DIR=`"$userDir`" /TASKS=`"addtopath`""
  Check "per-user install exits 0 (got $code)" ($code -eq 0)
  Test-InstalledFiles 'per-user install' $userDir
  $user = Get-PathValue 'HKCU'
  Write-Host "HKCU Path after install: $(Describe $user)"
  Check "HKCU Path contains the folder exactly once (found $(Get-EntryCount $user.Value $userDir))" ((Get-EntryCount $user.Value $userDir) -eq 1)
  Check "HKCU Path keeps its type ($($originalUser.Kind) -> $($user.Kind))" ($user.Kind -eq (Get-ExpectedPath $originalUser $userDir).Kind)
  Check 'HKCU Path is the old value plus ";<folder>", every other entry unchanged' (Test-SamePath $user (Get-ExpectedPath $originalUser $userDir))
  Check 'HKLM Path is unchanged by a per-user install' (Test-SamePath (Get-PathValue 'HKLM') $originalMachine)
  Check 'Add/Remove Programs entry is under HKCU' (Test-UninstallKey 'HKCU')
  Check 'no Add/Remove Programs entry under HKLM' (-not (Test-UninstallKey 'HKLM'))
  Check "Add/Remove Programs shows version $Version" ((Get-UninstallValue 'HKCU' 'DisplayVersion') -eq $Version)
  Check "Add/Remove Programs shows publisher 'Tristan contributors'" ((Get-UninstallValue 'HKCU' 'Publisher') -eq 'Tristan contributors')

  # --- (b) the same installer again: an upgrade in place (no /DIR: it must find the folder itself) ---
  Write-Host '== again over it (upgrade in place)'
  $code = Install 'user-upgrade' '/CURRENTUSER /TASKS="addtopath"'
  Check "reinstall exits 0 (got $code)" ($code -eq 0)
  Test-InstalledFiles 'after the reinstall' $userDir
  Check 'the reinstall used the same folder' (((Get-UninstallValue 'HKCU' 'InstallLocation') -replace '\\$', '') -ieq $userDir)
  Check 'still one uninstaller (no unins001.exe)' (-not (Test-Path -LiteralPath (Join-Path $userDir 'unins001.exe')))
  $user = Get-PathValue 'HKCU'
  Check "HKCU Path still contains the folder exactly once (found $(Get-EntryCount $user.Value $userDir))" ((Get-EntryCount $user.Value $userDir) -eq 1)
  Check 'HKCU Path after the reinstall equals the value after the first install' (Test-SamePath $user (Get-ExpectedPath $originalUser $userDir))

  # --- (c) user data survives the uninstall ---
  New-Item -ItemType Directory -Force $settingsDir | Out-Null
  if ($null -eq $settingsBefore) { [System.IO.File]::WriteAllText($settings, '{"ci":"installer test dummy"}') }
  $settingsBytes = [System.IO.File]::ReadAllBytes($settings)

  # --- (d) uninstall ---
  Write-Host '== uninstall (per user)'
  $result = Uninstall 'user-uninstall' $userDir 'HKCU'
  Check "unins000.exe started the uninstall (exit $($result.Code))" ($result.Code -eq 0)
  Check "the uninstall finished within 180 s (took $($result.Seconds) s)" $result.Finished
  Check 'the install folder is gone' (-not (Test-Path -LiteralPath $userDir))
  Check 'the Add/Remove Programs entry is gone' (-not (Test-UninstallKey 'HKCU'))
  $user = Get-PathValue 'HKCU'
  Write-Host "HKCU Path after uninstall: $(Describe $user)"
  Check 'HKCU Path equals the original exactly (value and type)' (Test-SamePath $user $originalUser)
  Check 'HKLM Path is unchanged' (Test-SamePath (Get-PathValue 'HKLM') $originalMachine)
  Check '%APPDATA%\Tristan\settings.json is kept by the uninstall, unchanged' ((Test-Path -LiteralPath $settings) -and ([System.Convert]::ToBase64String([System.IO.File]::ReadAllBytes($settings)) -ceq [System.Convert]::ToBase64String($settingsBytes)))

  # --- (e) per user, without the PATH task ---
  Write-Host '== per user, without the PATH task (/TASKS="")'
  $code = Install 'nopath-install' "/CURRENTUSER /DIR=`"$noPathDir`" /TASKS=`"`""
  Check "install without the PATH task exits 0 (got $code)" ($code -eq 0)
  Check 'tristan.exe is installed' (Test-Path -LiteralPath (Join-Path $noPathDir 'tristan.exe'))
  Check 'HKCU Path is unchanged without the PATH task' (Test-SamePath (Get-PathValue 'HKCU') $originalUser)
  $result = Uninstall 'nopath-uninstall' $noPathDir 'HKCU'
  Check "the uninstall finished within 180 s (took $($result.Seconds) s, exit $($result.Code))" ($result.Finished -and $result.Code -eq 0)
  Check 'the install folder is gone' (-not (Test-Path -LiteralPath $noPathDir))
  Check 'HKCU Path is still unchanged after the uninstall' (Test-SamePath (Get-PathValue 'HKCU') $originalUser)

  # --- (f) all users ---
  Write-Host '== all users (/ALLUSERS), with the PATH task'
  $code = Install 'allusers-install' "/ALLUSERS /DIR=`"$machineDir`" /TASKS=`"addtopath`""
  Check "all-users install exits 0 (got $code)" ($code -eq 0)
  Test-InstalledFiles 'all-users install' $machineDir
  $machine = Get-PathValue 'HKLM'
  Write-Host "HKLM Path after install: $(Describe $machine)"
  Check "HKLM Path contains the folder exactly once (found $(Get-EntryCount $machine.Value $machineDir))" ((Get-EntryCount $machine.Value $machineDir) -eq 1)
  Check "HKLM Path keeps its type ($($originalMachine.Kind) -> $($machine.Kind))" ($machine.Kind -eq $originalMachine.Kind)
  Check 'HKLM Path is the old value plus ";<folder>", every other entry unchanged' (Test-SamePath $machine (Get-ExpectedPath $originalMachine $machineDir))
  Check 'HKCU Path is unchanged by an all-users install' (Test-SamePath (Get-PathValue 'HKCU') $originalUser)
  Check 'Add/Remove Programs entry is under HKLM' (Test-UninstallKey 'HKLM')
  $result = Uninstall 'allusers-uninstall' $machineDir 'HKLM'
  Check "the all-users uninstall finished within 180 s (took $($result.Seconds) s, exit $($result.Code))" ($result.Finished -and $result.Code -eq 0)
  Check 'the install folder is gone' (-not (Test-Path -LiteralPath $machineDir))
  Check 'the HKLM Add/Remove Programs entry is gone' (-not (Test-UninstallKey 'HKLM'))
  Check 'HKLM Path equals the original exactly (value and type)' (Test-SamePath (Get-PathValue 'HKLM') $originalMachine)
  Check 'HKCU Path equals the original exactly (value and type)' (Test-SamePath (Get-PathValue 'HKCU') $originalUser)
} catch {
  Write-Host "FAIL: unexpected error: $($_.Exception.Message)"
  Write-Host $_.ScriptStackTrace
  $script:failures++
} finally {
  # Leave the runner as it was, whatever happened above.
  foreach ($case in @(@{ Dir = $userDir; Hive = 'HKCU' }, @{ Dir = $noPathDir; Hive = 'HKCU' }, @{ Dir = $machineDir; Hive = 'HKLM' })) {
    if (Test-Path -LiteralPath (Join-Path $case.Dir 'unins000.exe')) {
      Write-Host "cleanup: uninstalling $($case.Dir)"
      try { Uninstall "cleanup-$(Split-Path $case.Dir -Leaf)" $case.Dir $case.Hive 120 | Out-Null } catch { Write-Host "cleanup: $($_.Exception.Message)" }
    }
    if (Test-Path -LiteralPath $case.Dir) { Remove-Item -LiteralPath $case.Dir -Recurse -Force -ErrorAction SilentlyContinue }
  }
  foreach ($hive in 'HKCU', 'HKLM') {
    $base = Open-Base $hive
    try { $base.DeleteSubKeyTree($uninstallSubKey, $false) } catch { Write-Host "cleanup: $($_.Exception.Message)" } finally { $base.Dispose() }
  }
  if (-not (Test-SamePath (Get-PathValue 'HKCU') $originalUser)) { Write-Host 'cleanup: restoring HKCU Path'; Set-PathValue 'HKCU' $originalUser }
  if (-not (Test-SamePath (Get-PathValue 'HKLM') $originalMachine)) { Write-Host 'cleanup: restoring HKLM Path'; Set-PathValue 'HKLM' $originalMachine }
  if ($null -eq $settingsBefore) {
    if (Test-Path -LiteralPath $settings) { Remove-Item -LiteralPath $settings -Force }
    if (-not $settingsDirExisted -and (Test-Path -LiteralPath $settingsDir)) { Remove-Item -LiteralPath $settingsDir -Recurse -Force }
  } else {
    [System.IO.File]::WriteAllBytes($settings, $settingsBefore)
  }
}

Check 'the runner is left as it was: HKCU Path' (Test-SamePath (Get-PathValue 'HKCU') $originalUser)
Check 'the runner is left as it was: HKLM Path' (Test-SamePath (Get-PathValue 'HKLM') $originalMachine)
if ($script:failures -gt 0) {
  Write-Host "$($script:failures) check(s) failed. The installer logs are in ${LogDir}:"
  Get-ChildItem -LiteralPath $LogDir -File | ForEach-Object {
    Write-Host "===== $($_.Name) (last 60 lines)"
    Get-Content -LiteralPath $_.FullName -Tail 60 | ForEach-Object { Write-Host "| $_" }
  }
  exit 1
}
Write-Host 'All installer checks passed.'
exit 0
