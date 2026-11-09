import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';

import '../widgets/tonal_button.dart';
import 'haptics.dart';

export '../widgets/tonal_button.dart';

/// Shared design system — the same visual language as the home and chat
/// screens: plain white/black pages, quiet neutral surfaces with hairline
/// borders, sentence-case section labels, and one accent colour (blue) used
/// sparingly for the primary action.
///
/// Prefer these widgets over hand-rolled containers so every screen matches.
class AppTokens {
  final bool isDark;
  final Color bg;
  final Color text;
  final Color muted;
  final Color faint;
  final Color accent;
  final Color surface;
  final Color surfacePressed;
  final Color fill; // small neutral fills: icon circles, chips, tracks
  final Color outline;
  final Color hairline;
  final Color green;
  final Color orange;
  final Color red;

  const AppTokens._({
    required this.isDark,
    required this.bg,
    required this.text,
    required this.muted,
    required this.faint,
    required this.accent,
    required this.surface,
    required this.surfacePressed,
    required this.fill,
    required this.outline,
    required this.hairline,
    required this.green,
    required this.orange,
    required this.red,
  });

  factory AppTokens.of(BuildContext context) {
    final d = Theme.of(context).brightness == Brightness.dark;
    return AppTokens._(
      isDark: d,
      bg: d ? Colors.black : Colors.white,
      text: d ? Colors.white : const Color(0xFF0B0B0C),
      muted: d ? const Color(0xFF8E8E93) : const Color(0xFF6E6E73),
      faint: d ? const Color(0xFF5A5A5F) : const Color(0xFFAEAEB2),
      accent: d ? const Color(0xFF0A84FF) : const Color(0xFF007AFF),
      surface: d ? const Color(0xFF141416) : const Color(0xFFF5F5F7),
      surfacePressed: d ? const Color(0xFF1E1E21) : const Color(0xFFEBEBED),
      fill: d
          ? Colors.white.withValues(alpha: 0.08)
          : Colors.black.withValues(alpha: 0.05),
      outline: d
          ? Colors.white.withValues(alpha: 0.14)
          : Colors.black.withValues(alpha: 0.10),
      hairline: d
          ? Colors.white.withValues(alpha: 0.07)
          : Colors.black.withValues(alpha: 0.06),
      green: d ? const Color(0xFF30D158) : const Color(0xFF28A745),
      orange: d ? const Color(0xFFFF9F0A) : const Color(0xFFE08600),
      red: d ? const Color(0xFFFF453A) : const Color(0xFFE5342B),
    );
  }

  // ── Type scale ──
  TextStyle get title => GoogleFonts.inter(
      fontSize: 17,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.3,
      color: text);
  TextStyle get body =>
      GoogleFonts.inter(fontSize: 15, letterSpacing: -0.15, color: text);
  TextStyle get bodyStrong => GoogleFonts.inter(
      fontSize: 15,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.2,
      color: text);
  // Two-line rows: both lines fit the 32 icon height, so a 44 row keeps its
  // icon inset (and the group's concentric corners).
  TextStyle get rowTitle => GoogleFonts.inter(
      fontSize: 14, height: 1.15, letterSpacing: -0.15, color: text);
  TextStyle get rowSubtitle =>
      GoogleFonts.inter(fontSize: 12, height: 1.2, color: muted);
  TextStyle get caption =>
      GoogleFonts.inter(fontSize: 13, height: 1.35, color: muted);
  TextStyle get small => GoogleFonts.inter(fontSize: 12, color: muted);
  TextStyle get label => GoogleFonts.inter(
      fontSize: 13,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.08,
      color: muted);
  TextStyle get mono => GoogleFonts.firaCode(fontSize: 12.5, color: text);
}

// ── Page chrome ─────────────────────────────────────────────────────────

