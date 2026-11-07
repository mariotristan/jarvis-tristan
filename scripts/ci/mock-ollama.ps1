# A stand-in for Ollama, for the Windows smoke test. Listens on 127.0.0.1 only and serves exactly what the core calls
# (Sources/TristanCore/OllamaProvider.swift):
#   GET  /api/tags              -> one installed model, "<Model>:latest"
#   POST /v1/chat/completions   -> a streamed (server-sent events, chunked) answer in two pieces, DelayMs apart
# Anything else gets 404. Every request is logged as "<time> <method> <path>". Stops after Seconds, or when killed.
param(
    [int]$Port = 11434,
    [string]$Model = 'mock',
    [string]$First = 'Hello from ',
    [string]$Second = 'the mock Ollama.',
    [int]$DelayMs = 700,
    [int]$Seconds = 600
)
$ErrorActionPreference = 'Stop'
$ascii = [System.Text.Encoding]::ASCII
$utf8 = [System.Text.UTF8Encoding]::new($false)

function Write-Bytes($stream, [byte[]]$bytes) { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush() }

# Reads the request line, the headers and a Content-Length body. Answers "Expect: 100-continue" (libcurl sends it
# for bodies over 1 KB) before reading the body.
function Read-Request($stream) {
    $head = [System.Collections.Generic.List[byte]]::new()
    $one = [byte[]]::new(1)
    while ($true) {
        if ($stream.Read($one, 0, 1) -le 0) { return $null }
        $head.Add($one[0])
        $n = $head.Count
        if ($n -ge 4 -and $head[$n - 4] -eq 13 -and $head[$n - 3] -eq 10 -and $head[$n - 2] -eq 13 -and $head[$n - 1] -eq 10) { break }
        if ($n -gt 65536) { return $null }
    }
    $lines = $ascii.GetString($head.ToArray()) -split "`r`n"
    $request = $lines[0] -split ' '
    $length = 0
    $continue = $false
    foreach ($line in $lines | Select-Object -Skip 1) {
        if ($line -match '^(?i)content-length:\s*(\d+)\s*$') { $length = [int]$Matches[1] }
        if ($line -match '^(?i)expect:\s*100-continue') { $continue = $true }
    }
    if ($continue) { Write-Bytes $stream $ascii.GetBytes("HTTP/1.1 100 Continue`r`n`r`n") }
    $body = [byte[]]::new($length)
    $read = 0
    while ($read -lt $length) {
        $got = $stream.Read($body, $read, $length - $read)
        if ($got -le 0) { break }
        $read += $got
    }
    return @{ Method = $request[0]; Path = ($request[1] -split '\?')[0]; Body = $utf8.GetString($body, 0, $read) }
}

function Send-Whole($stream, [int]$status, [string]$reason, [string]$type, [string]$text) {
    $body = $utf8.GetBytes($text)
    Write-Bytes $stream $ascii.GetBytes("HTTP/1.1 $status $reason`r`nContent-Type: $type`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n")
    Write-Bytes $stream $body
}

function Send-Chunk($stream, [string]$text) {
    $data = $utf8.GetBytes($text)
    Write-Bytes $stream $ascii.GetBytes(('{0:x}' -f $data.Length) + "`r`n")
    Write-Bytes $stream $data
    Write-Bytes $stream $ascii.GetBytes("`r`n")
}

function Event([string]$content, $finish) {
    $choice = [ordered]@{ index = 0; delta = [ordered]@{ role = 'assistant'; content = $content }; finish_reason = $finish }
    'data: ' + ([ordered]@{ model = "${Model}:latest"; choices = @($choice) } | ConvertTo-Json -Depth 6 -Compress) + "`n`n"
}

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
$listener.Start()
Write-Host "mock-ollama listening on 127.0.0.1:$Port"
$deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
try {
    while ([DateTime]::UtcNow -lt $deadline) {
        if (-not $listener.Pending()) { Start-Sleep -Milliseconds 50; continue }
        $client = $listener.AcceptTcpClient()
        try {
            $stream = $client.GetStream()
            $stream.ReadTimeout = 10000
            $request = Read-Request $stream
            if (-not $request) { continue }
            Write-Host ("{0:HH:mm:ss.fff} {1} {2}" -f [DateTime]::Now, $request.Method, $request.Path)
            if ($request.Method -eq 'GET' -and $request.Path -eq '/api/tags') {
                Send-Whole $stream 200 'OK' 'application/json' (@{ models = @(@{ name = "${Model}:latest"; model = "${Model}:latest" }) } | ConvertTo-Json -Depth 4 -Compress)
            } elseif ($request.Method -eq 'POST' -and $request.Path -eq '/v1/chat/completions') {
                Write-Bytes $stream $ascii.GetBytes("HTTP/1.1 200 OK`r`nContent-Type: text/event-stream`r`nTransfer-Encoding: chunked`r`nConnection: close`r`n`r`n")
                Send-Chunk $stream (Event $First $null)
                Write-Host ("{0:HH:mm:ss.fff} sent chunk 1" -f [DateTime]::Now)
                Start-Sleep -Milliseconds $DelayMs
                Send-Chunk $stream ((Event $Second 'stop') + "data: [DONE]`n`n")
                Write-Host ("{0:HH:mm:ss.fff} sent chunk 2" -f [DateTime]::Now)
                Write-Bytes $stream $ascii.GetBytes("0`r`n`r`n")
            } else {
                Send-Whole $stream 404 'Not Found' 'application/json' '{"error":"not found"}'
            }
        } catch {
            Write-Host "request failed: $_"
        } finally {
            $client.Close()
        }
    }
} finally {
    $listener.Stop()
}
