# llama_flutter_android

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform: Android](https://img.shields.io/badge/Platform-Android-green.svg)](https://developer.android.com/)

Run GGUF models on Android with [llama.cpp](https://github.com/ggerganov/llama.cpp) - A simple, MIT-licensed Flutter plugin.

## Features

- **Android Only** - Optimized specifically for Android
- **Simple API** - Easy-to-use Dart interface with Pigeon type safety
- **Token Streaming** - Real-time token generation with EventChannel
- **Stop Generation** - Cancel text generation mid-process on Android devices
- **18 Parameters** - Complete control: temperature, penalties, mirostat, seed, and more
- **7 Chat Templates** - ChatML, Llama-2, Alpaca, Vicuna, Phi, Gemma, Zephyr
- **Auto-Detection** - Chat templates detected from model filename
- **Vulkan GPU Acceleration** - Real GPU inference via `GGML_VULKAN` on supported devices
- **GPU Detection API** - `detectGpu()` returns device name, Vulkan support, memory info, and a recommended layer count
- **Latest llama.cpp** - Built on March 4, 2026 llama.cpp release (b8201)
- **ARM64 Optimized** - NEON and dot product optimizations enabled

## Requirements

- Flutter 3.24.0+
- Dart SDK 3.3.0+
- Android API 26+ (Android 8.0)
- NDK r27+ (for 16KB page size support)

## Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  llama_flutter_android: ^0.2.0
```

## Quick Start

### Basic Usage

```dart
import 'package:llama_flutter_android/llama_flutter_android.dart';

// Initialize controller
final controller = LlamaController();

// Load model
await controller.loadModel(
  modelPath: '/path/to/model.gguf',
  threads: 4,
  contextSize: 2048,
);

// Generate text with streaming
StreamSubscription? subscription;
subscription = controller.generate(
  prompt: 'Write a story about a robot',
  maxTokens: 512,
  temperature: 0.7,
).listen(
  (token) => print(token),  // Print each token as it arrives
  onDone: () => print('Generation complete!'),
  onError: (error) => print('Error: $error'),
);

// Stop generation mid-process (critical for UX!)
await controller.stop();
subscription?.cancel();

// Clean up
await controller.dispose();
```

### Chat Mode with Templates

```dart
// Chat with automatic template formatting
controller.generateChat(
  messages: [
    ChatMessage(role: 'system', content: 'You are a helpful assistant'),
    ChatMessage(role: 'user', content: 'Explain quantum computing'),
  ],
  template: 'chatml', // Auto-detected if null
  temperature: 0.7,
  maxTokens: 1000,
).listen((token) => print(token));
```

### Advanced Parameters

```dart
// Fine-grained control over generation
controller.generate(
  prompt: 'Explain machine learning',
  maxTokens: 1000,
  // Sampling
  temperature: 0.8,      // Creativity (0.0-2.0)
  topP: 0.9,             // Nucleus sampling
  topK: 40,              // Top-K sampling
  minP: 0.05,            // Minimum probability
  // Penalties (reduce repetition)
  repeatPenalty: 1.2,    // Penalize repeated tokens
  frequencyPenalty: 0.5, // Penalize frequent tokens
  presencePenalty: 0.3,  // Penalize token presence
  repeatLastN: 64,       // Penalty window size
  // Reproducibility
  seed: 42,              // Fixed seed for same output
  // Mirostat (perplexity control)
  mirostat: 2,           // 0=off, 1=v1, 2=v2
  mirostatTau: 5.0,      // Target perplexity
  mirostatEta: 0.1,      // Learning rate
).listen((token) => print(token));

// Stop anytime!
await controller.stop();
```

### GPU Detection

```dart
// Detect GPU capabilities before loading a model
final gpu = await controller.detectGpu();

print('Vulkan supported: ${gpu.vulkanSupported}');
print('GPU: ${gpu.gpuName}');                          // e.g. "Adreno (TM) 740"
print('Free RAM: ${gpu.freeRamBytes ~/ 1024 ~/ 1024} MB');
print('Recommended layers: ${gpu.recommendedGpuLayers}'); // 0, 16, or 99

// Use the recommendation (or override it)
await controller.loadModel(
  modelPath: '/path/to/model.gguf',
  gpuLayers: gpu.recommendedGpuLayers, // 0 = CPU only, 99 = full GPU offload
);
```

**`recommendedGpuLayers` values:**

| Value | Meaning |
|---|---|
| `0` | CPU only — no Vulkan, Mali GPU, or insufficient RAM |
| `16` | Partial offload — Vulkan supported but limited RAM/VRAM |
| `99` | Full offload — llama.cpp clamps to model's actual layer count |

> **Note:** `deviceLocalMemoryBytes` on Android equals total system RAM (unified memory architecture), not dedicated VRAM. Use `freeRamBytes` for memory pressure decisions.

## Architecture

```
         Flutter App (Dart)
                ↓
    llama_flutter_android.dart
    (User-facing API)
                ↓
    Pigeon Generated Code
    (Type-safe bridge)
                ↓
    LlamaFlutterAndroidPlugin.kt
    (Kotlin coroutines)
                ↓
    InferenceService.kt
    (Foreground service)
                ↓
    jni_wrapper.cpp
    (JNI bridge)
                ↓
    llama.cpp
    (Native inference)
```

## API Reference

### LlamaController

The main interface for working with llama.cpp models.

**Methods:**
- `loadModel()` - Load a GGUF model file
- `generate()` - Generate text with streaming tokens
- `generateChat()` - Generate chat responses with template formatting
- `stop()` - Stop generation mid-process
- `dispose()` - Clean up resources

**Parameters:**
- Basic: `maxTokens`, `seed`
- Sampling: `temperature`, `topP`, `topK`, `minP`, `typicalP`
- Penalties: `repeatPenalty`, `frequencyPenalty`, `presencePenalty`, `repeatLastN`, `penalizeNl`
- Mirostat: `mirostat`, `mirostatTau`, `mirostatEta`
- Context: `getContextInfo()`, `clearContext()`, `setSystemPromptLength()`
- Templates: `getSupportedTemplates()`, `registerCustomTemplate()`, `unregisterCustomTemplate()`

**Supported Chat Templates:**
- `chatml` - ChatML format (default)
- `llama2` - Llama-2 format
- `alpaca` - Alpaca format
- `vicuna` - Vicuna format
- `phi` - Phi format
- `gemma` - Gemma format
- `zephyr` - Zephyr format

## Contributing

Contributions are welcome! Please read [CONTRIBUTING.md](CONTRIBUTING.md) for details.

## License

MIT License - see [LICENSE](LICENSE) file for details.

## Credits

- [llama.cpp](https://github.com/ggerganov/llama.cpp) - The amazing inference engine
- [Pigeon](https://pub.dev/packages/pigeon) - Type-safe platform communication

## Support

- [Issue Tracker](https://github.com/dragneel2074/Llama-Flutter/issues)
- 💬 [Discussions](https://github.com/dragneel2074/Llama-Flutter/discussions)
- 📦 [Example App](example/) - Complete working example