/// Standard tab-screen app bar: left-aligned bold title, page background,
/// no elevation. Hairline appears only once content scrolls under it.
PreferredSizeWidget appScreenBar(
  BuildContext context, {
  required String title,
  List<Widget>? actions,
  Widget? leading,
  bool showBack = false,
}) {
  final t = AppTokens.of(context);
  return AppBar(
    backgroundColor: t.bg,
    surfaceTintColor: Colors.transparent,
    elevation: 0,
    scrolledUnderElevation: 0,
    automaticallyImplyLeading: showBack,
    leading: leading,
    iconTheme: IconThemeData(color: t.text),
    titleSpacing: leading == null && !showBack ? 20 : 0,
    title: Text(title,
        style: GoogleFonts.inter(
            fontSize: 22,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.6,
            color: t.text)),
    actions: [...?actions, const SizedBox(width: 6)],
  );
}

/// Neutral icon button for app bars.
class AppBarIcon extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  const AppBarIcon(
      {super.key, required this.icon, required this.tooltip, this.onPressed});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 22, color: onPressed == null ? t.faint : t.text),
    );
  }
}

/// Standard horizontal page padding.
const kPagePadding = EdgeInsets.fromLTRB(8, 4, 8, 24);

// ── Sections & groups ───────────────────────────────────────────────────

/// Sentence-case section label with optional trailing widget (e.g. a sort
/// toggle or a count).
class SectionHeader extends StatelessWidget {
  final String title;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;
  const SectionHeader(this.title,
      {super.key,
      this.trailing,
      this.padding = const EdgeInsets.fromLTRB(0, 12, 12, 4)});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Padding(
      padding: padding,
      child: Row(children: [
        Expanded(child: Text(title, style: t.label)),
        if (trailing != null) trailing!,
      ]),
    );
  }
}

/// Footnote text under a group.
class SectionFootnote extends StatelessWidget {
  final String text;
  const SectionFootnote(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
      child: Text(text, style: AppTokens.of(context).small),
    );
  }
}

/// Rounded neutral surface. Use [AppGroup] for lists of rows.
class AppCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final bool outlined;
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(12),
    this.onTap,
    this.outlined = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Material(
      color: outlined ? Colors.transparent : t.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: BorderSide(
            color: outlined ? t.outline : t.hairline,
            width: outlined ? 1 : 0.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        splashFactory: NoSplash.splashFactory,
        highlightColor: t.surfacePressed,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// Grouped list surface with inset hairline dividers between children.
class AppGroup extends StatelessWidget {
  final List<Widget> children;
  final double dividerIndent;

  /// No surface/border — just the rows and dividers. For use inside another
  /// card (e.g. a [CollapsibleCard] body).
  final bool flat;
  const AppGroup(
      {super.key,
      required this.children,
      this.dividerIndent = 0,
      this.flat = false});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final items = children.where((w) => w is! SizedBox || w.height != 0);
    final list = items.toList();
    return Container(
      decoration: flat
          ? null
          : BoxDecoration(
              color: t.surface,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: t.hairline, width: 0.5),
            ),
      clipBehavior: flat ? Clip.none : Clip.antiAlias,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        for (var i = 0; i < list.length; i++) ...[
          if (i > 0)
            Padding(
              padding: EdgeInsets.only(left: dividerIndent),
              child: Container(height: 0.5, color: t.hairline),
            ),
          list[i],
        ],
      ]),
    );
  }
}

/// Card with a tappable header (icon, title, live one-line summary, chevron)
/// that expands to reveal its body. Expansion state survives rebuilds.
class CollapsibleCard extends StatefulWidget {
  final IconData icon;
  final String title;
  final String? summary;
  final Widget child;
  final bool initiallyExpanded;

  const CollapsibleCard({
    super.key,
    required this.icon,
    required this.title,
    this.summary,
    required this.child,
    this.initiallyExpanded = false,
  });

  @override
  State<CollapsibleCard> createState() => _CollapsibleCardState();
}

class _CollapsibleCardState extends State<CollapsibleCard> {
  late bool _open = widget.initiallyExpanded;

