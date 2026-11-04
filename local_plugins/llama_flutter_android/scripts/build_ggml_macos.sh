#!/usr/bin/env bash
# Builds the ggml libraries a macOS device-cluster worker needs (CPU + Metal
# + RPC) from the same llama.cpp tree the Android and iOS builds use. The
# RPC protocol is version-specific, so all cluster nodes must be built from
# the same tree.
#
# Output (vendored by macos/llama_flutter_android.podspec):
#   macos/llama/lib/libggml_macos.a   ggml, ggml-cpu, ggml-metal, ggml-rpc
#   macos/llama/include/              ggml*.h
#
# Usage:
#   local_plugins/llama_flutter_android/scripts/build_ggml_macos.sh
#
# Set ARCHS=arm64;x86_64 for a universal build, or GGML_METAL=OFF for a
# CPU-only build/toolchain test. Needs Xcode (for the Metal compiler) and
# CMake (brew install cmake).
set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LLAMA_SRC="$PLUGIN_DIR/android/src/main/cpp/llama.cpp"
OUT="$PLUGIN_DIR/macos/llama"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

GGML_METAL="${GGML_METAL:-ON}"
ARCHS="${ARCHS:-$(uname -m)}"
GENERATOR="${CMAKE_GENERATOR:-Unix Makefiles}"

mkdir -p "$BUILD/wrapper"
cat > "$BUILD/wrapper/CMakeLists.txt" <<EOF
cmake_minimum_required(VERSION 3.22)
project(ggml_macos C CXX OBJC OBJCXX)
set(CMAKE_CXX_STANDARD 17)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_METAL ${GGML_METAL} CACHE BOOL "" FORCE)
set(GGML_METAL_EMBED_LIBRARY ${GGML_METAL} CACHE BOOL "" FORCE)
set(GGML_RPC ON CACHE BOOL "" FORCE)
set(GGML_RPC_RDMA OFF CACHE BOOL "" FORCE)
set(GGML_BLAS OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_SERVER OFF CACHE BOOL "" FORCE)
set(LLAMA_BUILD_MTMD OFF CACHE BOOL "" FORCE)
add_subdirectory("$LLAMA_SRC" llama)
EOF

cmake -S "$BUILD/wrapper" -B "$BUILD/out" -G "$GENERATOR" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES="$ARCHS" \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=11.0

TARGETS=(ggml ggml-base ggml-cpu ggml-rpc)
if [ "$GGML_METAL" = "ON" ]; then
  TARGETS+=(ggml-metal)
fi
cmake --build "$BUILD/out" --target "${TARGETS[@]}" -j "$(sysctl -n hw.ncpu)"

rm -rf "$OUT/lib" "$OUT/include"
mkdir -p "$OUT/lib" "$OUT/include"
libtool -static -o "$OUT/lib/libggml_macos.a" $(find "$BUILD/out" -name "*.a")
cp "$LLAMA_SRC"/ggml/include/*.h "$OUT/include/"
echo "Built $OUT/lib/libggml_macos.a ($(du -h "$OUT/lib/libggml_macos.a" | cut -f1), arch $ARCHS, Metal $GGML_METAL)"
