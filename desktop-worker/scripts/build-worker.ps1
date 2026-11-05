[CmdletBinding()]
param([switch]$Cuda)

$ErrorActionPreference = "Stop"
$commit = "53ed051ce5e8193652e449f43216ca3859454f49"
$root = Join-Path $env:LOCALAPPDATA "PrivateLM"
$source = Join-Path $root "llama.cpp-b11157"
$build = Join-Path $root "build-b11157"

if (-not (Test-Path (Join-Path $source ".git"))) {
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    git clone --filter=blob:none https://github.com/ggml-org/llama.cpp.git $source
    if ($LASTEXITCODE -ne 0) { throw "git clone failed with exit code $LASTEXITCODE" }
}
$changes = git -C $source status --porcelain
if ($LASTEXITCODE -ne 0) { throw "Could not inspect source tree" }
if ($changes) { throw "Source tree has local changes: $source" }
git -C $source fetch --depth 1 origin $commit
if ($LASTEXITCODE -ne 0) { throw "git fetch failed with exit code $LASTEXITCODE" }
git -C $source checkout --detach $commit
if ($LASTEXITCODE -ne 0) { throw "git checkout failed with exit code $LASTEXITCODE" }
$actual = git -C $source rev-parse HEAD
if ($actual.Trim() -ne $commit) { throw "Source commit mismatch: $actual" }

$configure = @(
    "-S", $source, "-B", $build, "-DCMAKE_BUILD_TYPE=Release",
    "-DGGML_RPC=ON", "-DGGML_CUDA=OFF", "-DGGML_METAL=OFF",
    "-DLLAMA_BUILD_TESTS=OFF", "-DLLAMA_BUILD_EXAMPLES=OFF",
    "-DLLAMA_BUILD_SERVER=OFF", "-DLLAMA_BUILD_APP=OFF", "-DLLAMA_BUILD_TOOLS=ON"
)
if ($Cuda) { $configure += "-DGGML_CUDA=ON" }
cmake @configure
if ($LASTEXITCODE -ne 0) { throw "CMake configure failed with exit code $LASTEXITCODE" }
cmake --build $build --config Release --target ggml-rpc-server --parallel
if ($LASTEXITCODE -ne 0) { throw "RPC worker build failed with exit code $LASTEXITCODE" }
Write-Output "Built ggml-rpc-server from $commit at $build."
