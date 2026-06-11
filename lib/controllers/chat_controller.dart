import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show compute, kIsWeb;
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:get/get.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:uuid/uuid.dart';
import 'package:gal/gal.dart';
import '../controllers/settings_controller.dart';
import '../core/constants.dart';
import '../models/chat_message.dart';
import '../models/chat_session.dart';
import '../ffi/sd_ffi_bindings.dart';
import '../services/hive_service.dart';
import '../services/inference_service.dart';
import '../services/cloud_service.dart';
import '../services/local_image_service.dart';
import '../services/app_log_service.dart';
import '../services/image_generation_notification_service.dart';
import '../services/document_extractor_service.dart';
import '../utils/thought_parser.dart';

const int _visionImageMaxSide = 768;
const int _visionImageJpegQuality = 72;

Uint8List? _resizeVisionImageBytes(Map<String, dynamic> args) {
  final bytes = args['bytes'] as Uint8List;
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;

  final longestSide = decoded.width > decoded.height ? decoded.width : decoded.height;
  if (longestSide <= _visionImageMaxSide) {
    return bytes;
  }

  final resized = img.copyResize(
    decoded,
    width: decoded.width >= decoded.height ? _visionImageMaxSide : null,
    height: decoded.height > decoded.width ? _visionImageMaxSide : null,
    interpolation: img.Interpolation.average,
  );
  return Uint8List.fromList(
    img.encodeJpg(resized, quality: _visionImageJpegQuality),
  );
}

class ChatController extends GetxController {
  final HiveService _hive = Get.find<HiveService>();
  final _uuid = const Uuid();

  // State
  final sessions = <ChatSession>[].obs;
  final messages = <ChatMessage>[].obs;
  final currentSessionId = ''.obs;
  final isLoading = false.obs;
  final inputText = ''.obs;
  final selectedImagePath = Rxn<String>();
  final selectedImageBase64 = Rxn<String>();
  final selectedFileName = Rxn<String>();
  final selectedFileContent = Rxn<String>();
  final selectedFilePath = Rxn<String>();
  final selectedFileType = Rxn<String>();
  final selectedFileSize = 0.obs;

  // Batch Image Generation
  final batchPrompts = <String>[].obs;
  final batchModeAccepted = false.obs;
  final lastBatchImagesBase64 = <String>[].obs;

  // Real-time streaming state — the AI response as it's being generated
  final streamingResponse = ''.obs;
  final isStreaming = false.obs;
  final streamingAttachmentType = Rxn<String>();

  // Image generation progress (lightweight, replaces text-heavy updates)
  final imageGenStep = 0.obs;
  final imageGenTotal = 0.obs;
  final imageGenEstimatedSecs = 0.obs;
  final imageGenStartTime = Rxn<DateTime>();
  final imageGenDecoding = false.obs;

  // Speech-to-text
  final isListening = false.obs;
  final sttAvailable = false.obs;
  final _speech = stt.SpeechToText();

  final textController = TextEditingController();
  final scrollController = ScrollController();
  Timer? _scrollTimer;
  bool _followStreaming = true;
  bool _scrollListenerAttached = false;
  int _generationSerial = 0;

  @override
  void onInit() {
    super.onInit();
    scrollController.addListener(_handleUserScroll);
    _scrollListenerAttached = true;
    batchModeAccepted.value = _hive.getSetting<bool>(AppConstants.keyBatchModeWarningAccepted, defaultValue: false) ?? false;
    loadSessions();
    _initSpeech();
  }

  Future<void> _initSpeech() async {
    try {
      sttAvailable.value = await _speech.initialize(
        onError: (_) => isListening.value = false,
        onStatus: (status) {
          if (status == 'done' || status == 'notListening') {
            isListening.value = false;
          }
        },
      );
    } catch (_) {
      sttAvailable.value = false;
    }
  }

