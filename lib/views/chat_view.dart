import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import '../controllers/chat_controller.dart';
import '../controllers/settings_controller.dart';
import '../controllers/model_controller.dart';
import '../controllers/home_controller.dart';
import '../services/inference_service.dart';
import '../services/local_image_service.dart';
import '../ffi/sd_ffi_bindings.dart';
import '../utils/thought_parser.dart';
import '../widgets/attachment_preview.dart';
import '../widgets/chat_bubble.dart';
import '../widgets/thought_disclosure.dart';

// ── Apple-style color helpers ──
Color _appleBlue(BuildContext c) => Theme.of(c).brightness == Brightness.dark
    ? const Color(0xFF0A84FF)
    : const Color(0xFF007AFF);

Color _aiBubble(BuildContext c) => Theme.of(c).brightness == Brightness.dark
    ? const Color(0xFF1C1C1E)
    : const Color(0xFFF2F2F7);

Color _sep(BuildContext c) => Theme.of(c).brightness == Brightness.dark
    ? Colors.white.withValues(alpha: 0.08)
    : Colors.black.withValues(alpha: 0.08);

class ChatView extends GetView<ChatController> {
  const ChatView({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    Widget scaffold = Scaffold(
      backgroundColor: isDark ? Colors.black : Colors.white,
      appBar: _appBar(context, isDark),
      body: Column(
        children: [
          _modelLoadingBar(context, isDark),
          _contextBar(context, isDark),
          Expanded(child: Obx(() {
            if (controller.currentSessionId.value.isEmpty ||
                controller.messages.isEmpty)
              return _emptyState(context, isDark);
            final streaming = controller.isStreaming.value;
            final text = controller.streamingResponse.value;
            final n = controller.messages.length;
            return NotificationListener<ScrollUpdateNotification>(
              onNotification: (note) {
                if (note.dragDetails != null && streaming) {
                  if ((note.scrollDelta ?? 0) < 0)
                    controller.pauseStreamingFollow();
                  else
                    controller.resumeStreamingFollowIfNearBottom();
                }
                return false;
              },
              child: ListView.builder(
                controller: controller.scrollController,
                padding: const EdgeInsets.only(top: 8, bottom: 8),
                itemCount: n + (streaming ? 1 : 0),
                itemBuilder: (_, i) {
                  if (i == n && streaming)
                    return Obx(() => _streamBubble(context, text, isDark));
                  return ChatBubble(message: controller.messages[i]);
                },
              ),
            );
          })),
          _inputBar(context, isDark),
        ],
      ),
    );

    if (Platform.isIOS) {
      return GestureDetector(
        onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
        behavior: HitTestBehavior.translucent,
        child: scaffold,
      );
    }
    return scaffold;
  }

  // ── AppBar ──
  PreferredSizeWidget _appBar(BuildContext context, bool isDark) {
    return AppBar(
      backgroundColor: isDark ? Colors.black : Colors.white,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(0.5),
        child: Container(height: 0.5, color: _sep(context)),
      ),
      titleSpacing: 0,
      title: Obx(() {
        final sid = controller.currentSessionId.value;
        final settings = Get.find<SettingsController>();
        final inf = Get.find<InferenceService>();
        final isLocal = settings.inferenceMode.value == 'local';
        String model;
        if (isLocal) {
          final localImage = Get.find<LocalImageService>();
          if (inf.isModelLoaded.value) {
            model = inf.loadedModelName.value
                .replaceAll('.gguf', '')
                .replaceAll('.GGUF', '');
          } else if (localImage.isModelLoaded.value) {
            final backend = localImage.currentBackend.value;
            final backendEmoji = backend == Backend.cpu ? '🖥' : '⚡';
            final backendName = backend.displayName.split(' ').first;
            model = '$backendEmoji $backendName · ${localImage.loadedModelName.value
                .replaceAll('.gguf', '')
                .replaceAll('.GGUF', '')}';
          } else {
            model = 'No model loaded';
          }
          if (model.length > 24) model = '${model.substring(0, 24)}…';
        } else {
          final p = settings.cloudProvider.value;
          model = p == 'openai'
              ? settings.openaiModel.value
              : p == 'anthropic'
                  ? settings.anthropicModel.value
                  : p == 'google'
                      ? settings.googleModel.value
                      : p == 'stability'
                          ? settings.stabilityModel.value
                          : p == 'nvidia'
                              ? settings.nvidiaModel.value
                              : p == 'openrouter'
                                  ? settings.openRouterModel.value
                                  : p == 'custom'
                                      ? settings.customCloudModel.value
                                      : settings.kimiModel.value;
          if (p == 'custom' && model.isNotEmpty)
            model = '${settings.customCloudName.value}: $model';
        }
        final title = sid.isEmpty
            ? 'PrivateLM'
            : controller.sessions.firstWhereOrNull((s) => s.id == sid)?.title ??
                'Chat';
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title,
                style: GoogleFonts.inter(
                    fontWeight: FontWeight.w600,
                    fontSize: 17,
                    color: isDark ? Colors.white : Colors.black),
                overflow: TextOverflow.ellipsis),
            const SizedBox(height: 2),
            Row(children: [
              Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isLocal
                          ? (inf.isModelLoaded.value
                              ? const Color(0xFF34C759)
                              : const Color(0xFFFF9500))
                          : _appleBlue(context))),
              const SizedBox(width: 5),
              Flexible(
                  child: Text('$model · ${isLocal ? "Local" : "Cloud"}',
                      style: GoogleFonts.inter(
                          fontSize: 12,
                          color: Theme.of(context).hintColor,
                          fontWeight: FontWeight.w400),
                      overflow: TextOverflow.ellipsis)),
              if (isLocal && inf.isGpuAccelerated.value) ...[
                const SizedBox(width: 4),
                const Icon(Icons.bolt, size: 11, color: Color(0xFFFF9500)),
                Text('GPU',
                    style: GoogleFonts.inter(
                        fontSize: 10,
                        color: const Color(0xFFFF9500),
                        fontWeight: FontWeight.w600)),
              ],
            ]),
          ]),
        );
      }),
      actions: [
        Obx(() {
          final isLocal = Get.find<SettingsController>().inferenceMode.value == 'local';
          final inf = Get.find<InferenceService>();
          final localImage = Get.find<LocalImageService>();
          if (isLocal && (inf.isModelLoaded.value || localImage.isModelLoaded.value)) {
            return IconButton(
              tooltip: 'Unload Model',
              icon: const Icon(Icons.eject_outlined, size: 20, color: Color(0xFFFF3B30)),
              onPressed: () => Get.find<ModelController>().unloadModel(),
            );
          }
          return const SizedBox.shrink();
        }),
        IconButton(
            icon: Icon(Icons.history_rounded,
                size: 20, color: Theme.of(context).hintColor),
            onPressed: () => _showHistory(context)),
        IconButton(
            tooltip: 'New Chat',
            icon: Icon(Icons.edit_note,
                size: 22, color: _appleBlue(context)),
            onPressed: () => controller.createNewChat()),
      ],
    );
  }

  // ── Model Loading ──
  Widget _modelLoadingBar(BuildContext context, bool isDark) {
    return Obx(() {
      final inf = Get.find<InferenceService>();
      if (!inf.isLoadingModel.value) return const SizedBox.shrink();
      final pct = (inf.modelLoadProgress.value * 100).toStringAsFixed(0);
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
        color: isDark ? const Color(0xFF1C1C1E) : const Color(0xFFF2F2F7),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                    strokeWidth: 1.5, color: _appleBlue(context))),
            const SizedBox(width: 8),
            Text('Loading model… $pct%',
                style: GoogleFonts.inter(
                    fontSize: 12,
                    color: Theme.of(context).hintColor,
                    fontWeight: FontWeight.w500)),
          ]),
          const SizedBox(height: 8),
          ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                  value: inf.modelLoadProgress.value,
                  backgroundColor: _sep(context),
                  color: _appleBlue(context),
                  minHeight: 3)),
        ]),
      );
    });
  }

  // ── Context Bar ──
  Widget _contextBar(BuildContext context, bool isDark) {
    return Obx(() {
      final settings = Get.find<SettingsController>();
      final inf = Get.find<InferenceService>();
      final active = controller.currentSessionId.value.isNotEmpty &&
          controller.messages.isNotEmpty;
      if (!active || settings.inferenceMode.value != 'local')
        return const SizedBox.shrink();
      final total = inf.contextTokensTotal.value > 0
          ? inf.contextTokensTotal.value
          : settings.contextSize.value;
      final est =
          controller.messages.fold<int>(0, (s, m) => s + m.content.length);
      final used = (inf.contextTokensUsed.value > 0
              ? inf.contextTokensUsed.value
              : (est / 4).ceil())
          .clamp(0, total)
          .toInt();
      final pct = total == 0 ? 0.0 : (used / total).clamp(0.0, 1.0).toDouble();
      final warn = pct >= 0.75;
      final accent = warn ? const Color(0xFFFF9500) : _appleBlue(context);
      return Container(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        decoration: BoxDecoration(
            border:
                Border(bottom: BorderSide(color: _sep(context), width: 0.5))),
        child: Row(children: [
          Icon(Icons.memory_rounded, size: 14, color: accent),
          const SizedBox(width: 6),
          Text('${_fmtK(used)} / ${_fmtK(total)}',
              style: GoogleFonts.inter(
                  fontSize: 11,
                  color: Theme.of(context).hintColor,
                  fontWeight: FontWeight.w500)),
          const SizedBox(width: 8),
          Expanded(
              child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                      value: pct,
                      backgroundColor: _sep(context),
                      color: accent,
                      minHeight: 3))),
          const SizedBox(width: 8),
          Text('${(pct * 100).toStringAsFixed(0)}%',
              style: GoogleFonts.inter(
                  fontSize: 11, color: accent, fontWeight: FontWeight.w600)),
        ]),
      );
    });
  }

  // ── Empty State ──
  Widget _emptyState(BuildContext context, bool isDark) {
    final suggestions = [
      'Explain quantum computing simply',
      'Write a short poem about time',
      'Help me debug my code',
      'Summarize a complex topic'
    ];
    return Center(
        child: SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Image.asset(
          'assets/icons/appicon.png',
          width: 120,
          height: 120,
        ),
        const SizedBox(height: 20),
        Text('Hello.',
            style: GoogleFonts.inter(
                fontSize: 32,
                fontWeight: FontWeight.w700,
                color: isDark ? Colors.white : Colors.black)),
        const SizedBox(height: 6),
        Text('How can I help you today?',
            style: GoogleFonts.inter(
                fontSize: 16,
                color: Theme.of(context).hintColor,
                fontWeight: FontWeight.w400)),
        const SizedBox(height: 32),
        Obx(() {
          final settings = Get.find<SettingsController>();
          final models = Get.find<ModelController>();
          final isLocal = settings.inferenceMode.value == 'local';
          if (isLocal && models.downloadedCount == 0) {
            return Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFFFF9500).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(children: [
                const Icon(Icons.download_rounded,
                    color: Color(0xFFFF9500), size: 36),
                const SizedBox(height: 14),
                Text('No Local Models',
                    style: GoogleFonts.inter(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: isDark ? Colors.white : Colors.black)),
                const SizedBox(height: 6),
                Text(
                    'You need to download a model to use local inference on your device.',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.inter(
                        fontSize: 14, color: Theme.of(context).hintColor)),
                const SizedBox(height: 20),
                FilledButton.icon(
                  onPressed: () => Get.find<HomeController>().changeTab(1),
                  icon: const Icon(Icons.arrow_downward_rounded, size: 18),
                  label: const Text('Go to Models'),
                  style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFFF9500),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 24, vertical: 12),
                      textStyle: GoogleFonts.inter(
                          fontSize: 15, fontWeight: FontWeight.w600)),
                ),
              ]),
            );
          }
          return Wrap(
            spacing: 10,
            runSpacing: 10,
            alignment: WrapAlignment.center,
            children: suggestions
                .map((s) => _suggestionChip(context, s, isDark))
                .toList(),
          );
        }),
      ]),
    ));
  }

  Widget _suggestionChip(BuildContext context, String text, bool isDark) {
    return GestureDetector(
      onTap: () {
        controller.createNewChat();
        controller.textController.text = text;
        controller.inputText.value = text;
        controller.sendMessage();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        constraints: const BoxConstraints(maxWidth: 200),
        decoration: BoxDecoration(
          color: isDark
              ? Colors.white.withValues(alpha: 0.06)
              : Colors.black.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: _sep(context)),
        ),
        child: Text(text,
            style: GoogleFonts.inter(
                fontSize: 13,
                color: isDark
                    ? Colors.white.withValues(alpha: 0.8)
                    : Colors.black.withValues(alpha: 0.7),
                fontWeight: FontWeight.w400,
                height: 1.3)),
      ),
    );
  }

  // ── Streaming Bubble ──
  Widget _streamBubble(BuildContext context, String text, bool isDark) {
    final attType = controller.streamingAttachmentType.value;
    final isImageGen = controller.imageGenTotal.value > 0;
    final clean = _cleanStream(text).trimLeft();
    final parts = splitThoughtTags(clean);
    final answer = parts.answer.trimLeft();
    final hasText = parts.hasThought || _hasPrintable(answer);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.78),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: _aiBubble(context),
            borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(20),
                topRight: Radius.circular(20),
                bottomRight: Radius.circular(20),
                bottomLeft: Radius.circular(6)),
          ),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (isImageGen)
              _ImageGenIndicator(controller: controller, isDark: isDark)
            else if (!hasText)
              _typingHint(context, isDark, attachmentType: attType)
            else ...[
              if (parts.hasThought)
                ThoughtDisclosure(
                    thought: parts.thought,
                    isThinking: parts.isThinking,
                    styleSheet: _thoughtMd(context, isDark)),
              if (_hasPrintable(answer))
                Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Expanded(
                      child: MarkdownBody(
                          data: answer,
                          selectable: true,
                          styleSheet: _streamMd(context, isDark))),
                  _BlinkingCursor(color: Theme.of(context).hintColor),
                ]),
            ],
            if (hasText && !isImageGen)
              Obx(() {
                final inf = Get.find<InferenceService>();
                if (inf.tokensPerSecond.value <= 0)
                  return const SizedBox.shrink();
                return Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                        '${inf.tokensPerSecond.value.toStringAsFixed(1)} tok/s',
                        style: GoogleFonts.inter(
                            fontSize: 10,
                            color: _appleBlue(context),
                            fontWeight: FontWeight.w500)));
              }),
          ]),
        ),
      ),
    );
  }

  Widget _typingHint(BuildContext context, bool isDark,
      {String? attachmentType}) {
    final msg = attachmentType == 'image'
        ? 'Reading image…'
        : attachmentType == 'audio'
            ? 'Listening to audio…'
            : null;
    if (msg == null) return _TypingDots(isDark: isDark);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      _TypingDots(isDark: isDark),
      const SizedBox(width: 10),
      Flexible(
          child: Text(msg,
              style: GoogleFonts.inter(
                  fontSize: 12,
                  color: Theme.of(context).hintColor,
                  fontWeight: FontWeight.w400))),
    ]);
  }

  // ── Input Bar ──
  Widget _inputBar(BuildContext context, bool isDark) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      decoration: BoxDecoration(
        color: isDark ? Colors.black : Colors.white,
        border: Border(top: BorderSide(color: _sep(context), width: 0.5)),
      ),
      child: SafeArea(
          top: false,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            // Attachment preview
            Obx(() {
              final name = controller.selectedFileName.value;
              if (name == null) return const SizedBox.shrink();
              return Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                  child: AttachmentPreview(
                    fileName: name,
                    fileType: controller.selectedFileType.value,
                    fileSize: controller.selectedFileSize.value > 0
                        ? controller.selectedFileSize.value
                        : null,
                    imagePath: controller.selectedImagePath.value,
                    imageBase64: controller.selectedImageBase64.value,
                    onRemove: () {
                      controller.clearImage();
                      controller.clearFile();
                    },
                  ));
            }),
            // STT listening indicator
            Obx(() {
              if (!controller.isListening.value) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF3B30).withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                        color: const Color(0xFFFF3B30).withValues(alpha: 0.3)),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const _PulsingDot(),
                    const SizedBox(width: 8),
                    Text('Listening… tap mic to stop',
                        style: GoogleFonts.inter(
                            fontSize: 12,
                            color: const Color(0xFFFF3B30),
                            fontWeight: FontWeight.w500)),
                  ]),
                ),
              );
            }),
            Obx(() {
              final settings = Get.find<SettingsController>();
              final localImage = Get.find<LocalImageService>();
              if (settings.inferenceMode.value != 'local' ||
                  !localImage.isModelLoaded.value) {
                return const SizedBox.shrink();
              }
              final steps = settings.imageSteps.value;
              final size = settings.imageGenSize.value;
              final sizeLabel = size == 0 ? 'Auto' : '${size}px';
              final backend = localImage.currentBackend.value;
              final backendLabel = backend == Backend.cpu
                  ? 'CPU'
                  : (backend == Backend.metal ? 'APPLE NPU' : backend.displayName.split(' ').first.toUpperCase());
              final accent = backend == Backend.cpu
                  ? const Color(0xFFFF9500)
                  : const Color(0xFF34C759);
              return Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: accent.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: accent.withValues(alpha: 0.24),
                            width: 0.5,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.auto_awesome_rounded,
                                size: 13, color: accent),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                'Image gen · $steps ${steps == 1 ? "step" : "steps"} · $sizeLabel · $backendLabel',
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.inter(
                                  fontSize: 11,
                                  color: accent,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      height: 30,
                      decoration: BoxDecoration(
                        color: isDark
                            ? Colors.white.withValues(alpha: 0.06)
                            : Colors.black.withValues(alpha: 0.04),
                        borderRadius: BorderRadius.circular(15),
                        border: Border.all(color: _sep(context), width: 0.5),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                      children: [
                          _StepButton(
                            icon: Icons.remove_rounded,
                            enabled: steps > 1,
                            onTap: () => settings.setImageSteps(steps - 1),
                          ),
                        Text(
                            steps.toString(),
                          style: GoogleFonts.inter(
                              fontSize: 12,
                              color: isDark ? Colors.white : Colors.black,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                          _StepButton(
                            icon: Icons.add_rounded,
                            enabled: steps < 20,
                            onTap: () => settings.setImageSteps(steps + 1),
                          ),
                      ],
                      ),
                    ),
                  ],
                ),
              );
            }),
            Obx(() {
              if (controller.lastBatchImagesBase64.isEmpty) return const SizedBox.shrink();
              return Container(
                margin: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF34C759).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFF34C759).withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.check_circle_rounded, size: 18, color: Color(0xFF34C759)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Batch complete! (${controller.lastBatchImagesBase64.length} images)',
                        style: GoogleFonts.inter(fontWeight: FontWeight.w600, fontSize: 13, color: isDark ? Colors.white : Colors.black),
                      ),
                    ),
                    TextButton(
                      onPressed: () => controller.lastBatchImagesBase64.clear(),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        minimumSize: const Size(0, 32),
                        foregroundColor: Theme.of(context).hintColor,
                      ),
                      child: const Text('Dismiss'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: () => controller.downloadLastBatch(),
                      style: FilledButton.styleFrom(
                        backgroundColor: const Color(0xFF34C759),
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        minimumSize: const Size(0, 32),
                      ),
                      icon: const Icon(Icons.download_rounded, size: 16),
                      label: const Text('Save All'),
                    ),
                  ],
                ),
              );
            }),
            Obx(() {
              if (controller.batchPrompts.isEmpty) return const SizedBox.shrink();
              return Container(
                margin: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: _appleBlue(context).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: _appleBlue(context).withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.layers_rounded, size: 18, color: _appleBlue(context)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${controller.batchPrompts.length}/20 batch prompts',
                        style: GoogleFonts.inter(fontWeight: FontWeight.w600, fontSize: 13, color: isDark ? Colors.white : Colors.black),
                      ),
                    ),
                    TextButton(
                      onPressed: () => controller.batchPrompts.clear(),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        minimumSize: const Size(0, 32),
                        foregroundColor: Colors.redAccent,
                      ),
                      child: const Text('Clear'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: controller.isLoading.value ? null : () => controller.generateBatch(),
                      style: FilledButton.styleFrom(
                        backgroundColor: _appleBlue(context),
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        minimumSize: const Size(0, 32),
                      ),
                      child: const Text('Start Batch'),
                    ),
                  ],
                ),
              );
            }),
            Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
              // Attach button (image + file) — shown for cloud & local vision
              Obx(() {
                final s = Get.find<SettingsController>();
                final inf = Get.find<InferenceService>();
                final isCloud = s.inferenceMode.value == 'cloud';
                final isLocalVision = s.inferenceMode.value == 'local' &&
                    inf.loadedModelRuntime.value == 'litert' &&
                    inf.isVisionLoaded.value;
                if (!isCloud && !isLocalVision)
                  return const SizedBox.shrink();
                return _AttachButton(
                  isDark: isDark,
                  isCloud: isCloud,
                  onImage: controller.pickImage,
                  onFile: controller.pickFile,
                  context: context,
                );
              }),
              // Text field
              Expanded(
                  child: Container(
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF1C1C1E)
                      : const Color(0xFFF2F2F7),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: TextField(
                  controller: controller.textController,
                  onChanged: (v) => controller.inputText.value = v,
                  maxLines: 5,
                  minLines: 1,
                  style: GoogleFonts.inter(
                      fontSize: 15,
                      color: isDark ? Colors.white : Colors.black),
                  decoration: InputDecoration(
                    hintText: 'Message…',
                    hintStyle: GoogleFonts.inter(
                        fontSize: 15, color: Theme.of(context).hintColor),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 18, vertical: 10),
                    isDense: true,
                  ),
                  onSubmitted: (_) => controller.sendMessage(),
                ),
              )),
              const SizedBox(width: 6),
              // Batch add button
              Obx(() {
                final settings = Get.find<SettingsController>();
                final localImage = Get.find<LocalImageService>();
                if (settings.inferenceMode.value == 'local' && 
                    localImage.isModelLoaded.value && 
                    localImage.currentBackend.value == Backend.metal) {
                  return Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: GestureDetector(
                      onLongPress: () {
                        // Testing mode: Populate batch with 15 fresh alternative prompts
                        final testPrompts = [
                          "Portrait of a goth girl with dark makeup, realistic photography, 8k",
                          "Realistic photo of an elf girl in a forest, cinematic lighting",
                          "A fluffy orange cat sleeping on a sunny couch, photorealistic",
                          "A handsome man in a sharp suit, realistic portrait, studio lighting",
                          "A futuristic city street at night, realistic photography",
                          "A beautiful young woman with freckles, natural sunlight",
                          "A majestic lion resting in the savanna, highly detailed",
                          "An old man with a weathered face, realistic portrait, high detail",
                          "A delicious looking cup of coffee on a wooden table, macro photography",
                          "A medieval knight holding a sword, realistic cinematic lighting",
                          "A golden retriever playing fetch, sharp focus, photography",
                          "A realistic cyberpunk character with neon reflections",
                          "A vintage muscle car driving down a desert highway, photorealistic",
                          "A serene mountain lake at sunrise, realistic landscape photography",
                          "A close-up of a beautiful eye with detailed iris, macro shot"
                        ];
                        // Shuffle them before adding
                        testPrompts.shuffle();
                        controller.batchPrompts.clear();
                        controller.batchPrompts.addAll(testPrompts);
                        Get.snackbar('Test Mode', 'Added 15 test prompts to the batch.', backgroundColor: const Color(0xFF34C759).withValues(alpha: 0.9), colorText: Colors.white);
                      },
                      onTap: () async {
                        final text = controller.textController.text.trim();
                        if (text.isEmpty) return;
                        if (controller.batchPrompts.length >= 20) {
                          Get.snackbar('Batch Limit', 'You can only add up to 20 prompts per batch.');
                          return;
                        }
                        if (!controller.batchModeAccepted.value) {
                          final accepted = await Get.dialog<bool>(
                            AlertDialog(
                              backgroundColor: isDark ? const Color(0xFF1C1C1E) : Colors.white,
                              title: Text('Batch Generation', style: GoogleFonts.inter(fontWeight: FontWeight.w600, color: isDark ? Colors.white : Colors.black)),
                              content: Text('Generating multiple images back-to-back is demanding. Your device may become warm and use more battery.', style: GoogleFonts.inter(color: isDark ? Colors.white70 : Colors.black87)),
                              actions: [
                                TextButton(onPressed: () => Get.back(result: false), child: const Text('Cancel')),
                                FilledButton(
                                  onPressed: () => Get.back(result: true), 
                                  style: FilledButton.styleFrom(backgroundColor: _appleBlue(context)),
                                  child: const Text('Continue')
                                ),
                              ],
                            ),
                          );
                          if (accepted != true) return;
                          controller.acceptBatchMode();
                        }
                        controller.batchPrompts.add(text);
                        controller.textController.clear();
                        controller.inputText.value = '';
                      },
                      child: Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: _appleBlue(context).withValues(alpha: 0.15),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(Icons.add_rounded, size: 22, color: _appleBlue(context)),
                      ),
                    ),
                  );
                }
                return const SizedBox.shrink();
              }),
              // Unified mic / send / stop button
              Obx(() {
                final loading = controller.isLoading.value;
                final listening = controller.isListening.value;
                final hasContent = controller.inputText.value.isNotEmpty ||
                    controller.selectedFileName.value != null ||
                    controller.selectedImagePath.value != null;

                // Determine state
                final Color bgColor;
                final IconData iconData;
                final VoidCallback? onTap;

                if (loading) {
                  // AI generating → red stop
                  bgColor = const Color(0xFFFF3B30);
                  iconData = Icons.stop_rounded;
                  onTap = controller.stopGenerating;
                } else if (listening) {
                  // STT active → red stop
                  bgColor = const Color(0xFFFF3B30);
                  iconData = Icons.stop_rounded;
                  onTap = controller.toggleListening;
                } else if (hasContent) {
                  // Has text or attachment → blue send
                  bgColor = _appleBlue(context);
                  iconData = Icons.arrow_upward_rounded;
                  onTap = controller.sendMessage;
                } else {
                  // Empty → grey mic
                  bgColor = isDark
                      ? Colors.white.withValues(alpha: 0.08)
                      : Colors.black.withValues(alpha: 0.06);
                  iconData = Icons.mic_none_rounded;
                  onTap = controller.toggleListening;
                }

                return GestureDetector(
                  onTap: onTap,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeInOut,
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                        color: bgColor, shape: BoxShape.circle),
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      transitionBuilder: (child, anim) => ScaleTransition(
                          scale: anim, child: child),
                      child: Icon(iconData,
                          key: ValueKey(iconData),
                          color: (loading || listening || hasContent)
                              ? Colors.white
                              : Theme.of(context).hintColor,
                          size: iconData == Icons.mic_none_rounded ? 18 : 20),
                    ),
                  ),
                );
              }),
            ]),
          ])),
    );
  }

  // ── Chat History ──
  void _showHistory(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showModalBottomSheet(
      context: context,
      backgroundColor: isDark ? const Color(0xFF1C1C1E) : Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
      builder: (_) => Container(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.6),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
              margin: const EdgeInsets.only(top: 8),
              width: 36,
              height: 5,
              decoration: BoxDecoration(
                  color: isDark
                      ? Colors.white.withValues(alpha: 0.2)
                      : Colors.black.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(3))),
          Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Conversations',
                  style: GoogleFonts.inter(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: isDark ? Colors.white : Colors.black))),
          Divider(height: 0.5, color: _sep(context)),
          Flexible(child: Obx(() {
            if (controller.sessions.isEmpty)
              return Padding(
                  padding: const EdgeInsets.all(32),
                  child: Text('No conversations yet',
                      style: GoogleFonts.inter(
                          color: Theme.of(context).hintColor)));
            return ListView.separated(
              shrinkWrap: true,
              itemCount: controller.sessions.length,
              separatorBuilder: (_, __) =>
                  Divider(height: 0.5, indent: 56, color: _sep(context)),
              itemBuilder: (ctx, i) {
                final s = controller.sessions[i];
                final active = controller.currentSessionId.value == s.id;
                return ListTile(
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                  leading: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                          color: active
                              ? _appleBlue(ctx).withValues(alpha: 0.12)
                              : (isDark
                                  ? Colors.white.withValues(alpha: 0.06)
                                  : Colors.black.withValues(alpha: 0.04)),
                          borderRadius: BorderRadius.circular(10)),
                      child: Icon(
                          active
                              ? Icons.chat_bubble_rounded
                              : Icons.chat_bubble_outline_rounded,
                          size: 16,
                          color: active
                              ? _appleBlue(ctx)
                              : Theme.of(ctx).hintColor)),
                  title: Text(s.title,
                      style: GoogleFonts.inter(
                          fontSize: 15,
                          fontWeight:
                              active ? FontWeight.w600 : FontWeight.w400,
                          color: isDark ? Colors.white : Colors.black),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  subtitle: Text(_fmtDate(s.updatedAt),
                      style: GoogleFonts.inter(
                          fontSize: 12, color: Theme.of(ctx).hintColor)),
                  trailing: IconButton(
                      icon: Icon(Icons.delete_outline_rounded,
                          size: 18, color: Theme.of(ctx).hintColor),
                      onPressed: () => controller.deleteChat(s.id)),
                  onTap: () {
                    controller.openChat(s.id);
                    Navigator.pop(ctx);
                  },
                );
              },
            );
          })),
        ]),
      ),
    );
  }

  // ── Markdown styles ──
  MarkdownStyleSheet _streamMd(BuildContext c, bool isDark) {
    final clr = Theme.of(c).colorScheme.onSurface;
    final base = GoogleFonts.inter(fontSize: 15, color: clr, height: 1.5);
    final codeBg = isDark ? const Color(0xFF2C2C2E) : const Color(0xFFE5E5EA);
    return MarkdownStyleSheet.fromTheme(Theme.of(c)).copyWith(
        p: base,
        strong: base.copyWith(fontWeight: FontWeight.w600),
        em: base.copyWith(fontStyle: FontStyle.italic),
        listBullet: base,
        code: GoogleFonts.firaCode(
            fontSize: 13, color: clr, backgroundColor: codeBg),
        codeblockDecoration: BoxDecoration(
            color: codeBg, borderRadius: BorderRadius.circular(12)));
  }

  MarkdownStyleSheet _thoughtMd(BuildContext c, bool isDark) {
    final muted = Theme.of(c).hintColor;
    final base = GoogleFonts.inter(fontSize: 13, color: muted, height: 1.4);
    final codeBg = isDark ? const Color(0xFF2C2C2E) : const Color(0xFFE5E5EA);
    return MarkdownStyleSheet.fromTheme(Theme.of(c)).copyWith(
        p: base,
        strong: base.copyWith(fontWeight: FontWeight.w600),
        em: base.copyWith(fontStyle: FontStyle.italic),
        listBullet: base,
        code: GoogleFonts.firaCode(
            fontSize: 11, color: muted, backgroundColor: codeBg),
        codeblockDecoration: BoxDecoration(
            color: codeBg, borderRadius: BorderRadius.circular(10)));
  }

  // ── Helpers ──
  String _cleanStream(String t) => t
      .replaceAll(
          RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F]'), '')
      .replaceAll(RegExp(r'[\u200B-\u200D\uFEFF]'), '')
      .replaceAll('\uFFFD', '')
      .replaceAll('<|endoftext|>', '')
      .replaceAll('<|im_end|>', '')
      .replaceAll('<|end|>', '');

  bool _hasPrintable(String t) {
    for (final r in t.runes) {
      if (r > 32 &&
          r != 0x7F &&
          r != 0x200B &&
          r != 0x200C &&
          r != 0x200D &&
          r != 0xFEFF &&
          r != 0xFFFD) return true;
    }
    return false;
  }

  String _fmtDate(DateTime d) {
    final diff = DateTime.now().difference(d);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${d.day}/${d.month}/${d.year}';
  }

  String _fmtK(int v) => v >= 1000000
      ? '${(v / 1000000).toStringAsFixed(1)}M'
      : v >= 1000
          ? '${(v / 1000).toStringAsFixed(1)}K'
          : v.toString();
}

