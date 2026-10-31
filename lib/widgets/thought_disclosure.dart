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

class _ThoughtDisclosureState extends State<ThoughtDisclosure>
    with SingleTickerProviderStateMixin {
  late bool _expanded;
  late DateTime _startedAt;
  Timer? _timer;
  int _liveSeconds = 0;
  late AnimationController _animController;
  late Animation<double> _expandAnimation;

  @override
  void initState() {
    super.initState();
    _expanded = widget.isThinking;
    _startedAt = DateTime.now();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
      value: _expanded ? 1.0 : 0.0,
    );
    _expandAnimation = CurvedAnimation(
      parent: _animController,
      curve: Curves.easeOutCubic,
    );
    _syncTimer();
  }

  @override
  void didUpdateWidget(covariant ThoughtDisclosure oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.isThinking && !oldWidget.isThinking) {
      _expanded = true;
      _startedAt = DateTime.now();
      _liveSeconds = 0;
      _animController.forward();
    } else if (!widget.isThinking && oldWidget.isThinking) {
      _expanded = false;
      _liveSeconds = widget.durationSeconds ?? _liveSeconds;
      _animController.reverse();
    }

    _syncTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _animController.dispose();
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

  void _toggle() {
    setState(() => _expanded = !_expanded);
    if (_expanded) {
      _animController.forward();
    } else {
      _animController.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final muted = Theme.of(context).hintColor;
    final accentColor =
        isDark ? const Color(0xFF0A84FF) : const Color(0xFF007AFF);

    // Inline disclosure: a quiet "Thought for 6s ›" line; expanded reasoning
    // sits behind a thin left rule, like a quote.
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: _toggle,
            splashFactory: NoSplash.splashFactory,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.isThinking)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          color: accentColor,
                        ),
                      ),
                    ),
                  if (!widget.isThinking)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Icon(
                        Icons.lightbulb_outline_rounded,
                        size: 14,
                        color: muted,
                      ),
                    ),
                  Text(
                    _label,
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      color: widget.isThinking ? accentColor : muted,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(width: 4),
                  AnimatedRotation(
                    turns: _expanded ? 0.25 : 0.0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(
                      Icons.chevron_right_rounded,
                      size: 16,
                      color: muted,
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Content
          SizeTransition(
            sizeFactor: _expandAnimation,
            // Top-start; `alignment:` needs a newer Flutter than 3.38.
            axisAlignment: -1.0,
            child: Container(
              margin: const EdgeInsets.only(top: 2, bottom: 6, left: 2),
              padding: const EdgeInsets.only(left: 12),
              decoration: BoxDecoration(
                border: Border(
                  left: BorderSide(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.14)
                        : Colors.black.withValues(alpha: 0.12),
                    width: 2,
                  ),
                ),
              ),
              child: MarkdownBody(
                data: widget.thought.trim(),
                selectable: true,
                styleSheet: widget.styleSheet,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String get _label {
    final seconds = widget.durationSeconds ?? _liveSeconds;
    if (widget.isThinking) {
      return seconds > 0 ? 'Thinking for ${seconds}s…' : 'Thinking…';
    }
    return seconds > 0 ? 'Thought for ${seconds}s' : 'Thought';
  }
}
