# A local streaming server for the spike: every request gets line 1, a one second pause, then line 2 (chunked).
param([int]$Port = 18080)
$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()
Write-Host "stream-server listening on $Port"
while ($listener.IsListening) {
    $context = $listener.GetContext()
    $response = $context.Response
    $response.SendChunked = $true
    $response.ContentType = 'application/x-ndjson'
    $writer = [System.IO.StreamWriter]::new($response.OutputStream)
    $writer.AutoFlush = $true
    $writer.Write("{`"line`":1}`n")
    Start-Sleep -Seconds 1
    $writer.Write("{`"line`":2}`n")
    $writer.Close()
    $response.Close()
}
