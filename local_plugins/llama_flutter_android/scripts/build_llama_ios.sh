#!/usr/bin/env bash
# Builds llama.cpp for iOS devices (arm64) as one static library, from the
# same llama.cpp tree the Android build uses, so iOS and Android run the same
# engine and speak the same phone-cluster (RPC) protocol version.
#
# Output (vendored by ios/llama_flutter_android.podspec):
#   ios/llama_ios/lib/libllama_ios.a   llama + ggml (CPU, Metal, RPC)
#   ios/llama_ios/include/             llama.h, ggml*.h, gguf.h
#
# Usage: local_plugins/llama_flutter_android/scripts/build_llama_ios.sh
# Needs Xcode and CMake (brew install cmake). Re-run after updating llama.cpp.
set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LLAMA_SRC="$PLUGIN_DIR/android/src/main/cpp/llama.cpp"
OUT="$PLUGIN_DIR/ios/llama_ios"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT

# The bundled llama.cpp tree has its tools/examples stripped, so build it as
# a subproject (as the Android CMakeLists does), which leaves those off.
mkdir -p "$BUILD/wrapper"
cat > "$BUILD/wrapper/CMakeLists.txt" <<EOF
cmake_minimum_required(VERSION 3.22)
project(llama_ios C CXX OBJC OBJCXX)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_METAL ON CACHE BOOL "" FORCE)
set(GGML_METAL_EMBED_LIBRARY ON CACHE BOOL "" FORCE)
set(GGML_RPC ON CACHE BOOL "" FORCE)
set(GGML_RPC_RDMA OFF CACHE BOOL "" FORCE)
set(GGML_BLAS OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
add_subdirectory("$LLAMA_SRC" llama)
EOF

cmake -S "$BUILD/wrapper" -B "$BUILD/out" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT=iphoneos \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0

cmake --build "$BUILD/out" --target llama ggml ggml-base ggml-cpu ggml-metal ggml-rpc -j "$(sysctl -n hw.ncpu)"

rm -rf "$OUT"
mkdir -p "$OUT/lib" "$OUT/include"
# One archive, so the podspec vendors a single file.
libtool -static -o "$OUT/lib/libllama_ios.a" $(find "$BUILD/out" -name "*.a")
cp "$LLAMA_SRC"/include/*.h "$OUT/include/"
cp "$LLAMA_SRC"/ggml/include/*.h "$OUT/include/"
echo "Built $OUT/lib/libllama_ios.a ($(du -h "$OUT/lib/libllama_ios.a" | cut -f1))"