// ── Attach Button ──
class _AttachButton extends StatelessWidget {
  final bool isDark;
  final bool isCloud;
  final VoidCallback onImage;
  final VoidCallback onFile;
  final BuildContext context;

  const _AttachButton({
    required this.isDark,
    required this.isCloud,
    required this.onImage,
    required this.onFile,
    required this.context,
  });

  @override
  Widget build(BuildContext buildContext) {
    return Padding(
      padding: const EdgeInsets.only(right: 2),
      child: GestureDetector(
        onTap: () => _showSheet(buildContext),
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: isDark
                ? Colors.white.withValues(alpha: 0.08)
                : Colors.black.withValues(alpha: 0.06),
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.add_rounded,
              color: Theme.of(buildContext).hintColor, size: 20),
        ),
      ),
    );
  }

  void _showSheet(BuildContext ctx) {
    final isDarkSheet = Theme.of(ctx).brightness == Brightness.dark;
    showModalBottomSheet(
      context: ctx,
      backgroundColor:
          isDarkSheet ? const Color(0xFF1C1C1E) : Colors.white,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              // Handle
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                    color: isDarkSheet
                        ? Colors.white.withValues(alpha: 0.2)
                        : Colors.black.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(2)),
              ),
              const SizedBox(height: 16),
              Text('Add Attachment',
                  style: GoogleFonts.inter(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: isDarkSheet ? Colors.white : Colors.black)),
              if (isCloud)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('Cloud models support images & text files',
                      style: GoogleFonts.inter(
                          fontSize: 12,
                          color: isDarkSheet
                              ? Colors.white54
                              : Colors.black45)),
                ),
              const SizedBox(height: 20),
              Row(children: [
                _SheetTile(
                  icon: Icons.photo_library_rounded,
                  color: const Color(0xFF30D158),
                  label: 'Photo',
                  sub: 'From gallery',
                  isDark: isDarkSheet,
                  onTap: () {
                    Navigator.pop(_);
                    onImage();
                  },
                ),
                const SizedBox(width: 12),
                _SheetTile(
                  icon: Icons.attach_file_rounded,
                  color: const Color(0xFF0A84FF),
                  label: 'File',
                  sub: isCloud
                      ? 'PDF, DOCX, text…'
                      : 'PDF, DOCX, text…',
                  isDark: isDarkSheet,
                  onTap: () {
                    Navigator.pop(_);
                    onFile();
                  },
                ),
              ]),
            ]),
          ),
        );
      },
    );
  }
}

