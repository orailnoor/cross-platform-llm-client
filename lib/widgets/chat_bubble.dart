import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:google_fonts/google_fonts.dart';
import '../models/chat_message.dart';
import '../utils/thought_parser.dart';
import 'attachment_preview.dart';
import 'image_viewer.dart';
import 'thought_disclosure.dart';

class ChatBubble extends StatelessWidget {
  final ChatMessage message;

  const ChatBubble({super.key, required this.message});

  // ── Apple-style colors ──
  static const _appleBlue = Color(0xFF007AFF);
  static const _appleBlueDark = Color(0xFF0A84FF);

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == 'user';
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Premium Generated Image Card (Assistant only)
    if (!isUser && message.decodedImageBytes != null) {
      return _buildGeneratedImageCard(context, isDark);
    }

    final visibleContent = message.fileName == null
        ? message.content
        : message.content.split('\n\nAttached file:').first;
    final thoughtParts = isUser
        ? const ThoughtParts(thought: '', answer: '', isThinking: false)
        : splitThoughtTags(_cleanAssistantText(visibleContent));
    final answerContent = isUser ? visibleContent : thoughtParts.answer.trim();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
      child: Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.78,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: _bubbleColor(context, isUser),
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(20),
              topRight: const Radius.circular(20),
              bottomLeft: Radius.circular(isUser ? 20 : 6),
              bottomRight: Radius.circular(isUser ? 6 : 20),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Image attachment
              if (message.decodedImageBytes != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: GestureDetector(
                    onTap: () => ImageViewer.show(context, message.imageBase64!),
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: isDark ? Colors.white.withValues(alpha: 0.15) : Colors.black.withValues(alpha: 0.1),
                          width: 1,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.1),
                            blurRadius: 8,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(15),
                        child: Image.memory(
                          message.decodedImageBytes!,
                          width: double.infinity,
                          // Omit height and fit to allow the image to scale naturally without cropping
                          gaplessPlayback: true,
                          errorBuilder: (_, __, ___) => Container(
                            height: 150,
                            decoration: BoxDecoration(
                              color: isDark
                                  ? Colors.white.withValues(alpha: 0.05)
                                  : Colors.black.withValues(alpha: 0.05),
                            ),
                            child: const Center(child: Icon(Icons.broken_image_rounded, size: 28)),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),

              // Thought disclosure
              if (!isUser && thoughtParts.hasThought)
                ThoughtDisclosure(
                  thought: thoughtParts.thought,
                  durationSeconds: message.thoughtDurationSeconds,
                  styleSheet: _thoughtMarkdownStyle(context),
                ),

              // Message content
              if (isUser)
                SelectableText(
                  visibleContent,
                  style: GoogleFonts.inter(
                    fontSize: 15,
                    color: Colors.white,
                    height: 1.45,
                    fontWeight: FontWeight.w400,
                  ),
                )
              else if (answerContent.isNotEmpty)
                MarkdownBody(
                  data: answerContent,
                  selectable: true,
                  styleSheet: _markdownStyle(context),
                ),

              // File attachment
              if (message.fileName != null) ...[
                const SizedBox(height: 10),
                AttachmentPreview(
                  fileName: message.fileName!,
                  fileType: message.fileType,
                  fileSize: message.fileSize,
                  imageBase64: message.imageBase64,
                  imagePath: message.imagePath,
                  compact: true,
                ),
              ],

              // Timestamp & speed
              const SizedBox(height: 8),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (message.tokensPerSec != null && message.tokensPerSec! > 0)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Text(
                        '${message.tokensPerSec!.toStringAsFixed(1)} tok/s',
                        style: GoogleFonts.inter(
                          fontSize: 10,
                          color: isUser
                              ? Colors.white.withValues(alpha: 0.55)
                              : Theme.of(context).hintColor.withValues(alpha: 0.5),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  if (message.imageGenDurationMs != null && message.imageGenDurationMs! > 0)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: Text(
                        _formatGenTime(message.imageGenDurationMs!),
                        style: GoogleFonts.inter(
                          fontSize: 10,
                          color: isUser
                              ? Colors.white.withValues(alpha: 0.55)
                              : Theme.of(context).hintColor.withValues(alpha: 0.5),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  Text(
                    _formatTime(message.timestamp),
                    style: GoogleFonts.inter(
                      fontSize: 10,
                      color: isUser
                          ? Colors.white.withValues(alpha: 0.55)
                          : Theme.of(context).hintColor.withValues(alpha: 0.5),
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Color _bubbleColor(BuildContext context, bool isUser) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    if (isUser) return isDark ? _appleBlueDark : _appleBlue;
    return isDark ? const Color(0xFF1C1C1E) : const Color(0xFFF2F2F7);
  }

  MarkdownStyleSheet _markdownStyle(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final color = Theme.of(context).colorScheme.onSurface;
    final muted = Theme.of(context).hintColor;
    final base = GoogleFonts.inter(fontSize: 15, color: color, height: 1.5);
    final codeBlockBg = isDark ? const Color(0xFF2C2C2E) : const Color(0xFFE5E5EA);

    return MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
      p: base,
      strong: base.copyWith(fontWeight: FontWeight.w600),
      em: base.copyWith(fontStyle: FontStyle.italic),
      listBullet: base,
      code: GoogleFonts.firaCode(
        fontSize: 13,
        color: color,
        backgroundColor: codeBlockBg,
      ),
      codeblockDecoration: BoxDecoration(
        color: codeBlockBg,
        borderRadius: BorderRadius.circular(12),
      ),
      codeblockPadding: const EdgeInsets.all(14),
      blockquote: base.copyWith(color: muted),
      blockquoteDecoration: BoxDecoration(
        border: Border(
          left: BorderSide(
            color: isDark ? Colors.white.withValues(alpha: 0.15) : Colors.black.withValues(alpha: 0.15),
            width: 3,
          ),
        ),
      ),
      blockquotePadding: const EdgeInsets.only(left: 14, top: 2, bottom: 2),
    );
  }

  MarkdownStyleSheet _thoughtMarkdownStyle(BuildContext context) {
    final muted = Theme.of(context).hintColor;
    final base = GoogleFonts.inter(fontSize: 13, color: muted, height: 1.4);
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
      p: base,
      strong: base.copyWith(fontWeight: FontWeight.w600),
      em: base.copyWith(fontStyle: FontStyle.italic),
      listBullet: base,
      code: GoogleFonts.firaCode(
        fontSize: 11,
        color: muted,
        backgroundColor: isDark ? const Color(0xFF2C2C2E) : const Color(0xFFE5E5EA),
      ),
      codeblockDecoration: BoxDecoration(
        color: isDark ? const Color(0xFF2C2C2E) : const Color(0xFFE5E5EA),
        borderRadius: BorderRadius.circular(10),
      ),
    );
  }

  String _formatTime(DateTime date) {
    final h = date.hour.toString().padLeft(2, '0');
    final m = date.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  String _formatGenTime(int ms) {
    if (ms < 1000) return '${ms}ms';
    if (ms < 60000) return '${(ms / 1000).toStringAsFixed(1)}s';
    final m = ms ~/ 60000;
    final s = (ms % 60000) ~/ 1000;
    return s > 0 ? '${m}m ${s}s' : '${m}m';
  }

  String _cleanAssistantText(String text) {
    return text
        .replaceAll('<|endoftext|>', '')
        .replaceAll('<|im_end|>', '')
        .replaceAll('<|end|>', '')
        .trim();
  }

  Widget _buildGeneratedImageCard(BuildContext context, bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Align(
        alignment: Alignment.centerLeft,
        child: GestureDetector(
          onTap: () => ImageViewer.show(context, message.imageBase64!),
          child: Container(
            constraints: BoxConstraints(
              maxWidth: MediaQuery.of(context).size.width * 0.82,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: isDark ? Colors.white.withValues(alpha: 0.15) : Colors.black.withValues(alpha: 0.1),
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.15),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(19),
              child: Stack(
                children: [
                  Image.memory(
                    message.decodedImageBytes!,
                    width: double.infinity,
                    gaplessPlayback: true,
                    errorBuilder: (_, __, ___) => Container(
                      height: 150,
                      color: isDark ? const Color(0xFF1C1C1E) : const Color(0xFFF2F2F7),
                      child: const Center(child: Icon(Icons.broken_image_rounded, size: 28)),
                    ),
                  ),
                  // Time elapsed overlay
                  if (message.imageGenDurationMs != null && message.imageGenDurationMs! > 0)
                    Positioned(
                      bottom: 10,
                      right: 10,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.7),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.white.withValues(alpha: 0.2), width: 0.5),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.2),
                              blurRadius: 4,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.timer_outlined, size: 10, color: Colors.white),
                            const SizedBox(width: 4),
                            Text(
                              _formatGenTime(message.imageGenDurationMs!),
                              style: GoogleFonts.inter(fontSize: 10, color: Colors.white, fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