  Future<void> toggleListening() async {
    try {
      if (isListening.value) {
        await _speech.stop();
        isListening.value = false;
        return;
      }
      if (!sttAvailable.value) {
        try {
          final ok = await _speech.initialize();
          sttAvailable.value = ok;
        } catch (_) {
          sttAvailable.value = false;
        }
        if (!sttAvailable.value) return;
      }
      await _speech.listen(
        onResult: (result) {
          textController.text = result.recognizedWords;
          inputText.value = result.recognizedWords;
        },
        listenFor: const Duration(seconds: 60),
        pauseFor: const Duration(seconds: 4),
        localeId: 'en_US',
      );
      isListening.value = true;
    } catch (_) {
      isListening.value = false;
    }
  }

  @override
  void onClose() {
    _scrollTimer?.cancel();
    if (_scrollListenerAttached) {
      scrollController.removeListener(_handleUserScroll);
    }
    textController.dispose();
    scrollController.dispose();
    super.onClose();
  }

  // ─── Session Management ─────────────────────────

  void acceptBatchMode() {
    batchModeAccepted.value = true;
    _hive.setSetting(AppConstants.keyBatchModeWarningAccepted, true);
  }

  void loadSessions() {
    final raw = _hive.getAllSessions();
    sessions.value = raw.map((m) => ChatSession.fromMap(m)).toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  void createNewChat() {
    final id = _uuid.v4();
    final session = ChatSession(id: id, title: 'New Chat');
    _hive.saveSession(id, session.toMap());
    sessions.insert(0, session);
    openChat(id);
  }

  void _resetInferenceContext() {
    final inference = Get.find<InferenceService>();
    if (inference.isModelLoaded.value) {
      unawaited(inference.resetConversation());
    }
  }

  void openChat(String sessionId) {
    stopGenerating();
    currentSessionId.value = sessionId;
    final raw = _hive.getMessagesForChat(sessionId);
    messages.value = raw.map((m) => ChatMessage.fromMap(m)).toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final inference = Get.find<InferenceService>();
    if (inference.isModelLoaded.value) {
      inference.refreshContextInfo();
    }
    _resetInferenceContext();
    _scrollToBottom(force: true);
  }

  void deleteChat(String sessionId) {
    if (currentSessionId.value == sessionId && isLoading.value) {
      stopGenerating();
    }
    _hive.deleteSession(sessionId);
    sessions.removeWhere((s) => s.id == sessionId);
    if (currentSessionId.value == sessionId) {
      currentSessionId.value = '';
      messages.clear();
    }
  }

  // ─── Image Handling ─────────────────────────────

  Future<void> pickImage() async {
    final picker = ImagePicker();
    final file = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: _visionImageMaxSide.toDouble(),
      maxHeight: _visionImageMaxSide.toDouble(),
      imageQuality: _visionImageJpegQuality,
    );
    if (file != null) {
      selectedImagePath.value = file.path;
      selectedImageBase64.value = null;
      selectedFileName.value = file.name;
      selectedFilePath.value = file.path;
      selectedFileType.value = 'image';
      selectedFileSize.value = await file.length();
      selectedFileContent.value = null;
      _checkVisionSupport();
    }
  }

  void clearImage({bool deleteFile = true}) {
    final path = selectedImagePath.value;
    selectedImagePath.value = null;
    selectedImageBase64.value = null;
    if (deleteFile && path != null && path.isNotEmpty) {
      try {
        final f = File(path);
        if (f.existsSync()) f.deleteSync();
      } catch (_) {}
    }
    if (selectedFileType.value == 'image') {
      clearFile();
    }
  }

