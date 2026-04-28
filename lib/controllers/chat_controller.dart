import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';
import '../core/constants.dart';
import '../models/chat_message.dart';
import '../models/chat_session.dart';
import '../services/hive_service.dart';
import '../services/inference_service.dart';
import '../services/cloud_service.dart';
import '../services/local_image_service.dart';

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

  // ─── Send Message ───────────────────────────────

  Future<void> sendMessage() async {
    final text = textController.text.trim();
    if (text.isEmpty) return;

    // Create a session if none selected
    if (currentSessionId.value.isEmpty) {
      createNewChat();
    }

    // Add user message
    final userMsg = ChatMessage(
      id: _uuid.v4(),
      chatId: currentSessionId.value,
      role: 'user',
      content: text,
      imageBase64: selectedImageBase64.value,
      imagePath: selectedImagePath.value,
    );
    messages.add(userMsg);
    _hive.saveMessage(userMsg.id, userMsg.toMap());

    // Clear input
    textController.clear();
    inputText.value = '';
    final imgBase64 = selectedImageBase64.value;
    clearImage();
    _scrollToBottom();

    // Update session title (use first message as title)
    if (messages.where((m) => m.role == 'user').length == 1) {
      final title = text.length > 40 ? '${text.substring(0, 40)}...' : text;
      final session = sessions.firstWhere((s) => s.id == currentSessionId.value);
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
      final inferenceMode = _hive.getSetting(
            AppConstants.keyInferenceMode,
            defaultValue: 'cloud',
          ) ??
          'cloud';

      String rawResponse;

      // Build conversation history
      final history = messages
          .where((m) => m.role == 'user' || m.role == 'assistant')
          .map((m) => {'role': m.role, 'content': m.content})
          .toList();

      if (inferenceMode == 'local') {
        final localImage = Get.find<LocalImageService>();
        
        if (localImage.isModelLoaded.value) {
          // Local image generation
          final pngBytes = await localImage.generateImage(
            prompt: text,
            onProgress: (step, total) {
              streamingResponse.value = 'Generating locally... ($step/$total)';
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
            prompt: text,
            systemPrompt: _effectiveSystemPrompt,
            conversationHistory: history,
            source: 'chat',
            imagePath: selectedImagePath.value,
            onToken: (token) {
              // Real-time streaming update
              streamingResponse.value += token;
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
        );
      }

      // Stop streaming UI
      final tps = inferenceMode == 'local' ? Get.find<InferenceService>().tokensPerSecond.value : null;
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
    final inferenceMode = _hive.getSetting(
          AppConstants.keyInferenceMode,
          defaultValue: 'cloud',
        ) ??
        'cloud';

    String modelName = '';
    if (inferenceMode == 'local') {
      modelName = _hive.getSetting<String>(AppConstants.keyLocalModelName) ?? '';
    } else {
      final provider = _hive.getSetting(AppConstants.keyCloudProvider) ?? 'kimi';
      modelName = _hive.getSetting(provider == 'openai' ? AppConstants.keyOpenaiModel : 
                                 provider == 'anthropic' ? AppConstants.keyAnthropicModel :
                                 provider == 'google' ? AppConstants.keyGoogleModel : 
                                 provider == 'stability' ? AppConstants.keyStabilityModel : AppConstants.keyKimiModel) ?? '';
    }

    final lower = modelName.toLowerCase();
    if (lower.contains('uncensored') || lower.contains('abliterated') || lower.contains('dolphin')) {
      // Uncensored models work best with NO system prompt (like in Termux/llama-server)
      // to avoid triggering residual safety alignment.
      return '';
    }
    return AppConstants.systemPrompt;
  }
}