  void _toggle() {
    Haptics.selectionClick();
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _open = !_open);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Container(
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: t.hairline, width: 0.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        InkWell(
          onTap: _toggle,
          splashFactory: NoSplash.splashFactory,
          highlightColor: t.surfacePressed,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(6, 6, 10, 6),
            child: Row(children: [
              IconBadge(widget.icon),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(widget.title,
                          style: t.rowTitle
                              .copyWith(fontWeight: FontWeight.w600)),
                      if (widget.summary != null &&
                          widget.summary!.isNotEmpty) ...[
                        const SizedBox(height: 1),
                        Text(widget.summary!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: t.rowSubtitle.copyWith(fontFeatures: const [
                              FontFeature.tabularFigures()
                            ])),
                      ],
                    ]),
              ),
              const SizedBox(width: 8),
              AnimatedRotation(
                turns: _open ? 0.5 : 0,
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                child:
                    Icon(Icons.expand_more_rounded, size: 22, color: t.faint),
              ),
            ]),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 240),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: _open
              ? Column(mainAxisSize: MainAxisSize.min, children: [
                  Container(height: 0.5, color: t.hairline),
                  widget.child,
                ])
              : const SizedBox(width: double.infinity),
        ),
      ]),
    );
  }
}

/// Standard row inside an [AppGroup].
class AppRow extends StatelessWidget {
  final IconData? icon;
  final Widget? leading;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool destructive;
  final bool chevron;
  final bool selected;

  const AppRow({
    super.key,
    this.icon,
    this.leading,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.destructive = false,
    this.chevron = false,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final color = destructive ? t.red : t.text;
    final hasSubtitle = subtitle != null && subtitle!.isNotEmpty;
    final lead = leading ??
        (icon != null
            ? IconBadge(icon!, color: destructive ? t.red : null)
            : null);
    return InkWell(
      onTap: onTap == null
          ? null
          : () {
              Haptics.selectionClick();
              onTap!();
            },
      splashFactory: NoSplash.splashFactory,
      highlightColor: t.surfacePressed,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Padding(
          padding: lead != null
              ? const EdgeInsets.all(6)
              : const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          child: Row(children: [
            if (lead != null) ...[lead, const SizedBox(width: 12)],
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title,
                        maxLines: hasSubtitle ? 1 : null,
                        overflow: hasSubtitle ? TextOverflow.ellipsis : null,
                        style: (hasSubtitle ? t.rowTitle : t.body).copyWith(
                            color: color,
                            fontWeight:
                                selected ? FontWeight.w600 : FontWeight.w400)),
                    if (hasSubtitle) ...[
                      const SizedBox(height: 1),
                      Text(subtitle!, style: t.rowSubtitle),
                    ],
                  ]),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 10),
              // A Switch lays out 40-48 tall around its 32 track, which would
              // push the row past 44. Lay it out at the track's own size.
              if (trailing is Switch)
                SizedBox(
                  width: 52,
                  height: 32,
                  child: OverflowBox(
                    maxHeight: 48,
                    child: trailing!,
                  ),
                )
              else
                trailing!,
            ],
            if (selected && trailing == null)
              Icon(Icons.check_rounded, size: 20, color: t.accent),
            if (chevron) ...[
              const SizedBox(width: 4),
              Icon(Icons.chevron_right_rounded, size: 20, color: t.faint),
            ],
          ]),
        ),
      ),
    );
  }
}

/// Neutral circular icon holder — replaces the old colourful iOS squares.
class IconBadge extends StatelessWidget {
  final IconData icon;
  final double size;
  final Color? color;
  const IconBadge(this.icon, {super.key, this.size = 32, this.color});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(shape: BoxShape.circle, color: t.fill),
      child: Icon(icon,
          size: size * 0.53, color: color ?? t.text.withValues(alpha: 0.8)),
    );
  }
}

// ── Small pieces ────────────────────────────────────────────────────────

class StatusDot extends StatelessWidget {
  final Color color;
  final double size;
  const StatusDot(this.color, {super.key, this.size = 6});

  @override
  Widget build(BuildContext context) => Container(
      width: size,
      height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle));
}

/// Compact label badge. Neutral by default; pass [color] to tint.
class AppTag extends StatelessWidget {
  final String label;
  final Color? color;
  final IconData? icon;
  const AppTag(this.label, {super.key, this.color, this.icon});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final fg = color ?? t.muted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color == null ? t.fill : color!.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[
          Icon(icon, size: 11, color: fg),
          const SizedBox(width: 3),
        ],
        Text(label,
            style: GoogleFonts.inter(
                fontSize: 11, fontWeight: FontWeight.w600, color: fg)),
      ]),
    );
  }
}

