# What a PowerShell script started with -File received.
"powershell -File: $($args.Count) argument(s)"
for ($i = 0; $i -lt $args.Count; $i++) { "  [$i] " + (ConvertTo-Json -Compress -InputObject ([string]$args[$i])) }
