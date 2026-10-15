param(
    [Parameter(Mandatory = $true)]
    [string]$Address,
    [Parameter(Mandatory = $true)]
    [string]$Payload,
    [Parameter(Mandatory = $true)]
    [string]$Result
)

$status = 'ERROR|request failed'
try {
    $validIpv4 = $false
    [System.Net.IPAddress]$parsedAddress = $null
    if ([System.Net.IPAddress]::TryParse($Address, [ref]$parsedAddress) -and
        $parsedAddress.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
        $validIpv4 = $true
    }
    $validHost = $Address -match '^(?=.{1,253}$)([a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)(\.([a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?))*$'
    if ($Address -match '^[0-9.]+$' -and -not $validIpv4) {
        $validHost = $false
    }
    if (-not ($validIpv4 -or $validHost)) {
        throw 'Invalid device address'
    }
    if (-not (Test-Path -LiteralPath $Payload -PathType Leaf)) {
        throw 'Request payload is missing'
    }

    $curlOutput = & curl.exe --silent --show-error --max-time 8 `
        --output NUL --write-out '%{http_code}' `
        --header 'Content-Type: application/json' `
        --data-binary "@$Payload" "http://$Address/json/state" 2>$null
    $curlExit = $LASTEXITCODE
    $httpCode = ($curlOutput | Out-String).Trim()
    if ($curlExit -ne 0) {
        $status = "ERROR|curl error $curlExit"
    } elseif ($httpCode -notmatch '^2\d\d$') {
        $status = "ERROR|HTTP $httpCode"
    } else {
        $status = "OK|HTTP $httpCode"
    }
} catch {
    $message = $_.Exception.Message -replace '[\r\n|]', ' '
    $status = "ERROR|$message"
}

$temporary = "$Result.tmp"
[System.IO.File]::WriteAllText($temporary, $status, [System.Text.Encoding]::ASCII)
Move-Item -LiteralPath $temporary -Destination $Result -Force