/// Thin rounded progress bar.
class AppProgressBar extends StatelessWidget {
  final double? value;
  final Color? color;
  final double height;
  const AppProgressBar({super.key, this.value, this.color, this.height = 4});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: LinearProgressIndicator(
        value: value,
        minHeight: height,
        color: color ?? t.accent,
        backgroundColor: t.fill,
      ),
    );
  }
}

/// Horizontal filter chips. Selected = solid text-colour fill; others are
/// outlined, matching the home suggestion pills.
class AppChips<T> extends StatelessWidget {
  final List<(T, String)> items;
  final T selected;
  final ValueChanged<T> onSelected;
  const AppChips(
      {super.key,
      required this.items,
      required this.selected,
      required this.onSelected});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: [
        for (final (value, label) in items) ...[
          Builder(builder: (_) {
            final on = value == selected;
            return Material(
              color: on ? t.text : Colors.transparent,
              shape: StadiumBorder(
                  side: BorderSide(color: on ? t.text : t.outline)),
              child: InkWell(
                customBorder: const StadiumBorder(),
                splashFactory: NoSplash.splashFactory,
                onTap: () {
                  Haptics.selectionClick();
                  onSelected(value);
                },
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  child: Text(label,
                      style: GoogleFonts.inter(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w500,
                          color: on ? t.bg : t.text.withValues(alpha: 0.85))),
                ),
              ),
            );
          }),
          const SizedBox(width: 8),
        ],
      ]),
    );
  }
}

/// iOS-style segmented control with a sliding thumb.
class AppSegmented<T> extends StatelessWidget {
  final List<(T, String)> items;
  final T selected;
  final ValueChanged<T> onChanged;
  const AppSegmented(
      {super.key,
      required this.items,
      required this.selected,
      required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final index =
        items.indexWhere((e) => e.$1 == selected).clamp(0, items.length - 1);
    return Container(
      height: 40,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: t.fill,
        borderRadius: BorderRadius.circular(12),
      ),
      child: LayoutBuilder(builder: (context, box) {
        final w = box.maxWidth / items.length;
        return Stack(children: [
          AnimatedPositioned(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            left: w * index,
            top: 0,
            bottom: 0,
            width: w,
            child: Container(
              decoration: BoxDecoration(
                color: t.isDark ? const Color(0xFF2C2C2F) : Colors.white,
                borderRadius: BorderRadius.circular(9),
                boxShadow: t.isDark
                    ? null
                    : [
                        BoxShadow(
                            color: Colors.black.withValues(alpha: 0.08),
                            blurRadius: 6,
                            offset: const Offset(0, 1)),
                      ],
              ),
            ),
          ),
          Row(children: [
            for (var i = 0; i < items.length; i++)
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    if (i != index) Haptics.selectionClick();
                    onChanged(items[i].$1);
                  },
                  child: Center(
                    child: Text(items[i].$2,
                        style: GoogleFonts.inter(
                            fontSize: 14,
                            fontWeight:
                                i == index ? FontWeight.w600 : FontWeight.w500,
                            color: i == index ? t.text : t.muted)),
                  ),
                ),
              ),
          ]),
        ]);
      }),
    );
  }
}

/// Primary filled button (accent). Full-width by default.
class PrimaryButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool busy;
  final bool expand;
  final double radius;
  const PrimaryButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.busy = false,
    this.expand = true,
    this.radius = 12,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final enabled = onPressed != null && !busy;
    final child = Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (busy)
          const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: Colors.white))
        else if (icon != null)
          Icon(icon, size: 18, color: Colors.white),
        if (busy || icon != null) const SizedBox(width: 8),
        Text(label,
            style: GoogleFonts.inter(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: Colors.white)),
      ],
    );
    final button = Material(
      color: enabled ? t.accent : t.accent.withValues(alpha: 0.4),
      borderRadius: BorderRadius.circular(radius),
      child: InkWell(
        borderRadius: BorderRadius.circular(radius),
        onTap: enabled ? onPressed : null,
        child: SizedBox(
          height: 48,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18),
            child: Center(child: child),
          ),
        ),
      ),
    );
    return expand ? SizedBox(width: double.infinity, child: button) : button;
  }
}

