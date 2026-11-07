# Self-test for check-test-count.ps1: feeds it made-up `swift test` logs and checks it accepts or rejects each.
# Runs in windows.yml before the real test steps. Exits 1 if any case comes out wrong.
$ErrorActionPreference = 'Stop'
$checker = Join-Path $PSScriptRoot 'check-test-count.ps1'
$dir = Join-Path ([IO.Path]::GetTempPath()) ("tristan-count-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $dir | Out-Null
$failures = 0

function Check-Log($name, $minimum, $expectPass, [string[]]$lines) {
  $file = Join-Path $dir "$name.log"
  Set-Content -LiteralPath $file -Value $lines -Encoding utf8
  & pwsh -NoProfile -File $checker -LogFile $file -Minimum $minimum | Out-Host
  $passed = ($LASTEXITCODE -eq 0)
  if ($passed -eq $expectPass) { Write-Host "PASS: $name" } else { Write-Host "FAIL: $name (exit $LASTEXITCODE)"; $script:failures++ }
}

# The shape windows-latest prints: one top-level suite per test executable, the empty one first or last.
$core = @(
  "Test Suite 'Selected tests' started at 2026-11-07 13:48:40.697",
  "`t Executed 25 tests, with 0 failures (0 unexpected) in 11.514 (11.514) seconds",
  "`t Executed 204 tests, with 0 failures (0 unexpected) in 70.0 (70.0) seconds",
  "Test Suite 'Selected tests' passed at 2026-11-07 13:50:07.848",
  "`t Executed 229 tests, with 0 failures (0 unexpected) in 87.14 (87.14) seconds",
  "Test Suite 'Selected tests' started at 2026-11-07 13:50:07.924",
  "Test Suite 'Selected tests' passed at 2026-11-07 13:50:07.927",
  "`t Executed 0 tests, with 0 failures (0 unexpected) in 0.0 (0.0) seconds",
  "Test run with 0 tests passed after 0.001 seconds."
)
# A filter that matches nothing: every executable reports zero.
$none = @(
  "Test Suite 'Selected tests' started at 2026-11-07 13:50:22.858",
  "Test Suite 'Selected tests' passed at 2026-11-07 13:50:22.860",
  "`t Executed 0 tests, with 0 failures (0 unexpected) in 0.0 (0.0) seconds",
  "Test Suite 'Selected tests' started at 2026-11-07 13:50:22.924",
  "Test Suite 'Selected tests' passed at 2026-11-07 13:50:22.927",
  "`t Executed 0 tests, with 0 failures (0 unexpected) in 0.0 (0.0) seconds",
  "Test run with 0 tests passed after 0.001 seconds."
)
# The Mac shape: 'All tests' around the bundle, which repeats the same total (counted once).
$mac = @(
  "Test Suite 'All tests' started at 2026-11-07 13:48:40.697",
  "Test Suite 'TristanPackageTests.xctest' started at 2026-11-07 13:48:40.697",
  "Test Suite 'TristanPackageTests.xctest' passed at 2026-11-07 13:50:07.848",
  "`t Executed 109 tests, with 0 failures (0 unexpected) in 7.6 (7.6) seconds",
  "Test Suite 'All tests' passed at 2026-11-07 13:50:07.848",
  "`t Executed 109 tests, with 0 failures (0 unexpected) in 7.6 (7.6) seconds"
)

Check-Log 'core-229-min-200' 200 $true $core
Check-Log 'core-229-min-300' 300 $false $core
Check-Log 'no-tests-matched' 100 $false $none
Check-Log 'no-summary-at-all' 1 $false @('Build complete!', 'error: no tests found; create a target in the Tests directory')
Check-Log 'mac-109-counted-once-min-100' 100 $true $mac
Check-Log 'mac-109-counted-once-min-200' 200 $false $mac

Remove-Item -Recurse -Force -LiteralPath $dir
if ($failures) { Write-Host "::error::check-test-count.ps1 self-test: $failures case(s) wrong"; exit 1 }
Write-Host 'check-test-count.ps1 self-test: all cases right.'