  void _checkVisionSupport() {
    final s = Get.find<SettingsController>();
    if (s.inferenceMode.value != 'cloud') return;
    
    final provider = s.cloudProvider.value;
    String modelName = '';
    switch (provider) {
      case 'anthropic': modelName = s.anthropicModel.value; break;
      case 'google': modelName = s.googleModel.value; break;
      case 'kimi': modelName = s.kimiModel.value; break;
      case 'stability': modelName = s.stabilityModel.value; break;
      case 'nvidia': modelName = s.nvidiaModel.value; break;
      case 'openrouter': modelName = s.openRouterModel.value; break;
      case 'deepseek': modelName = s.deepSeekModel.value; break;
      case 'custom': modelName = s.customCloudModel.value; break;
      default: modelName = s.openaiModel.value; break;
    }
    
    final model = modelName.toLowerCase();
    
    // Known vision keywords in cloud model names
    final isVision = model.contains('vision') || 
                     model.contains('-vl') || 
                     model.contains('gpt-4o') || 
                     model.contains('claude-3') || 
                     model.contains('gemini') || 
                     model.contains('pixtral') || 
                     model.contains('llava') ||
                     model.contains('omni');
                     
    if (!isVision) {
      Get.snackbar(
        'Warning: Text-Only Model',
        'The selected model ($modelName) might not support images. If you get an error, switch to a vision model (like Gemini, GPT-4o, or Claude 3).',
        snackPosition: SnackPosition.TOP,
        duration: const Duration(seconds: 6),
        backgroundColor: const Color(0xFFFF9500).withValues(alpha: 0.95), // Warning Orange
        colorText: Colors.white,
        margin: const EdgeInsets.all(12),
      );
    }
  }

