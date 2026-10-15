param(
    [Parameter(Mandatory = $true)]
    [string]$Config,
    [Parameter(Mandatory = $true)]
    [string]$Rainmeter,
    [Parameter(Mandatory = $true)]
    [string]$Out,
    [Parameter(Mandatory = $true)]
    [string]$Status
)

$ErrorActionPreference = 'Stop'
$found = @()
$message = ''
$kind = 'ERROR'

function ConvertTo-IPv4Number([string]$Address) {
    $octets = $Address.Split('.') | ForEach-Object { [uint64]::Parse($_) }
    return [uint64]($octets[0] * 16777216 + $octets[1] * 65536 + $octets[2] * 256 + $octets[3])
}

function ConvertFrom-IPv4Number([uint64]$Number) {
    $a = [math]::Floor($Number / 16777216) % 256
    $b = [math]::Floor($Number / 65536) % 256
    $c = [math]::Floor($Number / 256) % 256
    $d = $Number % 256
    return "$a.$b.$c.$d"
}

try {
    $connectedIfIndexes = @{}
    Get-NetIPInterface -AddressFamily IPv4 -ErrorAction Stop |
        Where-Object { $_.ConnectionState -eq 'Connected' } |
        ForEach-Object { $connectedIfIndexes[[int]$_.InterfaceIndex] = $true }

    $networks = @{}
    Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
        Where-Object {
            $connectedIfIndexes.ContainsKey([int]$_.InterfaceIndex) -and
            $_.IPAddress -notmatch '^(127|169\.254|0)\.' -and
            $_.PrefixLength -ge 22 -and $_.PrefixLength -le 30
        } |
        ForEach-Object {
            $size = [uint64][math]::Pow(2, 32 - [int]$_.PrefixLength)
            $addressNumber = ConvertTo-IPv4Number $_.IPAddress
            $networkNumber = [uint64]([math]::Floor($addressNumber / $size) * $size)
            $networkKey = "$networkNumber/$($_.PrefixLength)"
            if (-not $networks.ContainsKey($networkKey)) {
                $networks[$networkKey] = @{
                    First = $networkNumber + 1
                    Last = $networkNumber + $size - 2
                }
            }
        }

    if ($networks.Count -eq 0) {
        throw 'No connected IPv4 subnet with 2-1022 host addresses was found'
    }

    foreach ($network in $networks.Values) {
        $clients = @{}
        $tasks = @()
        try {
            for ($number = $network.First; $number -le $network.Last; $number++) {
                $candidate = ConvertFrom-IPv4Number $number
                $client = New-Object System.Net.Sockets.TcpClient
                $clients[$candidate] = $client
                try {
                    $tasks += $client.ConnectAsync($candidate, 80)
                } catch {
                    $client.Close()
                }
            }
            if ($tasks.Count -gt 0) {
                try { [void][System.Threading.Tasks.Task]::WaitAll($tasks, 1500) } catch {}
            }

            foreach ($candidate in $clients.Keys) {
                if (-not $clients[$candidate].Connected) { continue }
                try {
                    $info = Invoke-RestMethod -Uri "http://$candidate/json/info" -TimeoutSec 2
                    if ($info.brand -eq 'WLED') {
                        $name = ([string]$info.name) -replace '[\r\n]', ' '
                        $found += "$candidate|$name"
                    }
                } catch {
                    # Open port 80 with a non-WLED response is expected during discovery.
                }
            }
        } finally {
            foreach ($client in $clients.Values) { $client.Close() }
        }
    }

    $found = @($found | Sort-Object { [version]($_.Split('|')[0]) })
    $kind = 'OK'
    if ($found.Count -eq 0) {
        $message = 'No WLED devices found on connected local networks'
    } else {
        $message = "Found $($found.Count) WLED device(s)"
    }
} catch {
    $found = @()
    $message = $_.Exception.Message -replace '[\r\n|]', ' '
}

$outTemp = "$Out.tmp"
$statusTemp = "$Status.tmp"
[System.IO.File]::WriteAllLines($outTemp, [string[]]$found, [System.Text.Encoding]::ASCII)
[System.IO.File]::WriteAllText($statusTemp, "$kind|$message", [System.Text.Encoding]::ASCII)
Move-Item -LiteralPath $outTemp -Destination $Out -Force
Move-Item -LiteralPath $statusTemp -Destination $Status -Force

$arguments = "!CommandMeasure Script `"LoadDevices()`" `"$Config`""
Start-Process -FilePath $Rainmeter -ArgumentList $arguments
