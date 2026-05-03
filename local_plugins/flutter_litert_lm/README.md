# flutter_litert_lm

[![pub package](https://img.shields.io/pub/v/flutter_litert_lm.svg)](https://pub.dev/packages/flutter_litert_lm)
[![CI](https://github.com/songhieu/flutter_litert_lm/actions/workflows/ci.yml/badge.svg)](https://github.com/songhieu/flutter_litert_lm/actions/workflows/ci.yml)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)

Flutter plugin for Google's [LiteRT-LM](https://github.com/google-ai-edge/LiteRT-LM)
— run Large Language Models **on-device** from your Flutter app, no network,
no API keys, no per-token bills.

Supports Gemma, Qwen, Phi, DeepSeek and any other model published in the
[`litert-community`](https://huggingface.co/litert-community) HuggingFace
organization, with hardware acceleration via the device's GPU (OpenCL) or
NPU.

## Why on-device?

- **Private** — prompts never leave the user's phone.
- **Offline** — works on a plane, in a tunnel, in a covered market.
- **Zero recurring cost** — no API calls, no token bills, no rate limits.
- **Low latency** — first-token latency is local round-trip time, not
  internet round-trip time.

## Features

- Streaming chat with token-by-token delta delivery
- Multi-turn conversations with system instructions and history
- Multimodal inputs (text, images, audio)
- Tool / function calling for agentic workflows
- CPU, GPU (OpenCL), and NPU backends
- Sampler controls: `temperature`, `topK`, `topP`
- Resource-safe lifecycle: `Engine.dispose()` and `Conversation.dispose()`
- Ships R8/Proguard keep rules so release builds don't break
- Manifest-merged `<uses-native-library>` entries so GPU works on Android 12+
  out of the box

## Platform support

| Platform    | Status  | Backends                                            |
|-------------|---------|-----------------------------------------------------|
| Android     | Stable  | CPU (XNNPACK), GPU (OpenCL), NPU (Qualcomm HTP, MediaTek APU) |
| iOS         | Beta    | CPU (XNNPACK) only                                  |
| iOS Sim arm64 | Beta  | CPU (XNNPACK) only                                  |

Minimum Android API **24** (Android 7.0). Minimum iOS **13.0**. iOS ships
arm64 slices only (no Intel Mac simulator).

### iOS notes

Google's LiteRT-LM ships no prebuilt iOS runtime, so the plugin pulls the
C++ runtime at install time and compiles it into an XCFramework on the
developer's Mac. One-time setup:

```bash
# 1. install Bazelisk (it will pick up Bazel 7.6.1 automatically)
brew install bazelisk git-lfs

# 2. clone your app, then from the plugin checkout:
bash scripts/build_ios_frameworks.sh

# 3. wait 30-60 minutes on the first run (Bazel downloads ~2 GB of deps
#    and compiles TFLite, protobuf, abseil, etc). Subsequent runs are
#    cached — flutter build ios after that takes seconds.
```

Details on what the script does and how to wire it into CI are in
[`ios/Frameworks/README.md`](ios/Frameworks/README.md).

**iOS backend limitations:** only the CPU (XNNPACK) backend is wired up.
The LiteRT-LM Metal GPU and WebGPU accelerators exist as separate dylibs
for macOS but are not shipped for iOS yet — see upstream issue
[google-ai-edge/LiteRT-LM#1050](https://github.com/google-ai-edge/LiteRT-LM/issues/1050).
The picker in the example app auto-hides GPU/NPU on iOS.

The iOS build also uses whatever sampler is baked into the model's own
metadata (kTopK and kGreedy aren't implemented in the C API shipped with
the current runtime), so the Dart-side `topK` / `topP` / `temperature`
knobs are ignored on iOS for now.

## Installation

```yaml
dependencies:
  flutter_litert_lm: ^0.2.0
```

Then run:

```bash
flutter pub get
```

## Quick start

```dart
import 'package:flutter_litert_lm/flutter_litert_lm.dart';

// 1. Load a model into a new engine.
final engine = await LiteLmEngine.create(
  LiteLmEngineConfig(
    modelPath: '/storage/.../model.litertlm',
    backend: LiteLmBackend.gpu, // or .cpu / .npu
  ),
);

// 2. Start a conversation.
final conversation = await engine.createConversation(
  LiteLmConversationConfig(
    systemInstruction: 'You are a helpful assistant. Be concise.',
    samplerConfig: const LiteLmSamplerConfig(
      temperature: 0.7,
      topK: 40,
      topP: 0.95,
    ),
  ),
);

// 3a. Get the full reply at once...
final reply = await conversation.sendMessage('What is Flutter?');
print(reply.text);

// 3b. ...or stream tokens as they arrive.
conversation.sendMessageStream('Tell me a story.').listen((delta) {
  stdout.write(delta.text); // each event is the new tokens, not a snapshot
});

// 4. Always release native resources when you're done.
await conversation.dispose();
await engine.dispose();
```

## Streaming chat

`sendMessageStream` returns a `Stream<LiteLmMessage>`. **Each event carries
only the new tokens** since the previous emission, not a snapshot of the full
response — accumulate as you go:

```dart
final buffer = StringBuffer();
await for (final delta in conversation.sendMessageStream('Hello!')) {
  buffer.write(delta.text);
  print(buffer); // partial reply so far
}
```

The example app shows how to wire this into a UI with a typing indicator and
live token-per-second readout.

## Multimodal

```dart
final reply = await conversation.sendMultimodalMessage([
  LiteLmContent.text('Describe what you see.'),
  LiteLmContent.imageFile('/storage/.../photo.jpg'),
]);
print(reply.text);
```

`LiteLmContent` factories: `text`, `imageFile`, `imageBytes`, `audioFile`,
`audioBytes`, `toolResponse`.

## Tool calling

```dart
final conversation = await engine.createConversation(
  LiteLmConversationConfig(
    tools: [
      LiteLmTool(
        name: 'get_weather',
        description: 'Get current weather for a city',
        parameters: {
          'type': 'object',
          'properties': {
            'city': {'type': 'string', 'description': 'City name'},
          },
          'required': ['city'],
        },
      ),
    ],
  ),
);

final reply = await conversation.sendMessage('Weather in Tokyo?');
if (reply.toolCalls.isNotEmpty) {
  final call = reply.toolCalls.first;
  // Run the tool yourself, then feed the result back:
  final final_ = await conversation.sendToolResponse(
    call.name,
    '{"temperature": 22, "condition": "sunny"}',
  );
  print(final_.text);
}
```

## Backends

| Backend | Android                           | iOS       |
|---------|-----------------------------------|-----------|
| `cpu`   | Always works (including emulator) | Supported |
| `gpu`   | Real devices with OpenCL          | Not yet   |
| `npu`   | Devices with vendor NPU runtime   | Not yet   |

The example app lets you switch backends at runtime on Android — useful
for benchmarking. On iOS the backend selector is locked to CPU.

> **Android emulator note:** emulators ship with no `libOpenCL.so`, so the
> `gpu` backend cannot initialize there. Use `cpu` on the emulator and
> `gpu` on real hardware.

> **iOS note:** only CPU is supported. GPU (Metal) requires the
> `libLiteRtMetalAccelerator.dylib` accelerator plugin, which Google has
> not shipped for iOS yet. Tracked upstream in LiteRT-LM issue
> [#1050](https://github.com/google-ai-edge/LiteRT-LM/issues/1050).

## Getting models

The [`litert-community`](https://huggingface.co/litert-community) HuggingFace
organization publishes ready-to-run `.litertlm` files. The example app's
[`models.dart`](example/lib/models.dart) curates the open-license,
non-gated subset:

| Model                          | Size     | License    | Notes                              |
|--------------------------------|----------|------------|------------------------------------|
| Qwen 3 0.6B                    | 586 MB   | Apache-2.0 | Smallest general-purpose chat      |
| Qwen 2.5 1.5B Instruct (q8)    | 1.49 GB  | Apache-2.0 | Balanced quality / size            |
| DeepSeek R1 Distill Qwen 1.5B  | 1.71 GB  | MIT        | Reasoning / chain-of-thought       |
| Gemma 4 E2B Instruct           | 2.46 GB  | Apache-2.0 | Google flagship, ungated           |
| Gemma 4 E4B Instruct           | 3.40 GB  | Apache-2.0 | Highest quality, ~5 GB RAM at load |

Models in the `litert-community/Gemma3-*` repos are gated under the Gemma
license and require a HuggingFace token to download — visit the model's HF
page first to accept the terms.

You can drop a `.litertlm` file anywhere readable by your app and pass the
absolute path as `modelPath`. For app-private storage, use
[`path_provider`](https://pub.dev/packages/path_provider) to resolve a
writable directory.

## API reference

### `LiteLmEngine`

| Member                            | Description                            |
|-----------------------------------|----------------------------------------|
| `LiteLmEngine.create(config)`     | Load a model and initialize the engine |
| `engine.createConversation([cfg])`| Open a new conversation                |
| `engine.countTokens(text)`        | Tokenize and count (currently `-1` — upstream API doesn't expose this yet) |
| `engine.dispose()`                | Release native handles                 |

### `LiteLmConversation`

| Member                                       | Description                              |
|----------------------------------------------|------------------------------------------|
| `sendMessage(text, {extraContext})`          | Full reply, awaited                      |
| `sendMultimodalMessage(contents, {extraContext})` | Mixed text + image + audio          |
| `sendMessageStream(text, {extraContext})`    | `Stream<LiteLmMessage>` of token deltas  |
| `sendToolResponse(name, result, {extraContext})` | Reply to a tool call                |
| `dispose()`                                  | Release the conversation                 |

### Configuration types

- **`LiteLmEngineConfig`** — `modelPath`, `backend`, `cacheDir`,
  `visionBackend`, `audioBackend`
- **`LiteLmConversationConfig`** — `systemInstruction`, `initialMessages`,
  `samplerConfig`, `tools`, `automaticToolCalling`
- **`LiteLmSamplerConfig`** — `temperature`, `topK`, `topP`
- **`LiteLmBackend`** — `cpu`, `gpu`, `npu`

## Example app

A full reference implementation lives in [`example/`](example/) and includes:

- Curated model picker with on-device download + progress
- Backend selector (CPU / GPU / NPU)
- Streaming chat with typing indicator
- Per-response inference stats (tokens, tok/s, TTFT, total duration)

```bash
cd example
flutter run --release
```

## Troubleshooting

**`NoSuchMethodError: Lcom/google/ai/edge/litertlm/SamplerConfig;.getTopK()I`**
in release builds — R8 stripped the JNI surface. The plugin already ships
keep rules in `consumer-rules.pro` that AGP merges into your app
automatically; if you somehow still hit this, copy those rules into your
own `proguard-rules.pro`.

**`Cannot find OpenCL library on this device`** on real Android phones with
GPU backend — your app's manifest is missing `<uses-native-library>`. The
plugin ships these entries and AGP merges them into your manifest, so this
should be automatic. If you've disabled manifest merging, add to your app's
`<application>`:

```xml
<uses-native-library android:name="libOpenCL.so" android:required="false"/>
<uses-native-library android:name="libOpenCL-pixel.so" android:required="false"/>
<uses-native-library android:name="libOpenCL-car.so" android:required="false"/>
```

**App is killed silently after loading a large model** — out-of-memory.
Modern phones often have 6–8 GB RAM but a third of that is used by the
system. Models bigger than ~2.5 GB on disk can blow past what's available
once loaded. Try a smaller model (Qwen 3 0.6B, Gemma 3 1B) or close
background apps.

**Streaming feels choppy** — make sure you're using `sendMessageStream`, not
`sendMessage`. The latter blocks until the entire response is generated.

### iOS-specific

**`Build input file cannot be found: .../LiteRTLM.xcframework`** during
`flutter build ios` — the vendored XCFramework hasn't been built yet.
Run `bash scripts/build_ios_frameworks.sh` from the plugin checkout
before your first iOS build. First run is 30-60 minutes, subsequent runs
are cached by Bazel.

**`engine_create returned NULL ... NOT_FOUND: Engine type not found`** —
the linker has dropped the LiteRT-LM engine factory static constructors.
The podspec already passes `-all_load` to the pod target to force every
`.o` file from `libc_engine.a` to be linked in; if you've customized
`pod_target_xcconfig` in your own build, make sure `-all_load` is still
in `OTHER_LDFLAGS`.

**`UNIMPLEMENTED: Sampler type: 1 not implemented yet`** (or 3) — the iOS
C API in the current LiteRT-LM runtime doesn't implement the kTopK /
kGreedy samplers. The plugin passes a NULL `session_config` on iOS so
the engine falls back to the sampler baked into the model metadata,
which always works.

**iOS simulator can't build for x86_64** — the shipped XCFrameworks only
contain arm64 slices (Apple Silicon devices + arm64 simulators). The
plugin's podspec and the example app's `Podfile` both exclude `x86_64`
from `EXCLUDED_ARCHS[sdk=iphonesimulator*]`; if you copy the podspec into
your own app without the Podfile hook, add the same exclusion to
your Runner target manually.

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for
the workflow. By contributing you agree that your work will be released
under this project's Apache 2.0 license.

## License

Licensed under the **Apache License 2.0** — see [LICENSE](LICENSE) for the
full text. The same license as upstream LiteRT-LM.

## Acknowledgements

- [Google AI Edge](https://github.com/google-ai-edge/LiteRT-LM) for the
  LiteRT-LM runtime and the `litert-community` model collection.
- [HuggingFace](https://huggingface.co/litert-community) for hosting the
  model artifacts.
- The Flutter team for the plugin platform interface.
