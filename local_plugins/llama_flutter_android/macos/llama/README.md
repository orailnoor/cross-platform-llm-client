# ggml for macOS (prebuilt)

`llama_flutter_android.podspec` links the ggml libraries as one static
library built from the same source tree as the Android and iOS builds, so all
cluster nodes speak the same RPC protocol version:

- `lib/libggml_macos.a` — ggml, ggml-cpu, ggml-metal and ggml-rpc
- `include/` — `ggml.h`, `ggml-backend.h`, `ggml-rpc.h`, …

## Building

These files aren't committed. Build them before the first macOS build, and
again after updating llama.cpp:

```bash
local_plugins/llama_flutter_android/scripts/build_ggml_macos.sh
```

Needs Xcode (for the Metal compiler) and CMake (`brew install cmake`). The
script builds for the host architecture by default; pass
`ARCHS="arm64;x86_64"` for a universal library, or `GGML_METAL=OFF` for a
CPU-only build.

The macOS app is a cluster **worker** only: it serves its Metal GPU (or CPU)
to an Android master. Local model inference on macOS is not part of this
build.
