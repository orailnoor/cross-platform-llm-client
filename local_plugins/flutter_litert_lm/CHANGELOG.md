# Changelog

All notable changes to `flutter_litert_lm` are documented in this file. The
format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.3.0] — 2026-04-11

### Changed
- **Bumped LiteRT-LM runtime to upstream `176953b` (2026-04-11)**, up from
  the `12db62a` snapshot v0.2.0 shipped. The new runtime understands the
  `multi-prefill-seq_q8_ekv4096` packaging format that HuggingFace
  `litert-community` now uses for every non-Gemma model
  (Qwen 2.5 / Qwen 3 / Phi-4 mini / DeepSeek R1 distill / etc). Under
  v0.2.0, engine_create() would either fail outright on those files or
  load the weights but emit garbage during decoding — the runtime was
  missing the flatbuffer schema entries for the extended prefill
  descriptor. v0.3.0 handles them transparently; the public C API
  surface is unchanged.

### Added
- Verified loads on HuggingFace `litert-community/Qwen2.5-1.5B-Instruct`,
  `litert-community/Qwen3-0.6B`, `litert-community/Phi-4-mini-instruct`,
  and `litert-community/DeepSeek-R1-Distill-Qwen-1.5B` in addition to
  the existing Gemma 4 E2B / E4B / Gemma 3 1B support.

### Rebuild required
- Every developer needs to re-run `scripts/build_ios_frameworks.sh` once
  because v0.3.0 ships a new `LiteRTLM.xcframework` built from the
  newer upstream source. Old cached artifacts are not compatible.

## [0.2.0] — 2026-04-11

### Added
- **iOS support (beta)** — the plugin now runs the LiteRT-LM C++ runtime
  natively on iOS via a vendored `LiteRTLM.xcframework` built from upstream
  source. Previously iOS method-channel calls returned `UNSUPPORTED`.
- `scripts/build_ios_frameworks.sh` — one-shot helper that clones upstream
  LiteRT-LM, cross-compiles `libc_engine.a` for `macos_arm64`, `ios_arm64`,
  and `ios_sim_arm64` via Bazel, wraps the outputs into proper static and
  dynamic framework bundles, assembles two XCFrameworks, and drops them
  into `ios/Frameworks/`. First run is 30-60 minutes; subsequent runs are
  cached by Bazel.
- `ios/Classes/LiteLmNativeBridge.{h,mm}` — Objective-C++ bridge that
  wraps the LiteRT-LM C API (`engine.h`) for Swift. Handles engine /
  conversation lifecycle, synchronous and streaming message delivery,
  and captures native stderr so errors from the runtime surface as
  `NSError` messages instead of opaque `NULL` returns.
- Example app's `_BackendSelector` now shows a read-only CPU chip on iOS
  with a note explaining the Metal accelerator is not available yet,
  instead of GPU/NPU buttons that would always fail at load time.
- README documents the iOS setup flow, the Bazel build prerequisites,
  and the iOS-specific troubleshooting entries (`NOT_FOUND: Engine type
  not found`, `UNIMPLEMENTED: Sampler type`, etc).

### Fixed
- Podspec now passes `-all_load` to the pod target's `OTHER_LDFLAGS` so
  the linker keeps every object file from `libc_engine.a`, including the
  engine-factory static constructors. Without this, `engine_create`
  failed at runtime with `NOT_FOUND: Engine type not found: 1`.
- Podspec and example `Podfile` exclude `x86_64` from the simulator
  architecture so the Apple Silicon-only XCFrameworks link cleanly on
  modern Macs.

### Known iOS limitations
- **CPU (XNNPACK) backend only.** The LiteRT-LM Metal GPU and WebGPU
  accelerators exist as prebuilt dylibs for macOS but have not been
  released for iOS yet — tracked upstream in
  [LiteRT-LM#1050](https://github.com/google-ai-edge/LiteRT-LM/issues/1050).
- Sampler knobs are ignored. The iOS C API currently reports
  `UNIMPLEMENTED: Sampler type: N not implemented yet` for both kTopK
  (1) and kGreedy (3), so the plugin passes a `NULL` session config and
  lets the engine use whatever sampler is baked into the model's own
  metadata.
- XCFrameworks only contain `arm64` slices — no Intel simulator support.
- Xcframeworks are not distributed with the package (they're ~370 MB on
  disk). Every developer must run `scripts/build_ios_frameworks.sh`
  locally before their first iOS build.

## [0.1.0] — 2026-04-10

Initial public release.

### Added
- Android support targeting `com.google.ai.edge.litertlm:litertlm-android:0.10.0`.
- `LiteLmEngine` for loading `.litertlm` model files with CPU, GPU (OpenCL),
  or NPU backends.
- `LiteLmConversation` for multi-turn chat with system instructions, sampler
  config, optional tools, and initial-message seeding.
- `sendMessage` for full responses and `sendMessageStream` for token-by-token
  streaming.
- Multimodal `sendMultimodalMessage` for text + image + audio inputs.
- Tool / function calling via `LiteLmTool` and `sendToolResponse`.
- Consumer Proguard / R8 keep rules shipped with the AAR so release builds
  don't strip the LiteRT-LM JNI surface.
- `<uses-native-library>` manifest entries merged into the host app for
  `libOpenCL.so` (Qualcomm Adreno), `libOpenCL-pixel.so` (Pixel Tensor), and
  `libOpenCL-car.so` (Android Auto) so the GPU backend works on Android 12+.
- Example app with model picker, on-device download with progress, backend
  selector, streaming chat, and per-response inference stats
  (tokens, tok/s, time-to-first-token, total duration).

### Known limitations
- iOS bridge is currently a stub — Google's LiteRT-LM Swift SDK is still in
  development. Method-channel calls return `UNSUPPORTED` until upstream ships.
- `countTokens` returns `-1` because token counting is not yet exposed by the
  upstream public API.
- Streaming downloads do not yet resume on network interruption — they
  restart from byte zero on retry.