  Future<void> pickFile() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: [
          'png',
          'jpg',
          'jpeg',
          'webp',
          'gif',
          'heic',
          'pdf',
          'docx',
          'mp3',
          'm4a',
          'wav',
          'aac',
          'ogg',
          'flac',
          'txt',
          'md',
          'json',
          'csv',
          'log',
          'yaml',
          'yml',
          'xml',
          'dart',
          'kt',
          'java',
          'js',
          'ts',
          'py'
        ],
        withData: kIsWeb,
      );
      if (result == null) return;
      final file = result.files.single;
      final extension = file.extension?.toLowerCase() ?? '';
      final fileType = _attachmentTypeForExtension(extension);

      // Reject unsupported or extension-less files
      if (extension.isEmpty || fileType == 'file') {
        Get.snackbar(
          'Unsupported file',
          'Only images, audio, PDF, DOCX, and text/code files are supported.',
          snackPosition: SnackPosition.BOTTOM,
        );
        return;
      }

      if (fileType == 'image') {
        final bytes = file.bytes ??
            (file.path != null ? await File(file.path!).readAsBytes() : null);
        if (bytes == null) return;
        final optimizedPath = await _prepareVisionImagePath(
          bytes: bytes,
          originalName: file.name,
          fallbackPath: file.path,
        );

        selectedFileName.value = file.name;
        selectedFilePath.value = optimizedPath;
        selectedFileType.value = 'image';
        selectedFileSize.value = await File(optimizedPath).length();
        selectedFileContent.value = null;
        selectedImagePath.value = optimizedPath;
        selectedImageBase64.value = null;
        _checkVisionSupport();
        return;
      }

      selectedFileName.value = file.name;
      selectedFilePath.value = file.path;
      selectedFileType.value = fileType;
      selectedFileSize.value = file.size;
      selectedFileContent.value = null;

      selectedImagePath.value = null;
      selectedImageBase64.value = null;

      if (fileType == 'pdf' || fileType == 'docx') {
        final path = file.path;
        if (path != null) {
          try {
            var content = await DocumentExtractorService.extractText(
              path,
              extension,
            );
            if (content.length > 12000) {
              content =
                  '${content.substring(0, 12000)}\n\n[File truncated for context size]';
            }
            selectedFileContent.value = content;
          } catch (e) {
            Get.find<AppLogService>().warning(
              'Document extraction failed',
              details: e,
            );
            selectedFileContent.value = '[Could not extract text from ${selectedFileName.value}: $e]';
          }
        }
      } else if (fileType == 'text') {
        final bytes = file.bytes ??
            (file.path != null ? await File(file.path!).readAsBytes() : null);
        if (bytes == null) return;
        selectedFileSize.value = file.size > 0 ? file.size : bytes.length;
        var content = utf8.decode(bytes, allowMalformed: true);
        if (content.length > 12000) {
          content =
              '${content.substring(0, 12000)}\n\n[File truncated for context size]';
        }
        selectedFileContent.value = content;
      }
    } catch (e) {
      Get.find<AppLogService>().warning('File attachment failed', details: e);
      Get.snackbar('File not attached', '$e',
          snackPosition: SnackPosition.BOTTOM);
    }
  }

  void clearFile() {
    selectedFileName.value = null;
    selectedFileContent.value = null;
    selectedFilePath.value = null;
    selectedFileType.value = null;
    selectedFileSize.value = 0;
  }

  Future<String> _prepareVisionImagePath({
    required Uint8List bytes,
    required String originalName,
    String? fallbackPath,
  }) async {
    final resized = await compute(_resizeVisionImageBytes, {'bytes': bytes});
    if (resized == null) {
      if (fallbackPath != null && fallbackPath.isNotEmpty) return fallbackPath;
      final tempDir = await getTemporaryDirectory();
      final failedDecodeFile = File(
        '${tempDir.path}/ai_chat_image_${DateTime.now().millisecondsSinceEpoch}_$originalName',
      );
      await failedDecodeFile.writeAsBytes(bytes, flush: false);
      return failedDecodeFile.path;
    }

    if (resized.length == bytes.length &&
        fallbackPath != null &&
        fallbackPath.isNotEmpty) {
      return fallbackPath;
    }

    final tempDir = await getTemporaryDirectory();
    final file = File(
      '${tempDir.path}/ai_chat_vision_${DateTime.now().millisecondsSinceEpoch}.jpg',
    );
    await file.writeAsBytes(resized, flush: false);
    return file.path;
  }

  // ─── Send Message ───────────────────────────────

  Future<void> generateBatch() async {
    if (batchPrompts.isEmpty || isLoading.value || isStreaming.value) return;
    
    // Copy the list to avoid concurrent modification issues
    final promptsToRun = List<String>.from(batchPrompts);
    batchPrompts.clear();
    lastBatchImagesBase64.clear();

    final generatedImagesBase64 = <String>[];

    for (final prompt in promptsToRun) {
      textController.text = prompt;
      await sendMessage();
      final expectedSerial = _generationSerial;
      
      // Wait until the single image generation completes before starting the next
      while (isLoading.value) {
        await Future.delayed(const Duration(milliseconds: 500));
      }
      
      if (_generationSerial != expectedSerial) break; // User stopped it

      // Capture generated image
      final lastMsg = messages.lastOrNull;
      if (lastMsg != null && lastMsg.role == 'assistant' && lastMsg.imageBase64 != null) {
        generatedImagesBase64.add(lastMsg.imageBase64!);
      }
      
      // Add a small delay between generations to let UI breathe
      await Future.delayed(const Duration(milliseconds: 1000));
    }

    if (generatedImagesBase64.isNotEmpty) {
      lastBatchImagesBase64.value = generatedImagesBase64;
    }
  }

  Future<void> downloadLastBatch() async {
    if (lastBatchImagesBase64.isEmpty) return;
    try {
      final hasAccess = await Gal.hasAccess();
      if (!hasAccess) {
        final granted = await Gal.requestAccess();
        if (!granted) {
          Get.snackbar('Permission Denied', 'Cannot save images without gallery access.');
          return;
        }
      }
      for (final base64 in lastBatchImagesBase64) {
        await Gal.putImageBytes(base64Decode(base64));
      }
      Get.snackbar('Success', 'Saved ${lastBatchImagesBase64.length} images to gallery.', backgroundColor: const Color(0xFF34C759).withValues(alpha: 0.9), colorText: const Color(0xFFFFFFFF));
      lastBatchImagesBase64.clear();
    } catch (e) {
      Get.snackbar('Error', 'Failed to save images: $e');
    }
  }

  Future<void> sendMessage() async {
    if (isLoading.value || isStreaming.value) return;

    final text = textController.text.trim();
    final hasAttachment =
        selectedImagePath.value != null || selectedFileName.value != null;
    if (text.isEmpty && !hasAttachment) return;
    final fileName = selectedFileName.value;
    final fileContent = selectedFileContent.value;
    final filePath = selectedFilePath.value;
    final fileType = selectedFileType.value;
    final fileSize = selectedFileSize.value;
    final imagePath = selectedImagePath.value;
    final imageBase64 = selectedImageBase64.value;
    final visibleText =
        text.isEmpty ? _defaultAttachmentPrompt(fileType) : text;
    final effectiveText = (fileContent != null && fileContent.trim().isNotEmpty)
        ? '$visibleText\n\nAttached file: $fileName\n```text\n$fileContent\n```'
        : visibleText;

    // Create a session if none selected
    if (currentSessionId.value.isEmpty) {
      createNewChat();
    }

    // Encode image to base64 if it's not already pre-encoded, so the message
    // saved in history contains the image bytes and is 100% stable.
    String? imgBase64 = imageBase64;
    if (imgBase64 == null && imagePath != null && !kIsWeb) {
      try {
        imgBase64 = base64Encode(await File(imagePath).readAsBytes());
      } catch (_) {}
    }

    // Add user message
    final userMsg = ChatMessage(
      id: _uuid.v4(),
      chatId: currentSessionId.value,
      role: 'user',
      content: effectiveText,
      imageBase64: imgBase64, // Always save the encoded base64 string
      imagePath: imagePath,
      fileName: fileName,
      fileContent: fileContent,
      filePath: filePath,
      fileType: fileType,
      fileSize: fileSize > 0 ? fileSize : null,
    );
    messages.add(userMsg);
    _hive.saveMessage(userMsg.id, userMsg.toMap());

    // Clear input preview UI state — but KEEP the physical file on disk 
    // because the native inference engine needs to read it during generation.
    textController.clear();
    inputText.value = '';
    clearImage(deleteFile: false); // Reset visual fields, do NOT delete file!
    clearFile();
    _scrollToBottom(force: true);

    // Update session title (use first message as title)
    if (messages.where((m) => m.role == 'user').length == 1) {
      final title = visibleText.length > 40
          ? '${visibleText.substring(0, 40)}...'
          : visibleText;
      final session =
          sessions.firstWhere((s) => s.id == currentSessionId.value);
      final updated = session.copyWith(title: title, lastMessage: visibleText);
      _hive.saveSession(updated.id, updated.toMap());
      final idx = sessions.indexWhere((s) => s.id == updated.id);
      if (idx >= 0) sessions[idx] = updated;
    }

    // Start generating
    final generationId = ++_generationSerial;
    isLoading.value = true;
    isStreaming.value = true;
    streamingAttachmentType.value =
        (imagePath != null || fileType == 'audio') ? fileType : null;
    streamingResponse.value = '';
    _followStreaming = true;
    _scrollToBottom(force: true);

    try {
      DateTime? thoughtStartedAt;
      int? thoughtDurationSeconds;

      void trackThoughtTiming() {
        final parts = splitThoughtTags(streamingResponse.value);
        if (parts.hasThought && parts.isThinking && thoughtStartedAt == null) {
          thoughtStartedAt = DateTime.now();
        }
        if (parts.hasThought &&
            !parts.isThinking &&
            thoughtStartedAt != null &&
            thoughtDurationSeconds == null) {
          thoughtDurationSeconds =
              DateTime.now().difference(thoughtStartedAt!).inSeconds;
        }
      }

      final inferenceMode = _hive.getSetting(
            AppConstants.keyInferenceMode,
            defaultValue: 'local',
          ) ??
          'local';

      String rawResponse;

      // Build conversation history
      final history = messages
          .where((m) => m.role == 'user' || m.role == 'assistant')
          .map((m) => {
                'role': m.role,
                'content': m.role == 'assistant'
                    ? splitThoughtTags(m.content).answer
                    : m.content,
              })
          .toList();

      if (inferenceMode == 'local') {
        final localImage = Get.find<LocalImageService>();

        if (localImage.isModelLoaded.value) {
          // Local image generation
          final settings = Get.find<SettingsController>();
          final imageNotifications =
              Get.find<ImageGenerationNotificationService>();
          final steps = _hive.getSetting<int>(AppConstants.keyImageSteps,
              defaultValue: AppConstants.defaultImageSteps) ??
              AppConstants.defaultImageSteps;
          final sizeSetting = settings.imageGenSize.value;
          final sizeLabel =
              sizeSetting == 0 ? 'Auto size' : '${sizeSetting}x$sizeSetting';
          final backendLabel = localImage.currentBackend.value == Backend.cpu
              ? 'CPU'
              : localImage.currentBackend.value.displayName
                  .split(' ')
                  .first
                  .toUpperCase();
          imageGenStep.value = 0;
          imageGenTotal.value = steps;
          imageGenEstimatedSecs.value = 0;
          imageGenStartTime.value = DateTime.now();
          imageGenDecoding.value = false;
          await imageNotifications.start(
            modelName: localImage.loadedModelName.value,
            backend: backendLabel,
            steps: steps,
            sizeLabel: sizeLabel,
          );
          print('[ChatController] Starting image generation for: $text');
          final pngBytes = await localImage.generateImage(
            prompt: text,
            onProgress: (step, total) {
              print('[ChatController] Progress callback: step=$step, total=$total');
              imageGenStep.value = step;
              imageGenTotal.value = total;
              if (step >= total && total > 0) {
                imageGenDecoding.value = true;
                print('[ChatController] Sampling complete, VAE decode in progress');
                imageNotifications.decoding();
              }
              if (step > 0 && total > 0 && step < total) {
                final start = imageGenStartTime.value;
                if (start != null) {
                  final elapsed = DateTime.now().difference(start).inMilliseconds;
                  final avgMsPerStep = elapsed / step;
                  final remainingSteps = total - step;
                  imageGenEstimatedSecs.value =
                      (avgMsPerStep * remainingSteps / 1000).ceil();
                }
              }
              imageNotifications.update(
                step: step,
                total: total,
                etaSeconds: imageGenEstimatedSecs.value,
                elapsedSeconds: imageGenStartTime.value == null
                    ? 0
                    : DateTime.now()
                        .difference(imageGenStartTime.value!)
                        .inSeconds,
              );
              _scrollToBottom();
            },
          );
          // Calculate total generation time
          final genDurationMs = imageGenStartTime.value != null
              ? DateTime.now().difference(imageGenStartTime.value!).inMilliseconds
              : null;
          print('[ChatController] generateImage returned, bytes=${pngBytes?.length}, duration=${genDurationMs}ms');

          if (pngBytes != null) {
            await imageNotifications.complete(durationMs: genDurationMs ?? 0);
            rawResponse = '[IMAGE_BASE64]${base64Encode(pngBytes)}';
          } else {
            await imageNotifications.failed();
            rawResponse = '❌ Local image generation failed.';
          }
        } else {
          final inference = Get.find<InferenceService>();

          // LiteRT models can consume image/audio attachments. GGUF currently
          // returns a clear unsupported message from the inference layer.

          rawResponse = await inference.generate(
            prompt: effectiveText,
            systemPrompt: _effectiveSystemPrompt,
            conversationHistory: history,
            source: 'chat',
            imagePath: imagePath,
            audioPath: fileType == 'audio' ? filePath : null,
            onToken: (token) {
              // Real-time streaming update
              streamingResponse.value += token;
              trackThoughtTiming();
              _scrollToBottom();
            },
          );
        }
      } else {
        final cloud = Get.find<CloudService>();
        final apiMessages = [
          {'role': 'system', 'content': _effectiveSystemPrompt},
          ...history,
        ];
        rawResponse = await cloud.sendMessage(
          messages: apiMessages,
          imageBase64: imgBase64, // already encoded before clearImage()
          onToken: (token) {
            streamingResponse.value += token;
            trackThoughtTiming();
            _scrollToBottom();
          },
        );
      }

      if (thoughtStartedAt != null && thoughtDurationSeconds == null) {
        thoughtDurationSeconds =
            DateTime.now().difference(thoughtStartedAt!).inSeconds;
      }

      if (generationId != _generationSerial) return;

      // Stop streaming UI
      final tps = inferenceMode == 'local'
          ? Get.find<InferenceService>().tokensPerSecond.value
          : null;
      isStreaming.value = false;
      streamingAttachmentType.value = null;
      streamingResponse.value = '';
      imageGenStep.value = 0;
      imageGenTotal.value = 0;
      imageGenDecoding.value = false;

      String? outImageBase64;
      if (rawResponse.startsWith('[IMAGE_BASE64]')) {
        outImageBase64 = rawResponse.substring('[IMAGE_BASE64]'.length);
        rawResponse = 'Here is your generated image:';
      }

      // Calculate total generation time for image gen
      final genDurationMs = imageGenStartTime.value != null
          ? DateTime.now().difference(imageGenStartTime.value!).inMilliseconds
          : null;

      // Display response directly (no command processing)
      final aiMsg = ChatMessage(
        id: _uuid.v4(),
        chatId: currentSessionId.value,
        role: 'assistant',
        content: rawResponse,
        imageBase64: outImageBase64,
        tokensPerSec: tps,
        thoughtDurationSeconds: thoughtDurationSeconds,
        imageGenDurationMs: genDurationMs,
      );
      messages.add(aiMsg);
      _hive.saveMessage(aiMsg.id, aiMsg.toMap());
      imageGenStartTime.value = null;

      // Update session
      final session =
          sessions.firstWhereOrNull((s) => s.id == currentSessionId.value);
      if (session != null) {
        final updated = session.copyWith(lastMessage: aiMsg.content);
        _hive.saveSession(updated.id, updated.toMap());
        final idx = sessions.indexWhere((s) => s.id == updated.id);
        if (idx >= 0) sessions[idx] = updated;
      }
    } catch (e) {
      if (generationId != _generationSerial) return;
      isStreaming.value = false;
      streamingAttachmentType.value = null;
      streamingResponse.value = '';
      imageGenStep.value = 0;
      imageGenTotal.value = 0;
      imageGenDecoding.value = false;
      if (imageGenStartTime.value != null) {
        await Get.find<ImageGenerationNotificationService>().failed();
      }
      imageGenStartTime.value = null;
      Get.find<AppLogService>().error('Chat response failed', details: e);
      final errorMsg = ChatMessage(
        id: _uuid.v4(),
        chatId: currentSessionId.value,
        role: 'assistant',
        content: '❌ Error: $e',
      );
      messages.add(errorMsg);
      _hive.saveMessage(errorMsg.id, errorMsg.toMap());
    }

    if (generationId == _generationSerial) {
      isLoading.value = false;
      _scrollToBottom();
    }
  }

  void stopGenerating() {
    if (!isLoading.value && !isStreaming.value) return;
    final partialResponse = streamingResponse.value.trim();
    if (partialResponse.isNotEmpty) {
      final tps = Get.find<InferenceService>().tokensPerSecond.value;
      _saveAssistantMessage(
        content: partialResponse,
        tokensPerSec: tps > 0 ? tps : null,
      );
    }
    _generationSerial++;
    isLoading.value = false;
    isStreaming.value = false;
    streamingAttachmentType.value = null;
    streamingResponse.value = '';
    Get.find<ImageGenerationNotificationService>().cancel();
    imageGenStep.value = 0;
    imageGenTotal.value = 0;
    imageGenEstimatedSecs.value = 0;
    imageGenStartTime.value = null;
    imageGenDecoding.value = false;
    unawaited(Get.find<InferenceService>().stopGeneration());
    Get.find<LocalImageService>().cancelGeneration();
  }

  void _saveAssistantMessage({
    required String content,
    String? imageBase64,
    double? tokensPerSec,
    int? thoughtDurationSeconds,
  }) {
    final aiMsg = ChatMessage(
      id: _uuid.v4(),
      chatId: currentSessionId.value,
      role: 'assistant',
      content: content,
      imageBase64: imageBase64,
      tokensPerSec: tokensPerSec,
      thoughtDurationSeconds: thoughtDurationSeconds,
    );
    messages.add(aiMsg);
    _hive.saveMessage(aiMsg.id, aiMsg.toMap());

    final session =
        sessions.firstWhereOrNull((s) => s.id == currentSessionId.value);
    if (session != null) {
      final updated = session.copyWith(lastMessage: aiMsg.content);
      _hive.saveSession(updated.id, updated.toMap());
      final idx = sessions.indexWhere((s) => s.id == updated.id);
      if (idx >= 0) sessions[idx] = updated;
    }
  }

  void _handleUserScroll() {
    if (!scrollController.hasClients) return;
    final position = scrollController.position;
    final distanceFromBottom = position.maxScrollExtent - position.pixels;
    if (!isStreaming.value) {
      _followStreaming = distanceFromBottom <= 180;
    } else if (distanceFromBottom <= 48) {
      _followStreaming = true;
    }
  }

  void pauseStreamingFollow() {
    if (isStreaming.value) {
      _followStreaming = false;
    }
  }

  void resumeStreamingFollowIfNearBottom() {
    if (!scrollController.hasClients) return;
    final position = scrollController.position;
    final distanceFromBottom = position.maxScrollExtent - position.pixels;
    if (distanceFromBottom <= 48) {
      _followStreaming = true;
    }
  }

  void _scrollToBottom({bool force = false}) {
    if (!force && isStreaming.value && !_followStreaming) return;
    if (_scrollTimer?.isActive == true) return;

    _scrollTimer = Timer(const Duration(milliseconds: 80), () {
      if (!scrollController.hasClients) return;
      if (!force && isStreaming.value && !_followStreaming) return;
      final target = scrollController.position.maxScrollExtent;
      if ((target - scrollController.position.pixels).abs() < 8) return;
      scrollController.animateTo(
        target,
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOutCubic,
      );
    });
  }

  String get _effectiveSystemPrompt {
    final settings = Get.find<SettingsController>();
    final inference = Get.find<InferenceService>();
    final modelName = settings.inferenceMode.value == 'local'
        ? inference.loadedModelName.value
        : settings.selectedCloudModelName;
    return settings.effectiveSystemPromptForModel(
      modelName,
    );
  }

  String _attachmentTypeForExtension(String extension) {
    const imageExtensions = {'png', 'jpg', 'jpeg', 'webp', 'gif', 'heic'};
    const audioExtensions = {'mp3', 'm4a', 'wav', 'aac', 'ogg', 'flac'};
    const textExtensions = {
      'txt',
      'md',
      'json',
      'csv',
      'log',
      'yaml',
      'yml',
      'xml',
      'dart',
      'kt',
      'java',
      'js',
      'ts',
      'py',
    };
    if (imageExtensions.contains(extension)) return 'image';
    if (audioExtensions.contains(extension)) return 'audio';
    if (extension == 'pdf') return 'pdf';
    if (extension == 'docx') return 'docx';
    if (textExtensions.contains(extension)) return 'text';
    return 'file';
  }

  String _defaultAttachmentPrompt(String? fileType) {
    switch (fileType) {
      case 'image':
        return 'Describe this image.';
      case 'pdf':
        return 'Summarize this PDF.';
      case 'docx':
        return 'Summarize this document.';
      case 'audio':
        return 'Transcribe or analyze this audio.';
      case 'text':
        return 'Review this file.';
      default:
        return 'Review this attachment.';
    }
  }
}
