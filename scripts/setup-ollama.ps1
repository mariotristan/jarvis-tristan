<#
Sets up Ollama for the `tristan` command on Windows: checks that Ollama is installed, starts the server, pulls a model,
checks that it answers and whether it can use tools, and sets it as tristan's model. The Windows twin of
scripts/setup-ollama.sh.

  pwsh -File scripts\setup-ollama.ps1                  pulls llama3.1 (good all-round, handles tools)
  pwsh -File scripts\setup-ollama.ps1 qwen2.5-coder    pulls another model by name
  pwsh -File scripts\setup-ollama.ps1 -StartOnly       only starts the server if Ollama is installed (no download).
                                                       Without Ollama it says so and exits 0: there is nothing to start.
  pwsh -File scripts\setup-ollama.ps1 -NoPin           does not run `tristan config set ollama.model <model>`

It never installs anything by itself: when Ollama is missing it prints the winget command to run and stops.
It needs no secrets and sends nothing anywhere except the model download from Ollama's registry.
Exit status: 0 done (or nothing to start with -StartOnly), 1 a step failed, 2 a bad argument or Ollama is not installed.
Works in PowerShell 7 (pwsh) and Windows PowerShell 5.1.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Model = 'llama3.1',
    [switch]$StartOnly,
    [switch]$NoPin
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# The address tristan uses by default (`tristan config get ollama.host`). 127.0.0.1 rather than localhost, because
# localhost can resolve to ::1 first while Ollama listens on IPv4.
$BaseUrl = 'http://127.0.0.1:11434'
$WingetHint = 'winget install -e --id Ollama.Ollama'

function Say([string]$Text) { Write-Host "==> $Text" -ForegroundColor Cyan }
function Fail([string]$Text, [int]$Code = 1) {
    [Console]::Error.WriteLine("Error: $Text")
    exit $Code
}

# The same rule tristan applies to `ollama.model`: no spaces or shell characters, never something read as an option.
if ($Model -cnotmatch '\A[A-Za-z0-9_.:/@+][A-Za-z0-9_.:/@+-]*\z') {
    Fail "'$Model' is not a model name: use letters, digits and _ . : / @ + - only, not starting with -. For example: llama3.1" 2
}

# Ollama on PATH, else the folder its Windows installer uses for the current user.
function Find-Ollama {
    $command = Get-Command ollama -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    if ($env:LOCALAPPDATA) {
        $default = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'
        if (Test-Path -LiteralPath $default -PathType Leaf) { return $default }
    }
    return $null
}

function Test-Server {
    try {
        Invoke-RestMethod -Uri "$BaseUrl/api/tags" -TimeoutSec 2 -UseBasicParsing | Out-Null
        return $true
    } catch {
        return $false
    }
}

$ollama = Find-Ollama
if (-not $ollama) {
    if ($StartOnly) {
        Write-Host 'Ollama is not installed, so there is nothing to start.'
        exit 0
    }
    Fail "Ollama is not installed. Install it with: $WingetHint (or from https://ollama.com/download), open a new terminal and run this again." 2
}
Say "Ollama: $ollama"

$process = $null
$log = Join-Path ([System.IO.Path]::GetTempPath()) 'ollama-serve.log'
if (-not (Test-Server)) {
    Say 'Starting the Ollama server'
    $errorLog = Join-Path ([System.IO.Path]::GetTempPath()) 'ollama-serve.err.log'
    $process = Start-Process -FilePath $ollama -ArgumentList 'serve' -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $log -RedirectStandardError $errorLog
    $up = $false
    foreach ($attempt in 1..30) {
        if (Test-Server) { $up = $true; break }
        Start-Sleep -Seconds 1
    }
    if (-not $up) { Fail "The server did not start within 30 seconds. See $errorLog" }
}

if ($StartOnly) {
    Say 'Ollama is running'
    exit 0
}

Say "Pulling $Model (this can take a few minutes the first time)"
& $ollama pull $Model
if ($LASTEXITCODE -ne 0) { Fail "ollama pull $Model failed (exit status $LASTEXITCODE)." }

Say "Checking that $Model answers"
$body = @{ model = $Model; messages = @(@{ role = 'user'; content = 'Say hi in three words.' }) } | ConvertTo-Json -Depth 5
try {
    $reply = Invoke-RestMethod -Method Post -Uri "$BaseUrl/v1/chat/completions" -ContentType 'application/json' `
        -Body $body -TimeoutSec 300 -UseBasicParsing
} catch {
    Fail "The model did not answer: $($_.Exception.Message)"
}
# A reply that is not the chat-completions JSON (a proxy's HTML page, a stream, another server on this port) has no
# choices[0].message.content; under strict mode reading it throws, so it is read here and refused with a clear message.
$answer = $null
try { $answer = ([string]$reply.choices[0].message.content).Trim() } catch { $answer = $null }
if (-not $answer) {
    $shown = ([string]$reply) -replace '\s+', ' '
    if ($shown.Length -gt 200) { $shown = $shown.Substring(0, 200) + '...' }
    Fail "The reply from $BaseUrl was not an Ollama chat answer (expected JSON with choices[0].message.content). Got: $shown"
}
Write-Host "    $answer"

Say 'Checking tool support (tristan needs it to edit files and run commands)'
$tool = @{
    type     = 'function'
    function = @{
        name        = 'list_dir'
        description = 'List a folder'
        parameters  = @{ type = 'object'; properties = @{ path = @{ type = 'string' } }; required = @('path') }
    }
}
$toolsBody = @{ model = $Model; messages = @(@{ role = 'user'; content = 'What is in the folder?' }); tools = @($tool) } |
    ConvertTo-Json -Depth 10
try {
    Invoke-RestMethod -Method Post -Uri "$BaseUrl/v1/chat/completions" -ContentType 'application/json' `
        -Body $toolsBody -TimeoutSec 300 -UseBasicParsing | Out-Null
    Say 'Tools are supported'
} catch {
    $detail = $_.Exception.Message
    if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $detail = $_.ErrorDetails.Message }
    if ($detail -match 'does not support tools') {
        Write-Warning "$Model cannot use tools. It is fine for questions (kids mode) but not for coding. Try: scripts\setup-ollama.ps1 llama3.1"
    } else {
        Write-Warning "Could not check tool support: $detail"
    }
}

if (-not $NoPin) {
    $tristan = Get-Command tristan -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($tristan) {
        Say "Setting $Model as tristan's model (tristan config set ollama.model $Model)"
        & $tristan.Source config set ollama.model $Model
        if ($LASTEXITCODE -ne 0) { Write-Warning "tristan did not save the model (exit status $LASTEXITCODE); the model itself is ready." }
    } else {
        Say "tristan is not on PATH. Once it is, run: tristan config set ollama.model $Model"
    }
}

Write-Host ''
Say 'Installed models:'
& $ollama list
Write-Host ''
Say 'Done. Try: tristan providers, then tristan run --provider ollama "explain this project"'
if ($process) {
    Say "The server was started by this script and keeps running in the background (log: $log). Stop it with: Stop-Process -Id $($process.Id)"
}
exit 0
