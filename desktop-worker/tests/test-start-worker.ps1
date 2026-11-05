$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$temp = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $temp | Out-Null
$stub = Join-Path $temp "stub.ps1"
$capture = Join-Path $temp "args.txt"
Set-Content -LiteralPath $stub -Value '$args | Set-Content -LiteralPath $env:CAPTURE_ARGS'
$env:CAPTURE_ARGS = $capture

function Invoke-Worker([string[]]$Arguments) {
    & (Join-Path $root "scripts\start-worker.ps1") -ServerPath $stub @Arguments
}
function Assert-Reject([string[]]$Arguments) {
    try {
        Invoke-Worker -Arguments $Arguments
        throw "Expected rejection: $Arguments"
    } catch {
        if ($_.Exception.Message -like "Expected rejection:*") { throw }
    }
}

try {
    Invoke-Worker @()
    $captured = Get-Content -LiteralPath $capture
    if ($captured -notcontains "127.0.0.1" -or $captured -notcontains "50052") {
        throw "Default launch arguments were incorrect: $captured"
    }
    Assert-Reject @("-HostAddress", "192.168.0.10")
    Invoke-Worker @("-AllowLan", "-HostAddress", "192.168.0.10", "-Device", "CUDA0")
    $captured = Get-Content -LiteralPath $capture
    if ($captured -notcontains "192.168.0.10" -or $captured -notcontains "CUDA0") {
        throw "LAN launch arguments were incorrect: $captured"
    }
    Assert-Reject @("-AllowLan", "-HostAddress", "0.0.0.0")
    Assert-Reject @("-AllowLan", "-HostAddress", "8.8.8.8")
    Assert-Reject @("-HostAddress", "bad-ip")
    Assert-Reject @("-Port", "0")
    Assert-Reject @("-Threads", "-1")
    Assert-Reject @("-Device", "CUDA0;Get-Process")
    Write-Output "Windows worker launcher safety tests passed"
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force
    Remove-Item Env:CAPTURE_ARGS -ErrorAction SilentlyContinue
}
