/// Flutter plugin for running GGUF language models on Android using llama.cpp.
///
/// Provides [LlamaController] for loading models, generating text, and
/// detecting GPU capabilities via Vulkan. Supports streaming token output,
/// chat templates, and configurable generation parameters.
///
/// ## Quick start
/// ```dart
/// import 'package:llama_flutter_android/llama_flutter_android.dart';
///
/// final controller = LlamaController();
/// final gpu = await controller.detectGpu();
/// await controller.loadModel(
///   modelPath: '/path/to/model.gguf',
///   gpuLayers: gpu.recommendedGpuLayers,
/// );
/// controller.generate(prompt: 'Hello!').listen(print);
/// ```
library;

export 'src/llama_controller.dart';
export 'src/llama_api.dart' show ModelConfig, GenerateRequest, ChatMessage, ChatRequest, ContextInfo, GpuInfo, LlamaHostApi;
export 'src/generation_config.dart';