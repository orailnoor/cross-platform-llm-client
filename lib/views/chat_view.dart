import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import '../controllers/chat_controller.dart';
import '../controllers/settings_controller.dart';
import '../core/colors.dart';
import '../services/inference_service.dart';
import '../utils/thought_parser.dart';
import '../widgets/attachment_preview.dart';
import '../widgets/chat_bubble.dart';
import '../widgets/thought_disclosure.dart';

class ChatView extends GetView<ChatController> {
  const ChatView({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Obx(() {
          final sessionId = controller.currentSessionId.value;
          final settings = Get.find<SettingsController>();
          final inference = Get.find<InferenceService>();
          final isLocal = settings.inferenceMode.value == 'local';

          // Determine the active model name
          String modelLabel;
          if (isLocal) {
            if (inference.isModelLoaded.value) {
              // Shorten model name (strip .gguf and path)
              final name = inference.loadedModelName.value
                  .replaceAll('.gguf', '')
                  .replaceAll('.GGUF', '');
              modelLabel =
                  name.length > 24 ? '${name.substring(0, 24)}…' : name;
            } else {
              modelLabel = 'No model loaded';
            }
          } else {
            final provider = settings.cloudProvider.value;
            final model = provider == 'openai'
                ? settings.openaiModel.value
                : provider == 'anthropic'
                    ? settings.anthropicModel.value
                    : provider == 'google'
                        ? settings.googleModel.value
                        : provider == 'stability'
                            ? settings.stabilityModel.value
                            : provider == 'nvidia'
                                ? settings.nvidiaModel.value
                                : provider == 'openrouter'
                                    ? settings.openRouterModel.value
                                    : provider == 'custom'
                                        ? settings.customCloudModel.value
                                        : settings.kimiModel.value;
            modelLabel = provider == 'custom' && model.isNotEmpty
                ? '${settings.customCloudName.value}: $model'
                : model;
          }

          return Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  sessionId.isEmpty
                      ? 'AI Chat'
                      : controller.sessions
                              .firstWhereOrNull((s) => s.id == sessionId)
                              ?.title ??
                          'Chat',
                  style: GoogleFonts.inter(
                      fontWeight: FontWeight.w600, fontSize: 18),
                  overflow: TextOverflow.ellipsis,
                ),
                // Model subtitle line
                Row(
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isLocal
                            ? (inference.isModelLoaded.value
                                ? AppColors.success
                                : AppColors.warning)
                            : AppColors.info,
                      ),
                    ),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        '$modelLabel · ${isLocal ? 'Local' : 'Cloud'}',
                        style: GoogleFonts.inter(
                          fontSize: 13,
                          color: Theme.of(context).hintColor,
                          fontWeight: FontWeight.w400,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (isLocal && inference.isGpuAccelerated.value) ...[
                      const SizedBox(width: 4),
                      const Icon(Icons.bolt,
                          size: 12, color: AppColors.warning),
                      Text(
                        'GPU',
                        style: GoogleFonts.inter(
                          fontSize: 10,
                          color: AppColors.warning,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          );
        }),
        actions: [
          IconButton(
            icon: const Icon(Icons.history, size: 22),
            onPressed: () => _showChatHistory(context),
          ),
          IconButton(
            icon: const Icon(Icons.add, size: 22),
            onPressed: () => controller.createNewChat(),
          ),
        ],
      ),
      body: Column(
        children: [
          // ── Model Loading Bar ──────────────────
          _buildModelLoadingBar(context),
          _buildContextUsageBar(context),

          // Messages + streaming
          Expanded(
            child: Obx(() {
              if (controller.currentSessionId.value.isEmpty) {
                return _buildEmptyState(context);
              }

              final isStreaming = controller.isStreaming.value;
              final streamText = controller.streamingResponse.value;
              final msgCount = controller.messages.length;

              return ListView.builder(
                controller: controller.scrollController,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                itemCount: msgCount + (isStreaming ? 1 : 0),
                itemBuilder: (context, index) {
                  // Streaming bubble at the end
                  if (index == msgCount && isStreaming) {
                    return _buildStreamingBubble(context, streamText);
                  }
                  return ChatBubble(message: controller.messages[index]);
                },
              );
            }),
          ),

          // Input bar
          _buildInputBar(context),
        ],
      ),
    );
  }