/// Small pill action (e.g. "Load", "Download") used inside rows and cards.
class PillButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final bool primary;
  final bool destructive;
  final IconData? icon;
  const PillButton({
    super.key,
    required this.label,
    this.onPressed,
    this.primary = false,
    this.destructive = false,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final Color bg;
    final Color fg;
    if (primary) {
      bg = t.accent;
      fg = Colors.white;
    } else if (destructive) {
      bg = t.red.withValues(alpha: t.isDark ? 0.16 : 0.10);
      fg = t.red;
    } else {
      bg = t.fill;
      fg = t.text;
    }
    return Opacity(
      opacity: onPressed == null ? 0.45 : 1,
      child: Material(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onPressed,
          child: Padding(
            padding: EdgeInsets.fromLTRB(icon != null ? 10 : 14, 7, 14, 7),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (icon != null) ...[
                Icon(icon, size: 15, color: fg),
                const SizedBox(width: 5),
              ],
              Text(label,
                  style: GoogleFonts.inter(
                      fontSize: 13, fontWeight: FontWeight.w600, color: fg)),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Centered empty / zero state.
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;
  const EmptyState(
      {super.key,
      required this.icon,
      required this.title,
      this.message,
      this.action});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 36),
      child: Column(children: [
        IconBadge(icon, size: 52),
        const SizedBox(height: 14),
        Text(title, textAlign: TextAlign.center, style: t.bodyStrong),
        if (message != null) ...[
          const SizedBox(height: 4),
          Text(message!, textAlign: TextAlign.center, style: t.caption),
        ],
        if (action != null) ...[const SizedBox(height: 18), action!],
      ]),
    );
  }
}

/// Inline notice (info / warning / error) — tinted, no heavy borders.
class AppNotice extends StatelessWidget {
  final String text;
  final IconData icon;
  final Color? color;
  const AppNotice(this.text,
      {super.key, this.icon = Icons.info_outline_rounded, this.color});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final c = color ?? t.muted;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: color == null ? t.fill : c.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(icon, size: 16, color: c),
        const SizedBox(width: 8),
        Expanded(
            child: Text(text,
                style: t.caption.copyWith(
                    color:
                        color == null ? t.muted : c.withValues(alpha: 0.95)))),
      ]),
    );
  }
}

// ── Inputs ──────────────────────────────────────────────────────────────

/// Filled text-field decoration matching the composer.
InputDecoration appInputDecoration(BuildContext context,
    {String? hint, String? label, Widget? suffix, Widget? prefix}) {
  final t = AppTokens.of(context);
  OutlineInputBorder b(Color c, [double w = 0]) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: w == 0 ? BorderSide.none : BorderSide(color: c, width: w));
  return InputDecoration(
    hintText: hint,
    labelText: label,
    suffixIcon: suffix,
    prefixIcon: prefix,
    filled: true,
    fillColor: t.isDark ? const Color(0xFF1C1C1F) : const Color(0xFFF0F0F2),
    hintStyle: GoogleFonts.inter(fontSize: 15, color: t.faint),
    labelStyle: GoogleFonts.inter(fontSize: 14, color: t.muted),
    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
    isDense: true,
    border: b(Colors.transparent),
    enabledBorder: b(Colors.transparent),
    focusedBorder: b(t.accent, 1.2),
    errorBorder: b(t.red, 1),
    focusedErrorBorder: b(t.red, 1.2),
  );
}

/// Labelled form field block: label above, field, optional helper below.
class AppField extends StatelessWidget {
  final String label;
  final Widget child;
  final String? helper;
  const AppField(
      {super.key, required this.label, required this.child, this.helper});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.only(left: 2, bottom: 6),
        child: Text(label, style: t.label),
      ),
      child,
      if (helper != null)
        Padding(
          padding: const EdgeInsets.only(left: 2, top: 6),
          child: Text(helper!, style: t.small),
        ),
    ]);
  }
}

