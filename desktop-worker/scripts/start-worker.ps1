[CmdletBinding()]
param(
    [string]$ServerPath = "",
    [string]$HostAddress = "127.0.0.1",
    [ValidateRange(1, 65535)][int]$Port = 50052,
    [string]$Device = "",
    [int]$Threads = 0,
    [switch]$AllowLan
)

$ErrorActionPreference = "Stop"
if (-not $ServerPath) {
    $base = Join-Path $env:LOCALAPPDATA "PrivateLM\build-b11157\bin"
    $ServerPath = Join-Path $base "ggml-rpc-server.exe"
    if (-not (Test-Path -LiteralPath $ServerPath)) {
        $ServerPath = Join-Path $base "Release\ggml-rpc-server.exe"
    }
}
if (-not (Test-Path -LiteralPath $ServerPath -PathType Leaf)) {
    throw "RPC server executable not found: $ServerPath"
}

$address = $null
if (-not [System.Net.IPAddress]::TryParse($HostAddress, [ref]$address) -or
    $address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
    throw "HostAddress must be a valid IPv4 address"
}
if ($address.Equals([System.Net.IPAddress]::Any) -or
    ($address -ne [System.Net.IPAddress]::Loopback -and -not $AllowLan)) {
    throw "LAN bind requires a private IPv4 address and -AllowLan; wildcard binds are denied"
}
if ($address -ne [System.Net.IPAddress]::Loopback) {
    $octets = $HostAddress.Split('.') | ForEach-Object { [int]$_ }
    $private = $octets[0] -eq 10 -or
        ($octets[0] -eq 172 -and $octets[1] -ge 16 -and $octets[1] -le 31) -or
        ($octets[0] -eq 192 -and $octets[1] -eq 168)
    if (-not $private) { throw "LAN bind must use an RFC1918 private IPv4 address" }
}
if ($Device -and $Device -notmatch '^[A-Za-z0-9_.-]+$') {
    throw "Device name contains invalid characters"
}
if ($Threads -lt 0 -or $Threads -gt 256) {
    throw "Threads must be zero or an integer from 1 to 256"
}

$arguments = @("--host", $HostAddress, "--port", "$Port")
if ($Device) { $arguments += @("--device", $Device) }
if ($Threads -gt 0) { $arguments += @("--threads", "$Threads") }
[Console]::Error.WriteLine("Starting unauthenticated llama.cpp RPC server on ${HostAddress}:$Port. Press Ctrl-C to stop.")
& $ServerPath @arguments
exit $LASTEXITCODE
