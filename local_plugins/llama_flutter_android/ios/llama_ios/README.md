# llama.cpp for iOS (prebuilt)

`llama_flutter_android.podspec` links llama.cpp as one static library built
from the same source tree as the Android build
(`android/src/main/cpp/llama.cpp`), so both platforms run the same engine and
speak the same phone-cluster (RPC) protocol version:

- `lib/libllama_ios.a` — llama + ggml with CPU, Metal and RPC (~10 MB)
- `include/` — `llama.h`, `ggml*.h`, `gguf.h`

## Building

These files aren't committed. Build them before the first iOS build, and again
after updating llama.cpp:

```bash
local_plugins/llama_flutter_android/scripts/build_llama_ios.sh
```

Needs Xcode and CMake (`brew install cmake`). Device (arm64) only.