  /// Real-time streaming bubble — shows AI response as it generates token-by-token.
  Widget _buildStreamingBubble(BuildContext context, String text) {
    final visibleText = _cleanStreamingText(text).trimLeft();
    final thoughtParts = splitThoughtTags(visibleText);
    final answerText = thoughtParts.answer.trimLeft();
    final hasVisibleText =
        thoughtParts.hasThought || _hasPrintableStreamingText(answerText);

    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.82,
        ),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).brightness == Brightness.dark
              ? AppColors.aiBubble
              : const Color(0xFFF0F0F5),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(16),
            topRight: Radius.circular(16),
            bottomRight: Radius.circular(16),
            bottomLeft: Radius.circular(4),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            !hasVisibleText
                ? _buildTypingIndicator(context)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (thoughtParts.hasThought)
                        ThoughtDisclosure(
                          thought: thoughtParts.thought,
                          isThinking: thoughtParts.isThinking,
                          styleSheet: _thoughtMarkdownStyle(context),
                        ),
                      if (_hasPrintableStreamingText(answerText))
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Expanded(
                              child: MarkdownBody(
                                data: answerText,
                                selectable: true,
                                styleSheet: _streamingMarkdownStyle(context),
                              ),
                            ),
                            _BlinkingCursor(
                              color: Theme.of(context).hintColor,
                            ),
                          ],
                        ),
                    ],
                  ),
            if (hasVisibleText)
              Obx(() {
                final inference = Get.find<InferenceService>();
                if (inference.tokensPerSecond.value > 0) {
                  return Padding(
                    padding: const EdgeInsets.only(top: 8.0),
                    child: Text(
                      '⚡ ${inference.tokensPerSecond.value.toStringAsFixed(1)} tok/s',
                      style: GoogleFonts.firaCode(
                        fontSize: 10,
                        color: AppColors.primary,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  );
                }
                return const SizedBox.shrink();
              }),
          ],
        ),
      ),
    );
  }

  /// Animated typing dots — shown only during prefill (before first token).
  Widget _buildTypingIndicator(BuildContext context) {
    return const _TypingDots();
  }

  MarkdownStyleSheet _streamingMarkdownStyle(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurface;
    final base = GoogleFonts.inter(fontSize: 14, color: color, height: 1.4);
    return MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
      p: base,
      strong: base.copyWith(fontWeight: FontWeight.w700),
      em: base.copyWith(fontStyle: FontStyle.italic),
      listBullet: base,
      code: GoogleFonts.firaCode(
        fontSize: 12,
        color: color,
        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      ),
      codeblockDecoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
    );
  }

  MarkdownStyleSheet _thoughtMarkdownStyle(BuildContext context) {
    final muted = Theme.of(context).hintColor;
    final base = GoogleFonts.inter(fontSize: 12, color: muted, height: 1.35);
    return MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
      p: base,
      strong: base.copyWith(fontWeight: FontWeight.w700),
      em: base.copyWith(fontStyle: FontStyle.italic),
      listBullet: base,
      code: GoogleFonts.firaCode(
        fontSize: 11,
        color: muted,
        backgroundColor: Theme.of(context).colorScheme.surface,
      ),
      codeblockDecoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
      ),
    );
  }

  String _cleanStreamingText(String text) {
    return text
        .replaceAll(
            RegExp(r'[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F]'),
            '')
        .replaceAll(RegExp(r'[\u200B-\u200D\uFEFF]'), '')
        .replaceAll('\uFFFD', '')
        .replaceAll('<|endoftext|>', '')
        .replaceAll('<|im_end|>', '')
        .replaceAll('<|end|>', '');
  }

  bool _hasPrintableStreamingText(String text) {
    for (final rune in text.runes) {
      if (rune > 32 &&
          rune != 0x7F &&
          rune != 0x200B &&
          rune != 0x200C &&
          rune != 0x200D &&
          rune != 0xFEFF &&
          rune != 0xFFFD) {
        return true;
      }
    }
    return false;
  }

  /// Model loading progress bar.
  Widget _buildModelLoadingBar(BuildContext context) {
    return Obx(() {
      final inference = Get.find<InferenceService>();
      if (!inference.isLoadingModel.value) return const SizedBox.shrink();

      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        color: Theme.of(context).colorScheme.surface,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: AppColors.secondary,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'Loading model… ${(inference.modelLoadProgress.value * 100).toStringAsFixed(0)}%',
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    color: AppColors.secondary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: inference.modelLoadProgress.value,
                backgroundColor:
                    Theme.of(context).colorScheme.surfaceContainerHighest,
                color: AppColors.secondary,
                minHeight: 3,
              ),
            ),
          ],
        ),
      );
    });
  }

  Widget _buildContextUsageBar(BuildContext context) {
    return Obx(() {
      final settings = Get.find<SettingsController>();
      final inference = Get.find<InferenceService>();
      final chatStarted = controller.currentSessionId.value.isNotEmpty &&
          controller.messages.isNotEmpty;
      final isLocal = settings.inferenceMode.value == 'local';

      if (!chatStarted || !isLocal) {
        return const SizedBox.shrink();
      }

      final total = inference.contextTokensTotal.value > 0
          ? inference.contextTokensTotal.value
          : settings.contextSize.value;
      final estimatedUsed = _estimateVisibleChatTokens();
      final used = (inference.contextTokensUsed.value > 0
              ? inference.contextTokensUsed.value
              : estimatedUsed)
          .clamp(0, total)
          .toInt();
      final available = (total - used).clamp(0, total).toInt();
      final progress =
          total == 0 ? 0.0 : (used / total).clamp(0.0, 1.0).toDouble();
      final percent = (progress * 100).toStringAsFixed(0);
      final isNearLimit = progress >= 0.75;
      final accent = isNearLimit ? AppColors.warning : AppColors.secondary;

      return Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: Border(
            bottom:
                BorderSide(color: Theme.of(context).dividerColor, width: 0.5),
          ),
        ),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Theme.of(context)
                .colorScheme
                .surfaceContainerHighest
                .withValues(alpha: 0.62),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: accent.withValues(alpha: 0.22)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child:
                        Icon(Icons.data_usage_rounded, size: 17, color: accent),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          inference.isModelLoaded.value
                              ? 'Context tokens'
                              : 'Estimated context',
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '${_formatTokenCount(used)} used · ${_formatTokenCount(available)} available',
                          style: GoogleFonts.inter(
                            fontSize: 11,
                            color: Theme.of(context).hintColor,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  Text(
                    '$percent%',
                    style: GoogleFonts.firaCode(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: accent,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 9),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 5,
                  backgroundColor:
                      Theme.of(context).dividerColor.withValues(alpha: 0.35),
                  color: accent,
                ),
              ),
            ],
          ),
        ),
      );
    });
  }

  Widget _buildEmptyState(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.chat_bubble_outline_rounded,
              size: 56, color: AppColors.primary.withValues(alpha: 0.3)),
          const SizedBox(height: 16),
          Text(
            'AI Chat',
            style: GoogleFonts.inter(
              fontSize: 24,
              fontWeight: FontWeight.w700,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Start a conversation',
            style: GoogleFonts.inter(
              fontSize: 14,
              color: Theme.of(context).hintColor,
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: () => controller.createNewChat(),
            icon: const Icon(Icons.add),
            label: const Text('New Chat'),
          ),
        ],
      ),
    );
  }

  Widget _buildInputBar(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          top: BorderSide(color: Theme.of(context).dividerColor, width: 0.5),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
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
                ),
              );
            }),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // Image picker
                Obx(() {
                  final settings = Get.find<SettingsController>();
                  final inference = Get.find<InferenceService>();
                  final isLocal = settings.inferenceMode.value == 'local';
                  final showPicker = !isLocal || inference.isVisionLoaded.value;

                  if (!showPicker) return const SizedBox.shrink();

                  return IconButton(
                    icon: Icon(
                      Icons.image_outlined,
                      color: Theme.of(context).hintColor,
                      size: 22,
                    ),
                    onPressed: controller.pickImage,
                    padding: const EdgeInsets.all(8),
                    constraints: const BoxConstraints(),
                  );
                }),
                IconButton(
                  icon: Icon(
                    Icons.attach_file,
                    color: Theme.of(context).hintColor,
                    size: 22,
                  ),
                  onPressed: controller.pickFile,
                  padding: const EdgeInsets.all(8),
                  constraints: const BoxConstraints(),
                ),
                // Text field
                Expanded(
                  child: TextField(
                    controller: controller.textController,
                    onChanged: (v) => controller.inputText.value = v,
                    enabled: true,
                    maxLines: 4,
                    minLines: 1,
                    style: GoogleFonts.inter(
                        fontSize: 14,
                        color: Theme.of(context).colorScheme.onSurface),
                    decoration: InputDecoration(
                      hintText: 'Message…',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide.none,
                      ),
                      filled: true,
                      fillColor:
                          Theme.of(context).colorScheme.surfaceContainerHighest,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 10),
                      isDense: true,
                    ),
                    onSubmitted: (_) => controller.sendMessage(),
                  ),
                ),
                const SizedBox(width: 4),
                // Send / Stop button
                Obx(() {
                  if (controller.isLoading.value) {
                    return IconButton(
                      icon: const Icon(Icons.stop_circle,
                          color: AppColors.error, size: 28),
                      onPressed: controller.stopGenerating,
                      padding: const EdgeInsets.all(8),
                      constraints: const BoxConstraints(),
                    );
                  }
                  final hasText = controller.inputText.value.isNotEmpty;
                  final hasAttachment =
                      controller.selectedFileName.value != null ||
                          controller.selectedImagePath.value != null;
                  final canSend = hasText || hasAttachment;
                  return IconButton(
                    icon: Icon(
                      Icons.arrow_upward_rounded,
                      color: canSend
                          ? AppColors.primary
                          : Theme.of(context).hintColor,
                      size: 24,
                    ),
                    onPressed: canSend ? controller.sendMessage : null,
                    padding: const EdgeInsets.all(8),
                    constraints: const BoxConstraints(),
                    style: canSend
                        ? IconButton.styleFrom(
                            backgroundColor:
                                AppColors.primary.withValues(alpha: 0.15),
                            shape: const CircleBorder(),
                          )
                        : null,
                  );
                }),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showChatHistory(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.6,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              margin: const EdgeInsets.only(top: 12),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Theme.of(context).hintColor,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Chat History',
                style: GoogleFonts.inter(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: Obx(() {
                if (controller.sessions.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      'No chats yet',
                      style:
                          GoogleFonts.inter(color: Theme.of(context).hintColor),
                    ),
                  );
                }
                return ListView.builder(
                  shrinkWrap: true,
                  itemCount: controller.sessions.length,
                  itemBuilder: (context, index) {
                    final session = controller.sessions[index];
                    return ListTile(
                      leading: Icon(
                        controller.currentSessionId.value == session.id
                            ? Icons.chat_bubble
                            : Icons.chat_bubble_outline,
                        color: controller.currentSessionId.value == session.id
                            ? AppColors.primary
                            : Theme.of(context).hintColor,
                        size: 20,
                      ),
                      title: Text(
                        session.title,
                        style: GoogleFonts.inter(
                            fontSize: 14,
                            color: Theme.of(context).colorScheme.onSurface),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        _formatDate(session.updatedAt),
                        style: GoogleFonts.inter(
                            fontSize: 11, color: Theme.of(context).hintColor),
                      ),
                      trailing: IconButton(
                        icon: Icon(Icons.delete_outline,
                            size: 18, color: Theme.of(context).hintColor),
                        onPressed: () => controller.deleteChat(session.id),
                      ),
                      onTap: () {
                        controller.openChat(session.id);
                        Navigator.pop(context);
                      },
                    );
                  },
                );
              }),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final diff = now.difference(date);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${date.day}/${date.month}/${date.year}';
  }

  String _formatTokenCount(int value) {
    if (value >= 1000000) {
      return '${(value / 1000000).toStringAsFixed(1)}M';
    }
    if (value >= 1000) {
      return '${(value / 1000).toStringAsFixed(1)}K';
    }
    return value.toString();
  }

  int _estimateVisibleChatTokens() {
    final chars = controller.messages.fold<int>(
      0,
      (sum, message) => sum + message.content.length,
    );
    return (chars / 4).ceil();
  }
}