class _SheetTile extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final String sub;
  final bool isDark;
  final VoidCallback onTap;

  const _SheetTile({
    required this.icon,
    required this.color,
    required this.label,
    required this.sub,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
          decoration: BoxDecoration(
            color: isDark
                ? Colors.white.withValues(alpha: 0.06)
                : Colors.black.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.08)
                  : Colors.black.withValues(alpha: 0.08),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: color, size: 22),
              ),
              const SizedBox(height: 10),
              Text(label,
                  style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: isDark ? Colors.white : Colors.black)),
              const SizedBox(height: 2),
              Text(sub,
                  style: GoogleFonts.inter(
                      fontSize: 11,
                      color: isDark ? Colors.white54 : Colors.black45)),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Pulsing Dot (STT indicator) ──
class _PulsingDot extends StatefulWidget {
  const _PulsingDot();

  @override
  State<_PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<_PulsingDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _c;
  late Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900))
      ..repeat(reverse: true);
    _scale = Tween<double>(begin: 0.7, end: 1.3)
        .animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: _scale,
      child: Container(
        width: 8,
        height: 8,
        decoration: const BoxDecoration(
            color: Color(0xFFFF3B30), shape: BoxShape.circle),
      ),
    );
  }
}

class _StepButton extends StatelessWidget {
  final IconData icon;
  final bool enabled;
  final VoidCallback onTap;

