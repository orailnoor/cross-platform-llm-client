import 'package:flutter_test/flutter_test.dart';
import 'package:ai_chat/models/ai_model.dart';

void main() {
  test('detects local model runtime from filename and template', () {
    expect(
      AiModel.runtimeFromFilename('Qwen3-0.6B.litertlm'),
      AiModel.runtimeLiteRt,
    );
    expect(
      AiModel.runtimeFromFilename('llama-3.2-1b-instruct.gguf'),
      AiModel.runtimeLlama,
    );
    expect(
      AiModel.runtimeFromFilename('DreamShaper.safetensors'),
      AiModel.runtimeSd,
    );
    expect(
      AiModel.runtimeFromFilename('sdxs.gguf', template: 'sd'),
      AiModel.runtimeSd,
    );
  });
}
