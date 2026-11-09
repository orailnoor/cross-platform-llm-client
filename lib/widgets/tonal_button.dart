import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Tonal sheet button — equal visual weight for each choice; colour carries
/// the meaning (neutral vs. destructive).
class TonalButton extends StatelessWidget {
  final String label;
  final Color color;
  final Color fill;
  final VoidCallback onTap;
  final double radius;

  const TonalButton({
    super.key,
    required this.label,
    required this.color,
    required this.fill,
    required this.onTap,
    this.radius = 12,
  });

  /// Neutral grey button matching the app's card surfaces.
  factory TonalButton.neutral(BuildContext context,
      {required String label, required VoidCallback onTap}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return TonalButton(
      label: label,
      onTap: onTap,
      color: isDark ? Colors.white : const Color(0xFF0B0B0C),
      fill: isDark
          ? Colors.white.withValues(alpha: 0.08)
          : const Color(0xFFF2F2F4),
    );
  }

  /// Soft red button for destructive actions.
  factory TonalButton.destructive(BuildContext context,
      {required String label,
      required VoidCallback onTap,
      double radius = 12}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return TonalButton(
      label: label,
      onTap: onTap,
      radius: radius,
      color: isDark ? const Color(0xFFFF453A) : const Color(0xFFE5342B),
      fill: (isDark ? const Color(0xFFFF453A) : const Color(0xFFFF3B30))
          .withValues(alpha: isDark ? 0.16 : 0.10),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: fill,
      borderRadius: BorderRadius.circular(radius),
      child: InkWell(
        borderRadius: BorderRadius.circular(radius),
        onTap: onTap,
        child: SizedBox(
          height: 48,
          child: Center(
            child: Text(label,
                style: GoogleFonts.inter(
                    fontSize: 15, fontWeight: FontWeight.w600, color: color)),
          ),
        ),
      ),
    );
  }
}