  const _StepButton({
    required this.icon,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = enabled
        ? _appleBlue(context)
        : Theme.of(context).hintColor.withValues(alpha: 0.35);
    return GestureDetector(
      onTap: enabled ? onTap : null,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 30,
        height: 30,
        child: Icon(icon, size: 16, color: color),
      ),
    );
  }
}

// ── Image Generation Indicator ──
class _ImageGenIndicator extends StatefulWidget {
  final ChatController controller;
  final bool isDark;
  const _ImageGenIndicator({required this.controller, required this.isDark});

  @override
  State<_ImageGenIndicator> createState() => _ImageGenIndicatorState();
}

class _ImageGenIndicatorState extends State<_ImageGenIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _c;
  late Timer _timer;
  int _elapsedSeconds = 0;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      final start = widget.controller.imageGenStartTime.value;
      if (start != null) {
        setState(() {
          _elapsedSeconds = DateTime.now().difference(start).inSeconds;
        });
      }
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    _c.dispose();
    super.dispose();
  }

  String _fmtEta(int seconds) {
    if (seconds <= 0) return '';
    if (seconds < 60) return '~$seconds s remaining';
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return s > 0 ? '~$m m $s s remaining' : '~$m m remaining';
  }

  String _fmtElapsed(int seconds) {
    if (seconds < 60) return '${seconds}s';
    final m = seconds ~/ 60;
    final s = seconds % 60;
    return s > 0 ? '${m}m ${s}s' : '${m}m';
  }

  Widget _backendChip(BuildContext context) {
    final localImage = Get.find<LocalImageService>();
    final backend = localImage.currentBackend.value;
    final isCpu = backend == Backend.cpu;
    final color = isCpu
        ? const Color(0xFFFF9500) // Orange for CPU
        : const Color(0xFF34C759); // Green for GPU
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.3), width: 0.5),
      ),
      child: Text(
        isCpu ? 'CPU · Slow' : (backend == Backend.metal ? 'APPLE NPU' : backend.displayName.split(' ').first.toUpperCase()),
        style: GoogleFonts.inter(
          fontSize: 9,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (_, __) {
        final dots = Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            final t = ((_c.value - i * 0.18) % 1.0).clamp(0.0, 1.0);
            final pulse = math.sin(t * math.pi).clamp(0.0, 1.0);
            return Padding(
              padding: EdgeInsets.only(right: i < 2 ? 5 : 0),
              child: Opacity(
                opacity: 0.25 + 0.75 * pulse,
                child: Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.isDark
                        ? Colors.white.withValues(alpha: 0.6)
                        : Colors.black.withValues(alpha: 0.35),
                  ),
                ),
              ),
            );
          }),
        );

        return Obx(() {
          final step = widget.controller.imageGenStep.value;
          final total = widget.controller.imageGenTotal.value;
          final eta = widget.controller.imageGenEstimatedSecs.value;
          final decoding = widget.controller.imageGenDecoding.value;
          final hasProgress = total > 0;
          final pct = hasProgress ? (step / total).clamp(0.0, 1.0) : 0.0;
          final isDone = decoding || (hasProgress && step >= total);

          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              dots,
              const SizedBox(height: 10),
              Text(
                isDone ? 'Decoding image' : 'Generating image',
                style: GoogleFonts.inter(
                  fontSize: 13,
                  color: Theme.of(context).hintColor,
                  fontWeight: FontWeight.w400,
                ),
              ),
              if (hasProgress) ...[
                const SizedBox(height: 10),
                // Progress bar (pulse at 100% during decode)
                Container(
                  width: 160,
                  height: 4,
                  decoration: BoxDecoration(
                    color: (widget.isDark ? Colors.white : Colors.black)
                        .withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(2),
                  ),
                  child: FractionallySizedBox(
                    alignment: Alignment.centerLeft,
                    widthFactor: isDone ? 1.0 : pct,
                    child: Container(
                      decoration: BoxDecoration(
                        color: _appleBlue(context),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                // Percentage + steps / decoding message
                Text(
                  isDone
                      ? 'VAE decode in progress…'
                      : '${(pct * 100).toStringAsFixed(0)}% · Step $step of $total',
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    color: Theme.of(context).hintColor.withValues(alpha: 0.6),
                    fontWeight: FontWeight.w500,
                  ),
                ),
                // Backend badge
                const SizedBox(height: 5),
                _backendChip(context),
                // Elapsed time
                const SizedBox(height: 3),
                Text(
                  'Elapsed: ${_fmtElapsed(_elapsedSeconds)}',
                  style: GoogleFonts.inter(
                    fontSize: 10,
                    color: Theme.of(context).hintColor.withValues(alpha: 0.45),
                  ),
                ),
                // ETA (only if we have a real estimate and not done)
                if (eta > 0 && step >= 2 && !isDone) ...[
                  const SizedBox(height: 3),
                  Text(
                    _fmtEta(eta),
                    style: GoogleFonts.inter(
                      fontSize: 10,
                      color: Theme.of(context).hintColor.withValues(alpha: 0.45),
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                // Cancel button
                GestureDetector(
                  onTap: widget.controller.stopGenerating,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFF3B30).withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.stop_rounded,
                            size: 12, color: const Color(0xFFFF3B30)),
                        const SizedBox(width: 4),
                        Text(
                          'Cancel',
                          style: GoogleFonts.inter(
                            fontSize: 11,
                            color: const Color(0xFFFF3B30),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          );
        });
      },
    );
  }
}

// ── Typing Dots ──
class _TypingDots extends StatefulWidget {
  final bool isDark;
  const _TypingDots({required this.isDark});
  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late AnimationController _c;
  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1400))
      ..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
        animation: _c,
        builder: (_, __) {
          return Row(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(3, (i) {
                final t = ((_c.value - i * 0.2) % 1.0).clamp(0.0, 1.0);
                final pulse = math.sin(t * math.pi).clamp(0.0, 1.0);
                return Padding(
                    padding: EdgeInsets.only(right: i < 2 ? 5 : 0),
                    child: Opacity(
                        opacity: 0.25 + 0.75 * pulse,
                        child: Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: widget.isDark
                                    ? Colors.white.withValues(alpha: 0.6)
                                    : Colors.black.withValues(alpha: 0.35)))));
              }));
        });
  }
}

// ── Blinking Cursor ──
class _BlinkingCursor extends StatefulWidget {
  final Color color;
  const _BlinkingCursor({required this.color});
  @override
  State<_BlinkingCursor> createState() => _BlinkingCursorState();
}

class _BlinkingCursorState extends State<_BlinkingCursor>
    with SingleTickerProviderStateMixin {
  late AnimationController _c;
  @override
  void initState() {
    super.initState();
    _c = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 600))
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
        animation: _c,
        builder: (_, __) => Opacity(
            opacity: _c.value,
            child: Container(
                width: 2,
                height: 16,
                margin: const EdgeInsets.only(left: 2, bottom: 2),
                decoration: BoxDecoration(
                    color: widget.color,
                    borderRadius: BorderRadius.circular(1)))));
  }
}
