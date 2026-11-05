#!/usr/bin/env bash
set -euo pipefail

readonly LLAMA_REPOSITORY=https://github.com/ggml-org/llama.cpp.git
readonly LLAMA_COMMIT=53ed051ce5e8193652e449f43216ca3859454f49
cache_root="${XDG_CACHE_HOME:-${HOME:?HOME is not set}/.cache}/privatelm-rpc-worker"
source_dir="$cache_root/llama.cpp-b11157"
build_dir="$cache_root/build-b11157"
backend=cpu

usage() {
  cat <<'EOF'
Build llama.cpp ggml-rpc-server at the Android-compatible b11157 commit.

Usage: build-worker.sh [--cuda | --metal] [--source PATH] [--build-dir PATH]

CPU is the default. Use --cuda on supported NVIDIA hosts or --metal on macOS.
The build requires Git and CMake. A backend SDK is required for CUDA or Metal.
EOF
}

while (($#)); do
  case "$1" in
    --cuda) [[ "$backend" == cpu ]] || { echo 'select one backend' >&2; exit 2; }; backend=cuda; shift ;;
    --metal) [[ "$backend" == cpu ]] || { echo 'select one backend' >&2; exit 2; }; backend=metal; shift ;;
    --source|--build-dir)
      (($# >= 2)) || { echo "missing value for $1" >&2; exit 2; }
      if [[ "$1" == --source ]]; then source_dir="$2"; else build_dir="$2"; fi
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ ! -d "$source_dir/.git" ]]; then
  mkdir -p "$(dirname "$source_dir")"
  git clone --filter=blob:none "$LLAMA_REPOSITORY" "$source_dir"
fi
[[ -z "$(git -C "$source_dir" status --porcelain)" ]] || { echo "source tree has local changes: $source_dir" >&2; exit 1; }
git -C "$source_dir" fetch --depth 1 origin "$LLAMA_COMMIT"
git -C "$source_dir" checkout --detach "$LLAMA_COMMIT"
actual_commit="$(git -C "$source_dir" rev-parse HEAD)"
[[ "$actual_commit" == "$LLAMA_COMMIT" ]] || { echo "source commit mismatch: $actual_commit" >&2; exit 1; }

cmake_args=(-S "$source_dir" -B "$build_dir" -DCMAKE_BUILD_TYPE=Release -DGGML_RPC=ON -DGGML_CUDA=OFF -DGGML_METAL=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_APP=OFF -DLLAMA_BUILD_TOOLS=ON)
case "$backend" in
  cuda) cmake_args+=(-DGGML_CUDA=ON) ;;
  metal) cmake_args+=(-DGGML_METAL=ON) ;;
esac
cmake "${cmake_args[@]}"
cmake --build "$build_dir" --target ggml-rpc-server --parallel "${BUILD_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"
printf 'Built ggml-rpc-server at %s/bin/ggml-rpc-server from %s (%s backend).\n' "$build_dir" "$actual_commit" "$backend"
