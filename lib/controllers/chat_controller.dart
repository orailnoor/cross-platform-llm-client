import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:get/get.dart';
import 'package:image_picker/image_picker.dart';
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

  // Real-time streaming state — the AI response as it's being generated
  final streamingResponse = ''.obs;
  final isStreaming = false.obs;

  final textController = TextEditingController();
  final scrollController = ScrollController();

  @override
  void onInit() {
    super.onInit();
    loadSessions();
  }

  @override
  void onClose() {
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
    _scrollToBottom();
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
      maxWidth: 1024,
      maxHeight: 1024,
      imageQuality: 80,
    );
    if (file != null) {
      selectedImagePath.value = file.path;
      final bytes = await file.readAsBytes();
      selectedImageBase64.value = base64Encode(bytes);
    }
  }

  void clearImage() {
    selectedImagePath.value = null;
    selectedImageBase64.value = null;
  }

  Future<void> pickFile() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: [
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
      String content;
      if (file.bytes != null) {
        content = utf8.decode(file.bytes!, allowMalformed: true);
      } else if (file.path != null) {
        content = await File(file.path!).readAsString();
      } else {
        return;
      }
      if (content.length > 12000) {
        content =
            '${content.substring(0, 12000)}\n\n[File truncated for context size]';
      }
      selectedFileName.value = file.name;
      selectedFileContent.value = content;
    } catch (e) {
      Get.find<AppLogService>().warning('File attachment failed', details: e);
      Get.snackbar('File not attached', '$e',
          snackPosition: SnackPosition.BOTTOM);
    }
  }

  void clearFile() {
    selectedFileName.value = null;
    selectedFileContent.value = null;
  }

  // ─── Send Message ───────────────────────────────

  Future<void> sendMessage() async {
    if (isLoading.value || isStreaming.value) return;

    final text = textController.text.trim();
    if (text.isEmpty) return;
    final fileName = selectedFileName.value;
    final fileContent = selectedFileContent.value;
    final effectiveText = fileContent == null
        ? text
        : '$text\n\nAttached file: $fileName\n```text\n$fileContent\n```';

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
      imageBase64: selectedImageBase64.value,
      imagePath: selectedImagePath.value,
      fileName: fileName,
      fileContent: fileContent,
    );
    messages.add(userMsg);
    _hive.saveMessage(userMsg.id, userMsg.toMap());

    // Clear input
    textController.clear();
    inputText.value = '';
    final imgBase64 = selectedImageBase64.value;
    clearImage();
    clearFile();
    _scrollToBottom();

    // Update session title (use first message as title)
    if (messages.where((m) => m.role == 'user').length == 1) {
      final title = text.length > 40 ? '${text.substring(0, 40)}...' : text;
      final session =
          sessions.firstWhere((s) => s.id == currentSessionId.value);
      final updated = session.copyWith(title: title, lastMessage: text);
      _hive.saveSession(updated.id, updated.toMap());
      final idx = sessions.indexWhere((s) => s.id == updated.id);
      if (idx >= 0) sessions[idx] = updated;
    }

    // Start generating
    isLoading.value = true;
    isStreaming.value = true;
    streamingResponse.value = '';
    _scrollToBottom();

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
              streamingResponse.value = 'Generating locally... ($step/$total)';
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

          // Local models support image analysis if it's a vision model (e.g. Qwen2-VL)
          // We pass the image path directly to the inference service below.

          rawResponse = await inference.generate(
            prompt: effectiveText,
            systemPrompt: _effectiveSystemPrompt,
            conversationHistory: history,
            source: 'chat',
            imagePath: selectedImagePath.value,
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

      // Stop streaming UI
      final tps = inferenceMode == 'local'
          ? Get.find<InferenceService>().tokensPerSecond.value
          : null;
      isStreaming.value = false;
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
      isStreaming.value = false;
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

    isLoading.value = false;
    _scrollToBottom();
  }

  void _scrollToBottom() {
    Future.delayed(const Duration(milliseconds: 50), () {
      if (scrollController.hasClients) {
        scrollController.animateTo(
          scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
        );
      }
    });
  }

  String get _effectiveSystemPrompt {
    final settings = Get.find<SettingsController>();
    return settings.globalSystemPrompt.value;
  }
}
