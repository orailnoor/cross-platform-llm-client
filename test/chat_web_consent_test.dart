import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:http/testing.dart';
import 'package:privatelm/controllers/chat_controller.dart';
import 'package:privatelm/services/cloud_service.dart';
import 'package:privatelm/services/hive_service.dart';
import 'package:privatelm/services/inference_service.dart';
import 'package:privatelm/services/local_image_service.dart';
import 'package:privatelm/services/parallel_search_service.dart';

void main() {
  late Directory dir;
  late HiveService hive;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('web_consent');
    Hive.init(dir.path);
    hive = await HiveService().init();
  });
  tearDown(() async {
    Get.reset();
    await Hive.deleteFromDisk();
    await dir.delete(recursive: true);
  });
  testWidgets(
      'real consent dialog cancels without transmitting or storing a turn',
      (tester) async {
    Get.put(hive);
    Get.put(InferenceService());
    Get.put(CloudService());
    Get.put(LocalImageService());
    var networkCalls = 0;
    Get.put(ParallelSearchService(
        clientFactory: () => MockClient((_) async {
              networkCalls++;
              throw StateError('No network before consent');
            })));
    final controller = ChatController();
    controller.currentSessionId.value = '00000000-0000-4000-8000-000000000001';
    await tester
        .pumpWidget(const GetMaterialApp(home: Scaffold(body: SizedBox())));
    controller.textController.text = '/search current Flutter stable version';
    final pending = controller.sendMessage();
    await tester.pumpAndSettle();
    expect(find.text('Use Parallel web search?'), findsOneWidget);
    expect(
        find.textContaining('Your chat history and attachments are not sent'),
        findsOneWidget);
    expect(networkCalls, 0);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await pending;
    expect(networkCalls, 0);
    expect(controller.messages, isEmpty);
    expect(hive.getMessagesForChat(controller.currentSessionId.value), isEmpty);
    expect(controller.textController.text, startsWith('/search'));
    controller.onClose();
    await tester.pumpWidget(const SizedBox());
  });
}
