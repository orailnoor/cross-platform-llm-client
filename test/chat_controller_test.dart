import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:privatelm/controllers/chat_controller.dart';
import 'package:privatelm/controllers/settings_controller.dart';
import 'package:privatelm/core/constants.dart';
import 'package:privatelm/services/app_log_service.dart';
import 'package:privatelm/services/cloud_service.dart';
import 'package:privatelm/services/hive_service.dart';
import 'package:privatelm/services/image_generation_notification_service.dart';
import 'package:privatelm/services/inference_service.dart';
import 'package:privatelm/services/local_image_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late HiveService hive;
  late ChatController chat;
  late _RecordingCloud cloud;
  late String firstChatId;
  late String secondChatId;
  const imageBytes = [1, 2, 3];

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('chat_test');
    Hive.init(dir.path);
    hive = await HiveService().init();
    Get.put(hive);
    await hive.setSetting(AppConstants.keyInferenceMode, 'cloud');
    Get.put(AppLogService());
    Get.put(SettingsController());
    Get.put(InferenceService());
    Get.put(LocalImageService());
    Get.put(ImageGenerationNotificationService());
    cloud = _RecordingCloud();
    Get.put<CloudService>(cloud);
    chat = ChatController();
    chat.createNewChat();
    firstChatId = chat.currentSessionId.value;
    chat.createNewChat();
    secondChatId = chat.currentSessionId.value;
    chat.openChat(firstChatId);

    final image =
        await File('${dir.path}/attachment.jpg').writeAsBytes(imageBytes);
    chat.textController.text = 'Describe the first chat image';
    chat.selectedImagePath.value = image.path;
  });

  tearDown(() async {
    chat.onClose();
    Get.reset();
    await Hive.deleteFromDisk();
    await dir.delete(recursive: true);
  });

  test('switching chats during attachment loading does not send the old draft',
      () async {
    final pending = chat.sendMessage();
    // File.readAsBytes yields; switch synchronously before it can finish.
    expect(chat.isLoading.value, isTrue);
    chat.openChat(secondChatId);
    chat.textController.text = 'New chat draft';
    await pending;

    expect(cloud.requests, 0);
    expect(chat.currentSessionId.value, secondChatId);
    expect(chat.messages, isEmpty);
    expect(hive.getMessagesForChat(firstChatId), isEmpty);
    expect(hive.getMessagesForChat(secondChatId), isEmpty);
    expect(chat.textController.text, 'New chat draft');
    expect(chat.isLoading.value, isFalse);
    expect(chat.isStreaming.value, isFalse);
  });

  test('stopping during attachment loading does not restart generation',
      () async {
    final pending = chat.sendMessage();
    chat.stopGenerating();
    chat.textController.text = 'Edited draft';
    await pending;

    expect(cloud.requests, 0);
    expect(chat.messages, isEmpty);
    expect(hive.getMessagesForChat(firstChatId), isEmpty);
    expect(chat.textController.text, 'Edited draft');
    expect(chat.isLoading.value, isFalse);
    expect(chat.isStreaming.value, isFalse);
  });

  test(
      'deleting a chat during attachment loading does not recreate its messages',
      () async {
    final pending = chat.sendMessage();
    chat.deleteChat(firstChatId);
    await pending;

    expect(cloud.requests, 0);
    expect(chat.currentSessionId.value, isEmpty);
    expect(chat.messages, isEmpty);
    expect(hive.messagesBox.isEmpty, isTrue);
    expect(hive.sessionsBox.containsKey(firstChatId), isFalse);
    expect(chat.isLoading.value, isFalse);
  });

  test('an uninterrupted attachment send persists the image and reply',
      () async {
    await chat.sendMessage();

    expect(cloud.requests, 1);
    expect(cloud.imageBase64, base64Encode(imageBytes));
    final saved = hive.getMessagesForChat(firstChatId);
    expect(saved, hasLength(2));
    expect(saved.singleWhere((m) => m['role'] == 'user')['imageBase64'],
        base64Encode(imageBytes));
    expect(saved.singleWhere((m) => m['role'] == 'assistant')['content'],
        'Image reply');
    expect(chat.isLoading.value, isFalse);
    expect(chat.isStreaming.value, isFalse);
  });
}

/// Replaces only the external provider; controller and persistence stay real.
class _RecordingCloud extends CloudService {
  int requests = 0;
  String? imageBase64;

  @override
  Future<String> sendMessage({
    required List<Map<String, String>> messages,
    String? imageBase64,
    double? temperature,
    int? maxTokens,
    void Function(String token)? onToken,
  }) async {
    requests++;
    this.imageBase64 = imageBase64;
    return 'Image reply';
  }
}
