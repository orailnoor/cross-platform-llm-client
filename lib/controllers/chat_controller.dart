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
import 'package:uuid/uuid.dart';
import '../controllers/settings_controller.dart';
import '../core/constants.dart';
import '../models/chat_message.dart';
import '../models/chat_session.dart';
import '../services/hive_service.dart';
import '../services/inference_service.dart';
import '../services/cloud_service.dart';
import '../services/local_image_service.dart';
import '../services/app_log_service.dart';
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

  // Real-time streaming state — the AI response as it's being generated
  final streamingResponse = ''.obs;
  final isStreaming = false.obs;
  final streamingAttachmentType = Rxn<String>();

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
    loadSessions();
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

  void openChat(String sessionId) {
    currentSessionId.value = sessionId;
    final raw = _hive.getMessagesForChat(sessionId);
    messages.value = raw.map((m) => ChatMessage.fromMap(m)).toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    final inference = Get.find<InferenceService>();
    if (inference.isModelLoaded.value) {
      inference.refreshContextInfo();
    }
    _scrollToBottom(force: true);
  }

  void deleteChat(String sessionId) {
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
    }
  }

  void clearImage() {
    selectedImagePath.value = null;
    selectedImageBase64.value = null;
    if (selectedFileType.value == 'image') {
      clearFile();
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
        return;
      }

      selectedFileName.value = file.name;
      selectedFilePath.value = file.path;
      selectedFileType.value = fileType;
      selectedFileSize.value = file.size;
      selectedFileContent.value = null;

      selectedImagePath.value = null;
      selectedImageBase64.value = null;

      if (fileType == 'text') {
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
    final effectiveText = fileContent == null
        ? visibleText
        : '$visibleText\n\nAttached file: $fileName\n```text\n$fileContent\n```';

    // Create a session if none selected
    if (currentSessionId.value.isEmpty) {
      createNewChat();
    }

    // Add user message
    final userMsg = ChatMessage(
      id: _uuid.v4(),
      chatId: currentSessionId.value,
      role: 'user',
      content: effectiveText,
      imageBase64: imageBase64,
      imagePath: imagePath,
      fileName: fileName,
      fileContent: fileContent,
      filePath: filePath,
      fileType: fileType,
      fileSize: fileSize > 0 ? fileSize : null,
    );
    messages.add(userMsg);
    _hive.saveMessage(userMsg.id, userMsg.toMap());

    // Clear input
    textController.clear();
    inputText.value = '';
    final imgBase64 = imageBase64;
    clearImage();
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
            defaultValue: 'cloud',
          ) ??
          'cloud';

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
          final pngBytes = await localImage.generateImage(
            prompt: text,
            onProgress: (step, total) {
              final estSec = (total - step) * 20; // ~20 sec per step on CPU
              final estText = estSec > 60
                  ? '${(estSec / 60).ceil()} min remaining'
                  : '$estSec sec remaining';
              streamingResponse.value =
                  'Generating image... step $step/$total · ~$estText';
              trackThoughtTiming();
              _scrollToBottom();
            },
          );

          if (pngBytes != null) {
            rawResponse = '[IMAGE_BASE64]${base64Encode(pngBytes)}';
          } else {
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
          imageBase64: imgBase64,
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

      String? outImageBase64;
      if (rawResponse.startsWith('[IMAGE_BASE64]')) {
        outImageBase64 = rawResponse.substring('[IMAGE_BASE64]'.length);
        rawResponse = 'Here is your generated image:';
      }

      // Display response directly (no command processing)
      final aiMsg = ChatMessage(
        id: _uuid.v4(),
        chatId: currentSessionId.value,
        role: 'assistant',
        content: rawResponse,
        imageBase64: outImageBase64,
        tokensPerSec: tps,
        thoughtDurationSeconds: thoughtDurationSeconds,
      );
      messages.add(aiMsg);
      _hive.saveMessage(aiMsg.id, aiMsg.toMap());

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
    unawaited(Get.find<InferenceService>().stopGeneration());
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
    if (textExtensions.contains(extension)) return 'text';
    return 'file';
  }

  String _defaultAttachmentPrompt(String? fileType) {
    switch (fileType) {
      case 'image':
        return 'Describe this image.';
      case 'pdf':
        return 'Summarize this PDF.';
      case 'audio':
        return 'Transcribe or analyze this audio.';
      case 'text':
        return 'Review this file.';
      default:
        return 'Review this attachment.';
    }
  }
}
