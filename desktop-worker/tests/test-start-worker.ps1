$ErrorActionPreference = "Stop"
$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$temp = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $temp | Out-Null
$stub = Join-Path $temp "stub.ps1"
$capture = Join-Path $temp "args.txt"
Set-Content -LiteralPath $stub -Value '$args | Set-Content -LiteralPath $env:CAPTURE_ARGS'
$env:CAPTURE_ARGS = $capture

function Invoke-Worker {
    param([string[]]$WorkerArguments)
    $launcher = Join-Path $root "scripts\start-worker.ps1"
    $pwsh = (Get-Command pwsh).Source
    $arguments = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$launcher`"",
        "-ServerPath", "`"$stub`""
    ) + $WorkerArguments
    $process = Start-Process -FilePath $pwsh -ArgumentList $arguments -Wait -PassThru -NoNewWindow
    return $process.ExitCode
}
function Assert-Reject([string[]]$Arguments) {
    $exitCode = Invoke-Worker -WorkerArguments $Arguments
    if ($exitCode -eq 0) {
        throw "Expected rejection: $Arguments"
    }
}

try {
    if ((Invoke-Worker -WorkerArguments @()) -ne 0) { throw "Default launch failed" }
    $captured = Get-Content -LiteralPath $capture
    if ($captured -notcontains "127.0.0.1" -or $captured -notcontains "50052") {
        throw "Default launch arguments were incorrect: $captured"
    }
    Assert-Reject @("-HostAddress", "192.168.0.10")
    if ((Invoke-Worker -WorkerArguments @("-AllowLan", "-HostAddress", "192.168.0.10", "-Device", "CUDA0")) -ne 0) {
        throw "LAN launch failed"
    }
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
