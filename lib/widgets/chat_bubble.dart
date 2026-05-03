import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:google_fonts/google_fonts.dart';
import '../core/theme.dart';
import '../models/chat_message.dart';
import '../utils/thought_parser.dart';
import 'thought_disclosure.dart';

class ChatBubble extends StatelessWidget {
  final ChatMessage message;

  const ChatBubble({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    final isUser = message.role == 'user';
    final visibleContent = message.fileName == null
        ? message.content
        : message.content.split('\n\nAttached file:').first;
    final thoughtParts = isUser
        ? const ThoughtParts(thought: '', answer: '', isThinking: false)
        : splitThoughtTags(visibleContent);
    final answerContent = isUser ? visibleContent : thoughtParts.answer.trim();

    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.82,
        ),
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: _getBubbleColor(context),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isUser ? 16 : 4),
            bottomRight: Radius.circular(isUser ? 4 : 16),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Image attachment (base64 — works on all platforms)
            if (message.imageBase64 != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Image.memory(
                    base64Decode(message.imageBase64!),
                    width: double.infinity,
                    height: 200,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(
                      height: 100,
                      color: Colors.grey[300],
                      child: const Center(child: Icon(Icons.broken_image)),
                    ),
                  ),
                ),
              ),

            // Message content
            if (!isUser && thoughtParts.hasThought)
              ThoughtDisclosure(
                thought: thoughtParts.thought,
                durationSeconds: message.thoughtDurationSeconds,
                styleSheet: _thoughtMarkdownStyle(context),
              ),
            if (isUser)
              SelectableText(
                visibleContent,
                style: GoogleFonts.inter(
                  fontSize: 14,
                  color: Theme.of(context).colorScheme.onSurface,
                  height: 1.4,
                ),
              )
            else if (answerContent.isNotEmpty)
              MarkdownBody(
                data: answerContent,
                selectable: true,
                styleSheet: _markdownStyle(context),
              ),
            if (message.fileName != null) ...[
              const SizedBox(height: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: Theme.of(context)
                      .colorScheme
                      .surfaceContainerHighest
                      .withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.description_outlined,
                        size: 16, color: Theme.of(context).hintColor),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        message.fileName!,
                        style: GoogleFonts.inter(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurface,
                          fontWeight: FontWeight.w600,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ],

            // Timestamp and Speed
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                if (message.tokensPerSec != null && message.tokensPerSec! > 0)
                  Text(
                    '⚡ ${message.tokensPerSec!.toStringAsFixed(1)} tok/s',
                    style: GoogleFonts.firaCode(
                      fontSize: 9,
                      color: Theme.of(context).hintColor.withValues(alpha: 0.6),
                      fontWeight: FontWeight.w500,
                    ),
                  )
                else
                  const SizedBox.shrink(),
                Text(
                  _formatTime(message.timestamp),
                  style: GoogleFonts.inter(
                    fontSize: 10,
                    color: Theme.of(context).hintColor,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Color _getBubbleColor(BuildContext context) {
    if (message.role == 'user') return AppTheme.userBubbleColor(context);
    return AppTheme.aiBubbleColor(context);
  }

  MarkdownStyleSheet _markdownStyle(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurface;
    final muted = Theme.of(context).hintColor;
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
      blockquote: base.copyWith(color: muted),
      blockquoteDecoration: BoxDecoration(
        border: Border(left: BorderSide(color: muted.withValues(alpha: 0.45))),
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

  String _formatTime(DateTime date) {
    final h = date.hour.toString().padLeft(2, '0');
    final m = date.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}
