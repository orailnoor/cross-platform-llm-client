import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import '../controllers/settings_controller.dart';
import '../core/colors.dart';
import '../core/constants.dart';
import '../services/inference_service.dart';
import '../services/local_image_service.dart';
import '../services/device_info_service.dart';
import '../services/device_info_native.dart' as platform_info;
import 'log_view.dart';

class SettingsView extends GetView<SettingsController> {
  const SettingsView({super.key});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor: isDark ? Colors.black : const Color(0xFFF2F2F7),
      appBar: AppBar(
        backgroundColor: isDark ? Colors.black : const Color(0xFFF2F2F7),
        title: Text('Settings',
            style:
                GoogleFonts.inter(fontWeight: FontWeight.w700, fontSize: 34)),
        toolbarHeight: 56,
      ),
      body: Obx(() => ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              const SizedBox(height: 8),
              _sectionLabel(context, 'APPEARANCE'),
              _appleGroupedCard(context, isDark, children: [
                for (final mode in [
                  ThemeMode.light,
                  ThemeMode.dark,
                  ThemeMode.system
                ])
                  _appleListTile(
                    context,
                    isDark,
                    leading: Icon(_themeModeIcon(mode),
                        size: 20, color: Theme.of(context).hintColor),
                    title: _themeModeName(mode),
                    trailing: controller.themeMode.value == mode
                        ? Icon(Icons.check,
                            size: 18,
                            color: isDark
                                ? const Color(0xFF0A84FF)
                                : AppColors.primary)
                        : null,
                    showDivider: mode != ThemeMode.system,
                    onTap: () => controller.setThemeMode(mode),
                  ),
              ]),
              const SizedBox(height: 24),
              _sectionLabel(context, 'DIAGNOSTICS'),
              _appleGroupedCard(context, isDark, children: [
                _appleListTile(
                  context,
                  isDark,
                  leading:
                      _iconBox(const Color(0xFF5AC8FA), Icons.article_outlined),
                  title: 'Logs',
                  subtitle: 'View errors, warnings, and debug details',
                  trailing: const Icon(Icons.chevron_right, size: 18),
                  showDivider: false,
                  onTap: () => Get.to(() => const LogView()),
                ),
              ]),
              const SizedBox(height: 24),
              _sectionLabel(context, 'DEVICE'),
              _buildDeviceCard(context, isDark),
              const SizedBox(height: 24),
              _sectionLabel(context, 'INFERENCE MODE'),
              _appleGroupedCard(context, isDark, children: [
                _appleListTile(
                  context,
                  isDark,
                  leading:
                      _iconBox(AppColors.success, Icons.phone_iphone_rounded),
                  title: 'Local (On-Device)',
                  subtitle: _localSubtitle(),
                  trailing: controller.inferenceMode.value == 'local'
                      ? Icon(Icons.check,
                          size: 18,
                          color: isDark
                              ? const Color(0xFF0A84FF)
                              : AppColors.primary)
                      : null,
                  showDivider: true,
                  onTap: () => controller.setInferenceMode('local'),
                ),
                _appleListTile(
                  context,
                  isDark,
                  leading: _iconBox(AppColors.secondary, Icons.cloud_outlined),
                  title: 'Cloud API',
                  subtitle: controller.cloudProvider.value.toUpperCase(),
                  trailing: controller.inferenceMode.value == 'cloud'
                      ? Icon(Icons.check,
                          size: 18,
                          color: isDark
                              ? const Color(0xFF0A84FF)
                              : AppColors.primary)
                      : null,
                  showDivider: false,
                  onTap: () => controller.setInferenceMode('cloud'),
                ),
              ]),
              const SizedBox(height: 24),
              _sectionLabel(context, 'SYSTEM PROMPT'),
              _appleGroupedCard(context, isDark, children: [
                Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Applies to local and cloud models',
                            style: GoogleFonts.inter(
                                fontSize: 13,
                                color: Theme.of(context).hintColor)),
                        const SizedBox(height: 10),
                        TextField(
                          controller: controller.globalSystemPromptController,
                          minLines: 3,
                          maxLines: 6,
                          style: GoogleFonts.inter(fontSize: 14),
                          decoration: InputDecoration(
                            hintText: AppConstants.systemPrompt,
                            suffixIcon: IconButton(
                                icon: const Icon(Icons.check_circle_outline,
                                    size: 20),
                                onPressed: () =>
                                    controller.setGlobalSystemPrompt(controller
                                        .globalSystemPromptController.text)),
                          ),
                          onSubmitted: (v) =>
                              controller.setGlobalSystemPrompt(v),
                        ),
                      ]),
                ),
              ]),
              const SizedBox(height: 24),
              _sectionLabel(context, 'MODEL PARAMETERS'),
              _buildLiteRtCard(context, isDark),
              const SizedBox(height: 10),
              _buildSlider(context, isDark,
                  label: 'Temperature',
                  value: controller.temperature.value,
                  min: 0.0,
                  max: 2.0,
                  divisions: 20,
                  safeMax: 1.0,
                  onChanged: (v) => controller.setTemperature(v),
                  icon: Icons.thermostat_rounded,
                  warning: 'High temperature = unpredictable output!'),
              const SizedBox(height: 10),
              _buildSlider(context, isDark,
                  label: 'Max Tokens',
                  value: controller.maxTokens.value.toDouble(),
                  min: 64,
                  max: 4096,
                  divisions: 63,
                  safeMax:
                      Get.find<DeviceInfoService>().maxSafeTokens.toDouble(),
                  onChanged: (v) => controller.setMaxTokens(v.toInt()),
                  displayValue: controller.maxTokens.value.toString(),
                  icon: Icons.tag_rounded,
                  warning: 'Your phone may crash with this value!'),
              const SizedBox(height: 10),
              _buildSlider(context, isDark,
                  label: 'Context Size',
                  value: controller.contextSize.value.toDouble(),
                  min: 512,
                  max: 8192,
                  divisions: 15,
                  safeMax: Get.find<DeviceInfoService>()
                      .maxSafeContextSize
                      .toDouble(),
                  onChanged: (v) => controller.setContextSize(v.toInt()),
                  displayValue: controller.contextSize.value.toString(),
                  icon: Icons.memory_rounded,
                  warning: 'Context this large will eat all your RAM!'),
              const SizedBox(height: 10),
              _buildSlider(context, isDark,
                  label: 'Image Gen Steps',
                  value: controller.imageSteps.value.toDouble(),
                  min: 1,
                  max: 20,
                  divisions: 19,
                  safeMax: 8,
                  onChanged: (v) => controller.setImageSteps(v.toInt()),
                  displayValue: controller.imageSteps.value.toString(),
                  icon: Icons.image_rounded,
                  warning: 'More steps = better quality but MUCH slower!'),
              const SizedBox(height: 24),
              _sectionLabel(context, 'ABOUT'),
              _appleGroupedCard(context, isDark, children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(children: [
                    Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                            gradient: LinearGradient(colors: [
                              isDark
                                  ? const Color(0xFF0A84FF)
                                  : AppColors.primary,
                              AppColors.secondary
                            ]),
                            borderRadius: BorderRadius.circular(12)),
                        child: const Icon(Icons.auto_awesome_rounded,
                            color: Colors.white, size: 22)),
                    const SizedBox(width: 14),
                    Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('MyAI',
                              style: GoogleFonts.inter(
                                  fontSize: 17, fontWeight: FontWeight.w600)),
                          const SizedBox(height: 2),
                          Text('v1.0.3',
                              style: GoogleFonts.inter(
                                  fontSize: 13,
                                  color: Theme.of(context).hintColor)),
                        ]),
                  ]),
                ),
              ]),
              const SizedBox(height: 40),
            ],
          )),
    );
  }

  // ── Apple grouped card container ──
  Widget _appleGroupedCard(BuildContext context, bool isDark,
      {required List<Widget> children}) {
    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1C1C1E) : Colors.white,
        borderRadius: BorderRadius.circular(14),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(mainAxisSize: MainAxisSize.min, children: children),
    );
  }

  // ── Apple-style list tile ──
  Widget _appleListTile(
    BuildContext context,
    bool isDark, {
    Widget? leading,
    required String title,
    String? subtitle,
    Widget? trailing,
    bool showDivider = true,
    VoidCallback? onTap,
  }) {
    return Column(children: [
      InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(children: [
            if (leading != null) ...[leading, const SizedBox(width: 14)],
            Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                  Text(title,
                      style: GoogleFonts.inter(
                          fontSize: 15,
                          fontWeight: FontWeight.w400,
                          color: isDark ? Colors.white : Colors.black)),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(subtitle,
                        style: GoogleFonts.inter(
                            fontSize: 13, color: Theme.of(context).hintColor))
                  ],
                ])),
            if (trailing != null) trailing,
          ]),
        ),
      ),
      if (showDivider)
        Divider(
            height: 0.5,
            indent: leading != null ? 58 : 16,
            color: isDark
                ? Colors.white.withValues(alpha: 0.06)
                : Colors.black.withValues(alpha: 0.06)),
    ]);
  }

  Widget _iconBox(Color color, IconData icon) {
    return Container(
        width: 30,
        height: 30,
        decoration:
            BoxDecoration(color: color, borderRadius: BorderRadius.circular(7)),
        child: Icon(icon, size: 17, color: Colors.white));
  }

  Widget _sectionLabel(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 16, bottom: 6),
      child: Text(title,
          style: GoogleFonts.inter(
              fontSize: 13,
              fontWeight: FontWeight.w400,
              color: Theme.of(context).hintColor)),
    );
  }

  String _localSubtitle() {
    final inf = Get.find<InferenceService>();
    final localImage = Get.find<LocalImageService>();
    if (inf.isModelLoaded.value) {
      return 'Active: ${inf.loadedModelName.value}';
    } else if (localImage.isModelLoaded.value) {
      return 'Active: ${localImage.loadedModelName.value}';
    }
    return 'No model loaded';
  }

  Widget _buildDeviceCard(BuildContext context, bool isDark) {
    return Obx(() {
      final device = Get.find<DeviceInfoService>();
      Color tierColor;
      IconData tierIcon;
      switch (device.deviceTier.value) {
        case 'low':
          tierColor = AppColors.error;
          tierIcon = Icons.battery_alert;
          break;
        case 'mid':
          tierColor = AppColors.warning;
          tierIcon = Icons.phone_android;
          break;
        case 'high':
          tierColor = AppColors.success;
          tierIcon = Icons.smartphone;
          break;
        case 'ultra':
          tierColor = AppColors.primary;
          tierIcon = Icons.rocket_launch;
          break;
        default:
          tierColor = Theme.of(context).hintColor;
          tierIcon = Icons.phone_android;
      }

      final soc = device.socFamily.value;
      final quantWarning = soc.quantWarning;

      return _appleGroupedCard(context, isDark, children: [
        Padding(
            padding: const EdgeInsets.all(16),
            child: Row(children: [
              _iconBox(tierColor, tierIcon),
              const SizedBox(width: 14),
              Expanded(
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                    Text(device.tierDescription,
                        style: GoogleFonts.inter(
                            fontSize: 15, fontWeight: FontWeight.w500)),
                    const SizedBox(height: 2),
                    Text(
                        'Available: ${device.availableRamGB.value.toStringAsFixed(1)}GB · Context: ${device.recommendedContextSize} · Tokens: ${device.recommendedMaxTokens}',
                        style: GoogleFonts.inter(
                            fontSize: 12, color: Theme.of(context).hintColor)),
                  ])),
            ])),
        // SoC + quantization recommendation
        if (soc != platform_info.SocFamily.unknown) ...[
          const Divider(height: 1, indent: 16, endIndent: 16),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: Row(children: [
              _iconBox(const Color(0xFF5856D6), Icons.memory_outlined),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(soc.displayName,
                        style: GoogleFonts.inter(
                            fontSize: 14, fontWeight: FontWeight.w500)),
                    const SizedBox(height: 3),
                    Text('Recommended: ${soc.recommendedQuant}',
                        style: GoogleFonts.inter(
                            fontSize: 12,
                            color: quantWarning != null
                                ? const Color(0xFFFF9500)
                                : Theme.of(context).hintColor)),
                  ],
                ),
              ),
            ]),
          ),
        ],
        // Warning banner for problematic SoCs
        if (quantWarning != null) ...[
          Container(
            margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFFF9500).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.warning_amber_rounded,
                    size: 16, color: Color(0xFFFF9500)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(quantWarning,
                      style: GoogleFonts.inter(
                        fontSize: 12,
                        color: const Color(0xFFFF9500),
                        fontWeight: FontWeight.w500,
                      )),
                ),
              ],
            ),
          ),
        ],
      ]);
    });
  }

  Widget _buildLiteRtCard(BuildContext context, bool isDark) {
    final modes = [
      (
        value: 'auto_fast',
        title: 'Auto Fast',
        subtitle: 'Try GPU first, then CPU fallback',
        icon: Icons.auto_awesome_rounded
      ),
      (
        value: 'gpu_fast',
        title: 'GPU Fast',
        subtitle: 'Maximum speed, may crash on some devices',
        icon: Icons.bolt_rounded
      ),
      (
        value: 'cpu_safe',
        title: 'CPU Safe',
        subtitle: 'Stable mode with lower speed',
        icon: Icons.shield_outlined
      ),
    ];
    return _appleGroupedCard(context, isDark, children: [
      for (var i = 0; i < modes.length; i++)
        _appleListTile(
          context,
          isDark,
          leading: _iconBox(
              isDark ? const Color(0xFF0A84FF) : AppColors.primary,
              modes[i].icon),
          title: modes[i].title,
          subtitle: modes[i].subtitle,
          trailing: controller.liteRtPerformanceMode.value == modes[i].value
              ? Icon(Icons.check,
                  size: 18,
                  color: isDark ? const Color(0xFF0A84FF) : AppColors.primary)
              : null,
          showDivider: i < modes.length - 1,
          onTap: () => controller.setLiteRtPerformanceMode(modes[i].value),
        ),
    ]);
  }

  Widget _buildSlider(
    BuildContext context,
    bool isDark, {
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required double safeMax,
    required ValueChanged<double> onChanged,
    required IconData icon,
    required String warning,
    String? displayValue,
  }) {
    final isOver = value > safeMax;
    final danger = safeMax < max
        ? ((value - safeMax) / (max - safeMax)).clamp(0.0, 1.0)
        : 0.0;
    final accent = isOver
        ? Color.lerp(AppColors.warning, AppColors.error, danger)!
        : (isDark ? const Color(0xFF0A84FF) : AppColors.primary);

    return _appleGroupedCard(context, isDark, children: [
      Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(icon, size: 16, color: accent),
              const SizedBox(width: 8),
              Text(label,
                  style: GoogleFonts.inter(
                      fontSize: 15, fontWeight: FontWeight.w400)),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6)),
                child: Text(displayValue ?? value.toStringAsFixed(2),
                    style: GoogleFonts.inter(
                        fontSize: 13,
                        color: accent,
                        fontWeight: FontWeight.w600)),
              ),
            ]),
            if (safeMax < max)
              Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                      'Recommended max: ${safeMax.toInt() > 0 ? safeMax.toInt().toString() : safeMax.toStringAsFixed(1)}',
                      style: GoogleFonts.inter(
                          fontSize: 12, color: Theme.of(context).hintColor))),
            Slider(
                value: value.clamp(min, max),
                min: min,
                max: max,
                divisions: divisions,
                activeColor: accent,
                onChanged: (v) {
                  if (v > safeMax && value <= safeMax) {
                    HapticFeedback.heavyImpact();
                    Get.snackbar('⚠️ Warning', warning,
                        snackPosition: SnackPosition.BOTTOM,
                        backgroundColor: AppColors.error.withValues(alpha: 0.9),
                        colorText: Colors.white,
                        duration: const Duration(seconds: 3),
                        margin: const EdgeInsets.all(12));
                  } else if (v > safeMax) {
                    HapticFeedback.mediumImpact();
                  }
                  onChanged(v);
                }),
            if (isOver)
              Container(
                  margin: const EdgeInsets.only(bottom: 10),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(8)),
                  child: Row(children: [
                    Icon(Icons.warning_amber_rounded, size: 14, color: accent),
                    const SizedBox(width: 6),
                    Expanded(
                        child: Text(warning,
                            style: GoogleFonts.inter(
                                fontSize: 12,
                                color: accent,
                                fontWeight: FontWeight.w400))),
                  ])),
          ])),
    ]);
  }

  String _themeModeName(ThemeMode m) => m == ThemeMode.light
      ? 'Light'
      : m == ThemeMode.dark
          ? 'Dark'
          : 'System Default';
  IconData _themeModeIcon(ThemeMode m) => m == ThemeMode.light
      ? Icons.wb_sunny_outlined
      : m == ThemeMode.dark
          ? Icons.dark_mode_outlined
          : Icons.brightness_auto_outlined;
}