/// Animated three-dot typing indicator (like iMessage / ChatGPT).
class _TypingDots extends StatefulWidget {
  const _TypingDots();

  @override
  State<_TypingDots> createState() => _TypingDotsState();
}

class _TypingDotsState extends State<_TypingDots>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            // Stagger each dot by 0.2
            final delay = i * 0.2;
            final t = (_controller.value - delay).clamp(0.0, 1.0);
            // Bounce: scale goes 1→1.4→1 using a sin curve
            final scale = 1.0 +
                0.4 *
                    (t < 0.5
                        ? (t * 2) // ramp up
                        : (1 - (t - 0.5) * 2).clamp(0.0, 1.0)); // ramp down
            final opacity = 0.3 +
                0.7 * (t < 0.5 ? (t * 2) : (1 - (t - 0.5) * 2).clamp(0.0, 1.0));

            return Padding(
              padding: EdgeInsets.only(right: i < 2 ? 4 : 0),
              child: Transform.scale(
                scale: scale,
                child: Opacity(
                  opacity: opacity,
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Theme.of(context).hintColor,
                    ),
                  ),
                ),
              ),
            );
          }),
        );
      },
    );
  }
}

/// Blinking cursor shown at the end of streaming text.
class _BlinkingCursor extends StatefulWidget {
  final Color color;
  const _BlinkingCursor({required this.color});

  @override
  State<_BlinkingCursor> createState() => _BlinkingCursorState();
}

class _BlinkingCursorState extends State<_BlinkingCursor>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Opacity(
          opacity: _controller.value,
          child: Container(
            width: 2,
            height: 16,
            margin: const EdgeInsets.only(left: 2, bottom: 2),
            color: widget.color,
          ),
        );
      },
    );
  }
}
