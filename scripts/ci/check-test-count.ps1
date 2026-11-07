# Runs `swift test --filter <Filter>` and fails unless the tests pass AND at least <Minimum> of them ran.
# `swift test --filter` succeeds when the filter matches nothing, so a renamed test target or a typo would otherwise
# pass with zero tests. Used by windows.yml and release.yml so the two gates cannot drift.
#
#   pwsh -File scripts/ci/check-test-count.ps1 -Filter TristanCoreTests -Minimum 200
#   pwsh -File scripts/ci/check-test-count.ps1 -LogFile some.log -Minimum 200   # check a saved log (self-test)
#
# The count is the sum of the XCTest summary lines that close a top-level suite ("Test Suite 'Selected tests'
# passed|failed" or "'All tests'"), one per test executable. Per-class lines and swift-testing's own summary
# ("Test run with 0 tests") are not counted.
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][int]$Minimum,
  [string]$Filter,
  [string]$LogFile
)

function Get-ExecutedCount([string[]]$Lines) {
  $total = 0
  $found = $false
  $afterSuite = $false
  foreach ($line in $Lines) {
    if ($line -match "Test Suite '(Selected tests|All tests)' (passed|failed)") { $afterSuite = $true; continue }
    if ($afterSuite -and $line -match 'Executed (\d+) tests?, with') {
      $total += [int]$Matches[1]
      $found = $true
      $afterSuite = $false
    }
  }
  if ($found) { return $total } else { return -1 }
}

if ($LogFile) {
  $lines = @(Get-Content -LiteralPath $LogFile)
  $exitCode = 0
  $label = $LogFile
} elseif ($Filter) {
  $ErrorActionPreference = 'Continue'   # swift writes progress to stderr; the exit code is checked below
  $lines = @(& swift test --filter $Filter 2>&1 | ForEach-Object { $s = "$_"; Write-Host $s; $s })
  $exitCode = $LASTEXITCODE
  $label = "swift test --filter $Filter"
} else {
  Write-Host '::error::check-test-count.ps1 needs -Filter or -LogFile'
  exit 2
}

$count = Get-ExecutedCount $lines
if ($exitCode -ne 0) {
  Write-Host "::error::$label failed (exit $exitCode, tests executed: $count)"
  exit $exitCode
}
if ($count -lt 0) {
  Write-Host "::error::$label printed no XCTest summary line ('Executed N tests'): did the filter match nothing?"
  exit 1
}
if ($count -lt $Minimum) {
  Write-Host "::error::$label ran $count tests, fewer than the expected minimum of ${Minimum}: did the filter or a test target change?"
  exit 1
}
Write-Host "$label ran $count tests (minimum $Minimum)."
exit 0
