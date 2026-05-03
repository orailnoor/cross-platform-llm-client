# LiteRT-LM iOS XCFrameworks

This directory contains XCFrameworks built from Google's LiteRT-LM source:

- `LiteRTLM.xcframework` — static library + headers + module map (~321 MB)
- `GemmaModelConstraintProvider.xcframework` — constrained decoding (~48 MB)

## Building

LiteRT-LM ships no prebuilt iOS runtime, so these frameworks must be built
from source. Run the helper script:

```bash
bash scripts/build_ios_frameworks.sh
```

First run takes 30-60 minutes (Bazel downloads ~2 GB of deps + compiles
TFLite, protobuf, etc.). Subsequent runs are cached.

Prerequisites: Xcode 16.2+, Bazelisk (`brew install bazelisk`), Git LFS.

These framework bundles are gitignored — each user must build them locally
on an Apple Silicon Mac.
