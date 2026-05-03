import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:google_fonts/google_fonts.dart';

class ThoughtDisclosure extends StatefulWidget {
  final String thought;
  final bool isThinking;
  final int? durationSeconds;
  final MarkdownStyleSheet styleSheet;

  const ThoughtDisclosure({
    super.key,
    required this.thought,
    required this.styleSheet,
    this.isThinking = false,
    this.durationSeconds,
  });

  @override
  State<ThoughtDisclosure> createState() => _ThoughtDisclosureState();
}

class _ThoughtDisclosureState extends State<ThoughtDisclosure> {
  late bool _expanded;
  late DateTime _startedAt;
  Timer? _timer;
  int _liveSeconds = 0;

  @override
  void initState() {
    super.initState();
    _expanded = widget.isThinking;
    _startedAt = DateTime.now();
    _syncTimer();
  }

  @override
  void didUpdateWidget(covariant ThoughtDisclosure oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.isThinking && !oldWidget.isThinking) {
      _expanded = true;
      _startedAt = DateTime.now();
      _liveSeconds = 0;
    } else if (!widget.isThinking && oldWidget.isThinking) {
      _expanded = false;
      _liveSeconds = widget.durationSeconds ?? _liveSeconds;
    }

    _syncTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _syncTimer() {
    if (!widget.isThinking) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    _timer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _liveSeconds = DateTime.now().difference(_startedAt).inSeconds;
      });
    });
  }

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
                    _label,
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

  String get _label {
    final seconds = widget.durationSeconds ?? _liveSeconds;
    if (widget.isThinking) {
      return seconds > 0 ? 'Thinking for ${seconds}s...' : 'Thinking...';
    }
    return seconds > 0 ? 'Thought for ${seconds}s' : 'Thought';
  }
}
