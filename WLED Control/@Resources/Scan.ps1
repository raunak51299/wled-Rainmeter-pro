param(
    [string]$Config,
    [string]$Rainmeter,
    [string]$Out
)

# Scans every local IPv4 /24 for WLED devices (port 80, /json/info with brand WLED).
$found = @()
try {
    $subnets = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
        Where-Object { $_.IPAddress -notmatch '^(127|169\.254)\.' -and $_.PrefixOrigin -ne 'WellKnown' } |
        ForEach-Object { ($_.IPAddress -split '\.')[0..2] -join '.' } | Select-Object -Unique

    foreach ($net in $subnets) {
        $clients = @{}
        $tasks = @()
        foreach ($i in 1..254) {
            $ip = "$net.$i"
            $c = New-Object System.Net.Sockets.TcpClient
            $clients[$ip] = $c
            $tasks += $c.ConnectAsync($ip, 80)
        }
        try { [void][System.Threading.Tasks.Task]::WaitAll($tasks, 2000) } catch {}

        foreach ($ip in $clients.Keys) {
            if (-not $clients[$ip].Connected) { continue }
            try {
                $info = Invoke-RestMethod -Uri "http://$ip/json/info" -TimeoutSec 2
                if ($info.brand -eq 'WLED') { $found += "$ip|$($info.name)" }
            } catch {}
        }
        foreach ($c in $clients.Values) { $c.Close() }
    }
} catch {}

[System.IO.File]::WriteAllLines($Out, [string[]]$found)

$args2 = "!CommandMeasure Script `"LoadDevices()`" `"$Config`""
Start-Process -FilePath $Rainmeter -ArgumentList $args2
