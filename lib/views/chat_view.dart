import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import '../controllers/chat_controller.dart';
import '../controllers/home_controller.dart';
import '../controllers/model_controller.dart';
import '../controllers/settings_controller.dart';
import '../core/colors.dart';
import '../services/inference_service.dart';
import '../widgets/chat_bubble.dart';

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
                        : settings.kimiModel.value;
            modelLabel = model;
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
                      Icon(Icons.bolt, size: 12, color: AppColors.warning),
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

          // Image preview
          Obx(() {
            if (controller.selectedImagePath.value == null) {
              return const SizedBox.shrink();
            }
            return Container(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: controller.selectedImageBase64.value != null
                        ? Image.memory(
                            base64Decode(controller.selectedImageBase64.value!),
                            width: 60,
                            height: 60,
                            fit: BoxFit.cover,
                          )
                        : Container(
                            width: 60,
                            height: 60,
                            color: Colors.grey[300],
                            child: const Icon(Icons.image, size: 30),
                          ),
                  ),
                  const SizedBox(width: 8),
                  Text('Image attached',
                      style: GoogleFonts.inter(
                          color:
                              Theme.of(context).textTheme.bodyMedium?.color ??
                                  Colors.grey,
                          fontSize: 13)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: controller.clearImage,
                  ),
                ],
              ),
            );
          }),

          // Input bar
          _buildInputBar(context),
        ],
      ),
    );
  }

  /// Real-time streaming bubble — shows AI response as it generates token-by-token.
  Widget _buildStreamingBubble(BuildContext context, String text) {
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
        child: text.isEmpty
            ? _buildTypingIndicator(context)
            : Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: SelectableText(
                      text,
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        color: Theme.of(context).colorScheme.onSurface,
                        height: 1.4,
                      ),
                    ),
                  ),
                  // Blinking cursor at the end while still generating
                  _BlinkingCursor(color: Theme.of(context).hintColor),
                ],
              ),
      ),
    );
  }

  /// Animated typing dots — shown only during prefill (before first token).
  Widget _buildTypingIndicator(BuildContext context) {
    return const _TypingDots();
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
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // Image picker
                IconButton(
                  icon: Icon(
                    Icons.image_outlined,
                    color: Theme.of(context).hintColor,
                    size: 22,
                  ),
                  onPressed: controller.pickImage,
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
                      onPressed: () {
                        Get.find<InferenceService>().stopGeneration();
                        controller.isLoading.value = false;
                        controller.isStreaming.value = false;
                        controller.streamingResponse.value = '';
                      },
                      padding: const EdgeInsets.all(8),
                      constraints: const BoxConstraints(),
                    );
                  }
                  final hasText = controller.inputText.value.isNotEmpty;
                  return IconButton(
                    icon: Icon(
                      Icons.arrow_upward_rounded,
                      color: hasText
                          ? AppColors.primary
                          : Theme.of(context).hintColor,
                      size: 24,
                    ),
                    onPressed: hasText ? controller.sendMessage : null,
                    padding: const EdgeInsets.all(8),
                    constraints: const BoxConstraints(),
                    style: hasText
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

  void _showLoadModelSheet(BuildContext context) {
    final modelController = Get.find<ModelController>();
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
                'Load Model',
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
                final downloaded = modelController.downloadedFiles;
                if (downloaded.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.download_outlined,
                            size: 48, color: Theme.of(context).hintColor),
                        const SizedBox(height: 12),
                        Text(
                          'No models downloaded',
                          style: GoogleFonts.inter(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Go to Models tab to download one.',
                          textAlign: TextAlign.center,
                          style: GoogleFonts.inter(
                            fontSize: 13,
                            color: Theme.of(context).hintColor,
                          ),
                        ),
                        const SizedBox(height: 16),
                        ElevatedButton.icon(
                          onPressed: () {
                            Navigator.pop(context);
                            Get.find<HomeController>().changeTab(2);
                          },
                          icon: const Icon(Icons.download, size: 16),
                          label: const Text('Go to Models'),
                        ),
                      ],
                    ),
                  );
                }
                return ListView.builder(
                  shrinkWrap: true,
                  itemCount: downloaded.length,
                  itemBuilder: (context, index) {
                    final filename = downloaded[index];
                    final model = modelController.availableModels
                        .firstWhereOrNull((m) => m.filename == filename);
                    return ListTile(
                      leading:
                          const Icon(Icons.memory, color: AppColors.primary),
                      title: Text(
                        model?.name ?? filename,
                        style: GoogleFonts.inter(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                      subtitle: Text(
                        filename,
                        style: GoogleFonts.inter(
                          fontSize: 11,
                          color: Theme.of(context).hintColor,
                        ),
                      ),
                      trailing: ElevatedButton(
                        onPressed: () {
                          Navigator.pop(context);
                          modelController.loadModel(filename);
                        },
                        style: ElevatedButton.styleFrom(
                          minimumSize: Size.zero,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 8),
                        ),
                        child: const Text('Load'),
                      ),
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
            final scale = 1.0 + 0.4 * (t < 0.5
                ? (t * 2) // ramp up
                : (1 - (t - 0.5) * 2).clamp(0.0, 1.0)); // ramp down
            final opacity = 0.3 + 0.7 * (t < 0.5
                ? (t * 2)
                : (1 - (t - 0.5) * 2).clamp(0.0, 1.0));

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
