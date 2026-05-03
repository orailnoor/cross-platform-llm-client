import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:google_fonts/google_fonts.dart';

class ThoughtDisclosure extends StatefulWidget {
  final String thought;
  final bool isThinking;
  final MarkdownStyleSheet styleSheet;

  const ThoughtDisclosure({
    super.key,
    required this.thought,
    required this.styleSheet,
    this.isThinking = false,
  });

  @override
  State<ThoughtDisclosure> createState() => _ThoughtDisclosureState();
}

class _ThoughtDisclosureState extends State<ThoughtDisclosure> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).hintColor;
    final borderColor = Theme.of(context).dividerColor.withValues(alpha: 0.65);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: Theme.of(context)
            .colorScheme
            .surfaceContainerHighest
            .withValues(alpha: 0.34),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: borderColor, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.isThinking ? 'Thinking...' : 'Thought',
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      color: muted,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    _expanded
                        ? Icons.keyboard_arrow_down_rounded
                        : Icons.chevron_right_rounded,
                    size: 18,
                    color: muted,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: MarkdownBody(
                data: widget.thought.trim(),
                selectable: true,
                styleSheet: widget.styleSheet,
              ),
            ),
        ],
      ),
    );
  }
}
