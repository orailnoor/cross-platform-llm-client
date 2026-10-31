class AppConstants {
  AppConstants._();

  // Hive Box Names
  static const String chatSessionsBox = 'chat_sessions';
  static const String chatMessagesBox = 'chat_messages';
  static const String tasksBox = 'tasks';
  static const String settingsBox = 'settings';

  // Settings Keys
  static const String keyInferenceMode = 'inference_mode'; // 'local' or 'cloud'
  static const String keyCloudProvider =
      'cloud_provider'; // 'openai', 'anthropic', 'google', 'kimi'
  static const String keyOpenaiKey = 'openai_api_key';
  static const String keyAnthropicKey = 'anthropic_api_key';
  static const String keyGoogleKey = 'google_api_key';
  static const String keyKimiKey = 'kimi_api_key';
  static const String keyStabilityKey = 'stability_api_key';
  static const String keyNvidiaKey = 'nvidia_api_key';
  static const String keyOpenRouterKey = 'openrouter_api_key';
  static const String keyDeepSeekKey = 'deepseek_api_key';
  static const String keyCustomCloudName = 'custom_cloud_name';
  static const String keyCustomCloudBaseUrl = 'custom_cloud_base_url';
  static const String keyCustomCloudKey = 'custom_cloud_api_key';
  static const String keyCustomCloudProfiles = 'custom_cloud_profiles';
  static const String keyCustomCloudProfileIndex = 'custom_cloud_profile_index';
  static const String keyOpenaiModel = 'openai_model';
  static const String keyAnthropicModel = 'anthropic_model';
  static const String keyGoogleModel = 'google_model';
  static const String keyKimiModel = 'kimi_model';
  static const String keyStabilityModel = 'stability_model';
  static const String keyNvidiaModel = 'nvidia_model';
  static const String keyOpenRouterModel = 'openrouter_model';
  static const String keyDeepSeekModel = 'deepseek_model';
  static const String keyCustomCloudModel = 'custom_cloud_model';
  static const String keyGlobalSystemPrompt = 'global_system_prompt';
  static const String keyLocalModelPath = 'local_model_path';
  static const String keyLocalModelName = 'local_model_name';
  static const String keyLocalModelRuntime = 'local_model_runtime';
  static const String keyLocalModelBackend = 'local_model_backend';
  static const String keyLiteRtPerformanceMode = 'litert_performance_mode';
  static const String keyLiteRtGpuWarningAccepted =
      'litert_gpu_warning_accepted';
  static const String keyLiteRtGpuLoadPending = 'litert_gpu_load_pending';
  static const String keyLiteRtGpuCrashDetected = 'litert_gpu_crash_detected';

  /// Set while a GGUF model runs on the GPU until its first reply succeeds;
  /// still set on the next load means the GPU crashed the app.
  static const String keyGgufGpuPending = 'gguf_gpu_pending';
  static const String keyStopSequences = 'stop_sequences';
  static const String keyImageModelPath = 'image_model_path';
  static const String keyImageModelName = 'image_model_name';
  static const String keyTemperature = 'temperature';
  static const String keyMaxTokens = 'max_tokens';
  static const String keyContextSize = 'context_size';
  static const String keyHapticsEnabled = 'haptics_enabled';
  static const String keyAutoUpdateCheck = 'auto_update_check';
  static const String keyLastUpdateCheck = 'last_update_check';
  static const String keyLastUpdatePrompt = 'last_update_prompt';
  static const String keySkippedUpdateVersion = 'skipped_update_version';

  /// GitHub repository whose releases ship the Android APKs.
  static const String githubRepo = 'orailnoor/cross-platform-llm-client';
  static const String keyServerApiKey = 'server_api_key';
  static const String keyServerUseApiKey = 'server_use_api_key';
  static const String keyServerAllowNetwork = 'server_allow_network';
  static const String keyClusterEnabled = 'cluster_enabled';
  static const String keyClusterWorkers = 'cluster_workers';
  static const String keyImageSteps = 'image_steps';
  static const String keyImageGenForceCpu = 'image_gen_force_cpu';
  static const String keyImageGenBackend = 'image_gen_backend';
  static const String keyImageGenGpuGuardMb = 'image_gen_gpu_guard_mb';
  static const String keyImageGenSize = 'image_gen_size';
  static const String keyImageGenQuantization = 'image_gen_quantization';
  static const String keyFontScale = 'font_scale';
  static const String keyBatchModeWarningAccepted =
      'batch_mode_warning_accepted';

  // Default Model Config
  static const double defaultTemperature = 0.7;
  static const int defaultMaxTokens = 1024;
  static const int defaultContextSize = 2048;
  static const String defaultLiteRtPerformanceMode = 'auto_fast';
  static const int defaultImageSteps = 1;
  static const bool defaultImageGenForceCpu = true;
  static const int defaultImageGenGpuGuardMb = 1843; // 1.8 GB
  static const int defaultImageGenSize = 0; // 0 = Auto recommended
  static const double defaultFontScale =
      0.95; // 4th slider stop, "Small" default

  // System Prompt (compact for small context models)
  static const String systemPrompt =
      '''You are AI Chat, a helpful and friendly assistant. Be concise, accurate, and conversational. Answer questions directly without unnecessary preamble.''';

  // System Prompt for Uncensored Models
  static const String uncensoredSystemPrompt =
      '''You are AI Chat running with an uncensored local model. Be direct, mature, and conversational. Avoid moralizing or unnecessary disclaimers, but keep answers accurate and do not help with real-world harm, abuse, or illegal activity.''';

  static bool isUncensoredModelName(String value) {
    final lower = value.toLowerCase();
    return lower.contains('uncensored') ||
        lower.contains('abliterated') ||
        lower.contains('unrestricted') ||
        lower.contains('dolphin');
  }

  // Available Models for Download
  static const List<Map<String, String>> availableModels = [
    {
      'name': 'Qwen 3 0.6B (LiteRT-LM)',
      'filename': 'Qwen3-0.6B.litertlm',
      'url':
          'https://huggingface.co/litert-community/Qwen3-0.6B/resolve/main/Qwen3-0.6B.litertlm',
      'size': '586 MB',
      'description':
          'Smallest LiteRT-LM general-purpose chat model for low-RAM phones',
      'template': 'litert',
      'runtime': 'litert',
    },
    {
      'name': 'Qwen 2.5 1.5B Instruct (LiteRT-LM)',
      'filename': 'Qwen2.5-1.5B-Instruct_multi-prefill-seq_q8_ekv4096.litertlm',
      'url':
          'https://huggingface.co/litert-community/Qwen2.5-1.5B-Instruct/resolve/main/Qwen2.5-1.5B-Instruct_multi-prefill-seq_q8_ekv4096.litertlm',
      'size': '1.49 GB',
      'description': 'Balanced LiteRT-LM chat model with int8 quantization',
      'template': 'litert',
      'runtime': 'litert',
    },
    {
      'name': 'DeepSeek R1 Distill Qwen 1.5B (LiteRT-LM)',
      'filename':
          'DeepSeek-R1-Distill-Qwen-1.5B_multi-prefill-seq_q8_ekv4096.litertlm',
      'url':
          'https://huggingface.co/litert-community/DeepSeek-R1-Distill-Qwen-1.5B/resolve/main/DeepSeek-R1-Distill-Qwen-1.5B_multi-prefill-seq_q8_ekv4096.litertlm',
      'size': '1.71 GB',
      'description': 'Reasoning-focused LiteRT-LM model with int8 quantization',
      'template': 'litert',
      'runtime': 'litert',
    },
    {
      'name': 'Gemma 4 E2B Instruct (LiteRT-LM)',
      'filename': 'gemma-4-E2B-it.litertlm',
      'recommended': 'vision',
      'url':
          'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it.litertlm',
      'size': '2.46 GB',
      'description': 'Strong general chat LiteRT-LM model from Google Gemma',
      'template': 'litert',
      'runtime': 'litert',
      'vision': 'true',
    },
    {
      'name': 'Gemma 4 E4B Instruct (LiteRT-LM)',
      'filename': 'gemma-4-E4B-it.litertlm',
      'url':
          'https://huggingface.co/litert-community/gemma-4-E4B-it-litert-lm/resolve/main/gemma-4-E4B-it.litertlm',
      'size': '3.40 GB',
      'description': 'Highest quality LiteRT-LM option; needs about 5 GB RAM',
      'template': 'litert',
      'runtime': 'litert',
      'vision': 'true',
    },
    {
      'name': 'Kimi Moonlight 16B-A3B (Q3_K_S)',
      'filename': 'moonlight-16b-a3b-instruct-q3_k_s.gguf',
      'url':
          'https://huggingface.co/mmnga/Moonlight-16B-A3B-Instruct-gguf/resolve/main/Moonlight-16B-A3B-Instruct-Q3_K_S.gguf',
      'size': '7.1 GB',
      'description': 'Moonshot AI (Kimi) — 3B active MoE, high quality',
      'template': 'chatml',
    },
    {
      'name': 'Qwen2.5-3B Instruct (Q4_K_M)',
      'filename': 'qwen2.5-3b-instruct-q4_k_m.gguf',
      'url':
          'https://huggingface.co/bartowski/Qwen2.5-3B-Instruct-GGUF/resolve/main/Qwen2.5-3B-Instruct-Q4_K_M.gguf',
      'size': '2.1 GB',
      'description': 'Best balance of speed and quality for mobile',
      'template': 'chatml',
    },
    {
      'name': 'LFM2.5 1.2B Instruct (Q4_K_M)',
      'filename': 'lfm2.5-1.2b-instruct-q4_k_m.gguf',
      'recommended': 'general',
      'url':
          'https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct-GGUF/resolve/main/LFM2.5-1.2B-Instruct-Q4_K_M.gguf',
      'size': '731 MB',
      'description':
          'Liquid AI\'s fast on-device model — quick replies on mid-range phones',
      'template': 'chatml',
    },
    {
      'name': 'LFM2.5-VL 1.6B (Q4_K_M)',
      'filename': 'lfm2.5-vl-1.6b-q4_k_m.gguf',
      'url':
          'https://huggingface.co/LiquidAI/LFM2.5-VL-1.6B-GGUF/resolve/main/LFM2.5-VL-1.6B-Q4_K_M.gguf',
      'size': '731 MB + 583 MB vision',
      'description':
          'Liquid AI\'s small vision model — fast, light enough for the GPU on most phones',
      'template': 'chatml',
      'vision': 'true',
      'mmproj_filename': 'lfm2.5-vl-1.6b-mmproj-q8_0.gguf',
      'mmproj_url':
          'https://huggingface.co/LiquidAI/LFM2.5-VL-1.6B-GGUF/resolve/main/mmproj-LFM2.5-VL-1.6b-Q8_0.gguf',
    },
    {
      'name': 'Qwen2-VL-2B Instruct (Q4_K_M)',
      'filename': 'qwen2-vl-2b-instruct-q4_k_m.gguf',
      'url':
          'https://huggingface.co/ggml-org/Qwen2-VL-2B-Instruct-GGUF/resolve/main/Qwen2-VL-2B-Instruct-Q4_K_M.gguf',
      'size': '986 MB + 710 MB vision',
      'description':
          'Small vision model — describe photos, read text in images',
      'template': 'chatml',
      'vision': 'true',
      'mmproj_filename': 'qwen2-vl-2b-instruct-mmproj-q8_0.gguf',
      'mmproj_url':
          'https://huggingface.co/ggml-org/Qwen2-VL-2B-Instruct-GGUF/resolve/main/mmproj-Qwen2-VL-2B-Instruct-Q8_0.gguf',
    },
    {
      'name': 'Gemma 4 E2B Uncensored Vision (Q2_K_P)',
      'filename': 'gemma-4-e2b-uncensored-hauhaucs-aggressive-q2_k_p.gguf',
      'recommended': 'uncensored',
      'url':
          'https://huggingface.co/HauhauCS/Gemma-4-E2B-Uncensored-HauhauCS-Aggressive/resolve/main/Gemma-4-E2B-Uncensored-HauhauCS-Aggressive-Q2_K_P.gguf',
      'size': '3.0 GB + 986 MB vision',
      'description':
          'Uncensored Gemma 4 with image understanding — smallest quant, needs ~4 GB free RAM',
      'template': 'gemma',
      'vision': 'true',
      'mmproj_filename': 'gemma-4-e2b-uncensored-hauhaucs-mmproj-f16.gguf',
      'mmproj_url':
          'https://huggingface.co/HauhauCS/Gemma-4-E2B-Uncensored-HauhauCS-Aggressive/resolve/main/mmproj-Gemma-4-E2B-Uncensored-HauhauCS-Aggressive-f16.gguf',
    },
    {
      'name': 'Gemma 3 4B Instruct Vision (Q4_K_M)',
      'filename': 'gemma-3-4b-it-q4_k_m.gguf',
      'url':
          'https://huggingface.co/ggml-org/gemma-3-4b-it-GGUF/resolve/main/gemma-3-4b-it-Q4_K_M.gguf',
      'size': '2.5 GB + 851 MB vision',
      'description':
          'Google\'s multimodal Gemma — stronger image understanding, needs ~4 GB free RAM',
      'template': 'gemma',
      'vision': 'true',
      'mmproj_filename': 'gemma-3-4b-it-mmproj-f16.gguf',
      'mmproj_url':
          'https://huggingface.co/ggml-org/gemma-3-4b-it-GGUF/resolve/main/mmproj-model-f16.gguf',
    },
    {
      'name': 'Phi-3.5 Mini Instruct (Q4_K_M)',
      'filename': 'phi-3.5-mini-instruct-q4_k_m.gguf',
      'url':
          'https://huggingface.co/bartowski/Phi-3.5-mini-instruct-GGUF/resolve/main/Phi-3.5-mini-instruct-Q4_K_M.gguf',
      'size': '2.2 GB',
      'description': 'Microsoft\'s compact reasoning model',
      'template': 'phi',
    },
    {
      'name': 'Gemma 3 1B Instruct (Q4_0)',
      'filename': 'gemma-3-1b-it-q4_0.gguf',
      'url':
          'https://huggingface.co/unsloth/gemma-3-1b-it-GGUF/resolve/main/gemma-3-1b-it-Q4_0.gguf',
      'size': '722 MB',
      'description':
          'Google\'s newer compact chat model — fast, small, and capable',
      'template': 'gemma',
    },
    {
      'name': 'Gemma-2-2B-Abliterated (Q4_K_M)',
      'filename': 'gemma-2-2b-it-abliterated-q4_k_m.gguf',
      'url':
          'https://huggingface.co/bartowski/gemma-2-2b-it-abliterated-GGUF/resolve/main/gemma-2-2b-it-abliterated-Q4_K_M.gguf',
      'size': '1.6 GB',
      'description': '🔓 Abliterated — Permanently uncensored, very smart',
      'template': 'gemma',
    },
    {
      'name': 'SmolLM2-1.7B-Uncensored (Q4_K_M)',
      'filename': 'smollm2-1.7b-instruct-uncensored-q4_k_m.gguf',
      'url':
          'https://huggingface.co/mradermacher/SmolLM2-1.7B-Instruct-Uncensored-GGUF/resolve/main/SmolLM2-1.7B-Instruct-Uncensored.Q4_K_M.gguf',
      'size': '1.1 GB',
      'description': 'Ultra-compact and unrestricted assistant',
      'template': 'chatml',
    },
    {
      'name': 'Dolphin-3.0-Qwen2.5-1.5B (Q4_K_M)',
      'filename': 'dolphin-3.0-qwen2.5-1.5b-q4_k_m.gguf',
      'url':
          'https://huggingface.co/bartowski/Dolphin3.0-Qwen2.5-1.5B-GGUF/resolve/main/Dolphin3.0-Qwen2.5-1.5B-Q4_K_M.gguf',
      'size': '986 MB',
      'description': 'Uncensored Dolphin 3.0 — Fast and unrestricted',
      'template': 'chatml',
    },
    {
      'name': 'Llama-3.2-3B Uncensored (Q4_K_M)',
      'filename': 'llama-3.2-3b-instruct-uncensored-q4_k_m.gguf',
      'url':
          'https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-uncensored-GGUF/resolve/main/Llama-3.2-3B-Instruct-uncensored-Q4_K_M.gguf',
      'size': '2.1 GB',
      'description': 'Uncensored Llama 3.2 3B — Smarter and unrestricted',
      'template': 'llama3',
    },
    {
      'name': 'Llama-3.2-1B Instruct (Q4_K_M)',
      'filename': 'llama-3.2-1b-instruct-q4_k_m.gguf',
      'url':
          'https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf',
      'size': '0.8 GB',
      'description': 'Ultra-lightweight text model',
      'template': 'llama3',
    },
    {
      'name': 'DreamShaper 8 LCM (SD 1.5)',
      'filename': 'DreamShaper8_LCM.safetensors',
      'url':
          'https://huggingface.co/Lykon/dreamshaper-8-lcm/resolve/main/DreamShaper8_LCM.safetensors',
      'size': '2.0 GB',
      'description': 'Extremely fast 4-step local image generation',
      'template': 'sd',
    },
    {
      'name': 'CyberRealistic V8 FP16 (SD 1.5)',
      'filename': 'CyberRealistic_V8_FP16.safetensors',
      'recommended': 'image',
      'url':
          'https://huggingface.co/cyberdelia/CyberRealistic/resolve/main/CyberRealistic_V8_FP16.safetensors',
      'size': '2.0 GB',
      'description':
          'Photorealistic, uncensored local image generation — FP16 for mobile',
      'template': 'sd',
    },
    {
      'name': 'CyberRealistic (Apple CoreML FP16)',
      'filename': 'cyberrealistic.coreml.zip',
      'url':
          'https://huggingface.co/orailnooor/cyberrealistic-coreml/resolve/main/cyberrealistic.coreml.zip?download=true',
      'size': '2.0 GB',
      'description':
          'Optimized for Apple devices with M-series chips or 8GB+ RAM',
      'template': 'sd',
    },
    {
      'name': 'CyberRealistic (Apple CoreML 6-bit)',
      'filename': 'cyberrealistic-6bit.coreml.zip',
      'url':
          'https://huggingface.co/orailnooor/cyberrealistic-coreml/resolve/main/cyberrealistic-6bit.coreml.zip?download=true',
      'size': '855 MB',
      'description':
          'Compressed 6-bit model optimized for Apple devices with 4GB/6GB RAM',
      'template': 'sd',
    },
    {
      'name': 'Realistic Vision V5.1 fp16 (SD 1.5)',
      'filename': 'Realistic_Vision_V5.1_fp16-no-ema.safetensors',
      'url':
          'https://huggingface.co/SG161222/Realistic_Vision_V5.1_noVAE/resolve/main/Realistic_Vision_V5.1_fp16-no-ema.safetensors',
      'size': '2.0 GB',
      'description': 'Highly popular photorealistic portrait and scene model',
      'template': 'sd',
    },
    {
      'name': 'AbsoluteReality 1.8.1 pruned (SD 1.5)',
      'filename': 'AbsoluteReality_1.8.1_pruned.safetensors',
      'url':
          'https://huggingface.co/Lykon/AbsoluteReality/resolve/main/AbsoluteReality_1.8.1_pruned.safetensors',
      'size': '2.0 GB',
      'description': 'Photorealistic general-purpose image generation',
      'template': 'sd',
    },
    {
      'name': 'AnyLoRA (SD 1.5)',
      'filename': 'AnyLoRA_noVae_fp16-pruned.safetensors',
      'url':
          'https://huggingface.co/Lykon/AnyLoRA/resolve/main/AnyLoRA_noVae_fp16-pruned.safetensors',
      'size': '2.0 GB',
      'description': 'Highly versatile Anime / Stylized image generator',
      'template': 'sd',
    },
  ];

  // Cloud API Endpoints
  static const String openaiEndpoint =
      'https://api.openai.com/v1/chat/completions';
  static const String anthropicEndpoint =
      'https://api.anthropic.com/v1/messages';
  static const String googleEndpoint =
      'https://generativelanguage.googleapis.com/v1beta/models';
  static const String kimiEndpoint =
      'https://api.moonshot.ai/v1/chat/completions';
  static const String stabilityEndpoint =
      'https://api.stability.ai/v2beta/stable-image/generate/sd3';
  static const String nvidiaEndpoint = 'https://integrate.api.nvidia.com/v1';
  static const String openRouterEndpoint = 'https://openrouter.ai/api/v1';
  static const String deepSeekEndpoint = 'https://api.deepseek.com';
}