// ── Sheets & dialogs ────────────────────────────────────────────────────

/// Bottom sheet with the app's look: rounded top, grab handle, optional
/// title/subtitle, keyboard-aware, scrolls when tall.
Future<T?> showAppSheet<T>(
  BuildContext context, {
  String? title,
  String? subtitle,
  required WidgetBuilder builder,
  bool scrollable = true,
}) {
  final t = AppTokens.of(context);
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: t.isDark ? const Color(0xFF1C1C1E) : Colors.white,
    barrierColor: Colors.black.withValues(alpha: t.isDark ? 0.6 : 0.32),
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
    builder: (ctx) {
      final tt = AppTokens.of(ctx);
      final content = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null) ...[
            Text(title,
                style: GoogleFonts.inter(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.5,
                    color: tt.text)),
            if (subtitle != null) ...[
              const SizedBox(height: 4),
              Text(subtitle, style: tt.caption),
            ],
            const SizedBox(height: 18),
          ],
          builder(ctx),
        ],
      );
      return Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: SafeArea(
          top: false,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 14),
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                    color: tt.outline, borderRadius: BorderRadius.circular(2)),
              ),
            ),
            Flexible(
              child: scrollable
                  ? SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                      child: content)
                  : Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                      child: content),
            ),
          ]),
        ),
      );
    },
  );
}

/// Two-button confirmation sheet (Cancel + confirm). Returns true on confirm.
Future<bool> confirmSheet(
  BuildContext context, {
  required String title,
  String? message,
  required String confirmLabel,
  bool destructive = false,
}) async {
  final ok = await showAppSheet<bool>(
    context,
    title: title,
    subtitle: message,
    builder: (ctx) => Row(children: [
      Expanded(
        child: TonalButton.neutral(ctx,
            label: 'Cancel', onTap: () => Navigator.pop(ctx, false)),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: destructive
            ? TonalButton.destructive(ctx,
                label: confirmLabel, onTap: () => Navigator.pop(ctx, true))
            : PrimaryButton(
                label: confirmLabel, onPressed: () => Navigator.pop(ctx, true)),
      ),
    ]),
  );
  return ok == true;
}

// ── Toasts ──────────────────────────────────────────────────────────────

enum ToastTone { info, success, warning, error }

/// App-wide toast (replaces ad-hoc `Get.snackbar` styling): a dark floating
/// pill at the bottom with a small tone icon. Works without a BuildContext.
void showToast(
  String title,
  String message, {
  ToastTone tone = ToastTone.info,
  Duration duration = const Duration(seconds: 3),
}) {
  final (IconData icon, Color color) = switch (tone) {
    ToastTone.success => (Icons.check_circle_rounded, const Color(0xFF30D158)),
    ToastTone.warning => (Icons.warning_amber_rounded, const Color(0xFFFF9F0A)),
    ToastTone.error => (Icons.error_rounded, const Color(0xFFFF453A)),
    ToastTone.info => (Icons.info_rounded, const Color(0xFF8E8E93)),
  };
  if (Get.isSnackbarOpen) Get.closeCurrentSnackbar();
  Get.snackbar(
    title,
    message,
    snackPosition: SnackPosition.BOTTOM,
    duration: duration,
    backgroundColor: const Color(0xFF1C1C1E),
    colorText: Colors.white,
    borderRadius: 16,
    margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
    padding: const EdgeInsets.fromLTRB(14, 12, 16, 12),
    icon: Icon(icon, color: color, size: 22),
    shouldIconPulse: false,
    boxShadows: [
      BoxShadow(
          color: Colors.black.withValues(alpha: 0.25),
          blurRadius: 24,
          offset: const Offset(0, 8)),
    ],
    titleText: Text(title,
        style: GoogleFonts.inter(
            fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white)),
    messageText: message.isEmpty
        ? const SizedBox.shrink()
        : Text(message,
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.inter(
                fontSize: 13, height: 1.35, color: const Color(0xFFC7C7CC))),
  );
}
