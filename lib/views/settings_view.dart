import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import '../controllers/settings_controller.dart';
import '../core/colors.dart';
import '../services/inference_service.dart';
import '../services/device_info_service.dart';

class SettingsView extends GetView<SettingsController> {
  const SettingsView({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Settings', style: GoogleFonts.inter(fontWeight: FontWeight.w700)),
      ),
      body: Obx(() => ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // ── Appearance ────────────────────────
              _buildSectionHeader(context, 'APPEARANCE'),
              _buildThemeCard(),
              const SizedBox(height: 20),

              // ── Device Info ───────────────────────
              _buildSectionHeader(context, 'DEVICE'),
              _buildDeviceInfoCard(context),
              const SizedBox(height: 20),

              // ── Inference Mode ──────────────────
              _buildSectionHeader(context, 'INFERENCE MODE'),
              _buildInferenceModeCard(context),
              const SizedBox(height: 20),

              // ── Cloud API Config ────────────────
              if (controller.inferenceMode.value == 'cloud') ...[
                _buildSectionHeader(context, 'CLOUD PROVIDER'),
                _buildCloudProviderCard(context),
                const SizedBox(height: 12),
                _buildApiKeyField(context),
                const SizedBox(height: 12),
                _buildModelField(context),
                const SizedBox(height: 20),
              ],

              // ── Model Parameters (RAM-aware) ─────
              _buildSectionHeader(context, 'MODEL PARAMETERS'),
              _buildSmartSlider(
                context: context,
                label: 'Temperature',
                value: controller.temperature.value,
                min: 0.0,
                max: 2.0,
                divisions: 20,
                safeMax: 1.0,
                onChanged: (v) => controller.setTemperature(v),
                warningMessage: 'High temperature = unpredictable, rambling output!',
                icon: Icons.thermostat,
              ),
              _buildSmartSlider(
                context: context,
                label: 'Max Tokens',
                value: controller.maxTokens.value.toDouble(),
                min: 64,
                max: 4096,
                divisions: 63,
                safeMax: Get.find<DeviceInfoService>().maxSafeTokens.toDouble(),
                onChanged: (v) => controller.setMaxTokens(v.toInt()),
                displayValue: controller.maxTokens.value.toString(),
                warningMessage: 'Your phone only has ${Get.find<DeviceInfoService>().totalRamGB.value.toStringAsFixed(0)}GB RAM! This WILL crash! 💀',
                icon: Icons.token,
              ),
              _buildSmartSlider(
                context: context,
                label: 'Context Size',
                value: controller.contextSize.value.toDouble(),
                min: 512,
                max: 8192,
                divisions: 15,
                safeMax: Get.find<DeviceInfoService>().maxSafeContextSize.toDouble(),
                onChanged: (v) => controller.setContextSize(v.toInt()),
                displayValue: controller.contextSize.value.toString(),
                warningMessage: 'Context this large will eat all your RAM! Your phone will FREEZE! 🥶',
                icon: Icons.memory,
              ),
              const SizedBox(height: 20),



              // ── About ───────────────────────────
              _buildSectionHeader(context, 'ABOUT'),
              _buildAboutCard(context),
              const SizedBox(height: 40),
            ],
          )),
    );
  }

  Widget _buildThemeCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Column(
          children: [
            for (final mode in [ThemeMode.light, ThemeMode.dark, ThemeMode.system])
              RadioListTile<ThemeMode>(
                value: mode,
                groupValue: controller.themeMode.value,
                onChanged: (v) => controller.setThemeMode(v!),
                title: Text(
                  _themeModeName(mode),
                  style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w500),
                ),
                secondary: Icon(_themeModeIcon(mode), color: AppColors.textMuted),
                activeColor: AppColors.primary,
                dense: true,
              ),
          ],
        ),
      ),
    );
  }

  String _themeModeName(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return 'Light';
      case ThemeMode.dark:
        return 'Dark';
      case ThemeMode.system:
        return 'System Default';
    }
  }

  IconData _themeModeIcon(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return Icons.wb_sunny_outlined;
      case ThemeMode.dark:
        return Icons.dark_mode_outlined;
      case ThemeMode.system:
        return Icons.brightness_auto_outlined;
    }
  }

  Widget _buildSectionHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        title,
        style: GoogleFonts.inter(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: Theme.of(context).hintColor,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  Widget _buildInferenceModeCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Column(
          children: [
            RadioListTile<String>(
              value: 'local',
              groupValue: controller.inferenceMode.value,
              onChanged: (v) => controller.setInferenceMode(v!),
              title: Text('Local (On-Device)',
                  style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w500)),
              subtitle: Obx(() {
                final inference = Get.find<InferenceService>();
                return Text(
                  inference.isModelLoaded.value
                      ? 'Active: ${inference.loadedModelName.value}'
                      : 'No model loaded',
                  style: GoogleFonts.inter(fontSize: 12, color: Theme.of(context).hintColor),
                );
              }),
              activeColor: AppColors.primary,
              dense: true,
            ),
            RadioListTile<String>(
              value: 'cloud',
              groupValue: controller.inferenceMode.value,
              onChanged: (v) => controller.setInferenceMode(v!),
              title: Text('Cloud API',
                  style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w500)),
              subtitle: Text(
                controller.cloudProvider.value.toUpperCase(),
                style: GoogleFonts.inter(fontSize: 12, color: Theme.of(context).hintColor),
              ),
              activeColor: AppColors.secondary,
              dense: true,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCloudProviderCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: Column(
          children: [
            for (final provider in ['kimi', 'openai', 'anthropic', 'google'])
              RadioListTile<String>(
                value: provider,
                groupValue: controller.cloudProvider.value,
                onChanged: (v) => controller.setCloudProvider(v!),
                title: Text(
                  _providerName(provider),
                  style: GoogleFonts.inter(fontSize: 14, fontWeight: FontWeight.w500),
                ),
                activeColor: AppColors.primary,
                dense: true,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildApiKeyField(BuildContext context) {
    final provider = controller.cloudProvider.value;
    final textController = controller.apiKeyControllerFor(provider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('API Key',
                style: GoogleFonts.inter(
                    fontSize: 13, fontWeight: FontWeight.w500, color: Theme.of(context).textTheme.bodyMedium?.color ?? Colors.grey)),
            const SizedBox(height: 8),
            TextField(
              controller: textController,
              obscureText: true,
              style: GoogleFonts.firaCode(fontSize: 13),
              decoration: InputDecoration(
                hintText: 'Enter ${_providerName(provider)} API key',
                suffixIcon: IconButton(
                  icon: const Icon(Icons.save, size: 18),
                  onPressed: () {
                    controller.cancelApiKeyDebounce();
                    controller.setApiKey(provider, textController.text);
                  },
                ),
              ),
              onSubmitted: (v) {
                controller.cancelApiKeyDebounce();
                controller.setApiKey(provider, v);
              },
              onChanged: (v) {
                controller.debouncedSetApiKey(provider, v);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModelField(BuildContext context) {
    final provider = controller.cloudProvider.value;
    final textController = controller.modelControllerFor(provider);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Model Name',
                style: GoogleFonts.inter(
                    fontSize: 13, fontWeight: FontWeight.w500, color: Theme.of(context).textTheme.bodyMedium?.color ?? Colors.grey)),
            const SizedBox(height: 8),
            TextField(
              controller: textController,
              style: GoogleFonts.firaCode(fontSize: 13),
              decoration: InputDecoration(
                hintText: 'e.g., gpt-4o-mini',
                suffixIcon: IconButton(
                  icon: const Icon(Icons.save, size: 18),
                  onPressed: () {
                    controller.cancelModelDebounce();
                    controller.setCloudModel(provider, textController.text);
                  },
                ),
              ),
              onSubmitted: (v) {
                controller.cancelModelDebounce();
                controller.setCloudModel(provider, v);
              },
              onChanged: (v) {
                controller.debouncedSetCloudModel(provider, v);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDeviceInfoCard(BuildContext context) {
    return Obx(() {
      final device = Get.find<DeviceInfoService>();
      final Color tierColor;
      final IconData tierIcon;
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

      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: tierColor.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(tierIcon, color: tierColor, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      device.tierDescription,
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Available: ${device.availableRamGB.value.toStringAsFixed(1)}GB · '
                      'Context: ${device.recommendedContextSize} · '
                      'Tokens: ${device.recommendedMaxTokens}',
                      style: GoogleFonts.inter(
                        fontSize: 11,
                        color: Theme.of(context).hintColor,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    });
  }

  Widget _buildSmartSlider({
    required BuildContext context,
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required double safeMax,
    required ValueChanged<double> onChanged,
    required String warningMessage,
    required IconData icon,
    String? displayValue,
  }) {
    final isOverLimit = value > safeMax;
    final dangerLevel = safeMax < max
        ? ((value - safeMax) / (max - safeMax)).clamp(0.0, 1.0)
        : 0.0;
    final sliderColor = isOverLimit
        ? Color.lerp(AppColors.warning, AppColors.error, dangerLevel)!
        : AppColors.primary;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: isOverLimit
            ? BorderSide(
                color: sliderColor.withOpacity(0.5),
                width: 1.5,
              )
            : BorderSide.none,
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 16, color: sliderColor),
                const SizedBox(width: 8),
                Text(label,
                    style: GoogleFonts.inter(
                        fontSize: 13, fontWeight: FontWeight.w500)),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: sliderColor.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    displayValue ?? value.toStringAsFixed(2),
                    style: GoogleFonts.firaCode(
                      fontSize: 13,
                      color: sliderColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
            // Safe limit indicator
            if (safeMax < max)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Recommended max: ${safeMax.toInt() > 0 ? safeMax.toInt().toString() : safeMax.toStringAsFixed(1)}',
                  style: GoogleFonts.inter(
                    fontSize: 10,
                    color: Theme.of(context).hintColor,
                  ),
                ),
              ),
            Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              onChanged: (v) {
                // VIBRATE when crossing into danger zone!
                if (v > safeMax && value <= safeMax) {
                  // Entering danger zone — heavy vibration
                  HapticFeedback.heavyImpact();
                  Future.delayed(const Duration(milliseconds: 100), () =>
                      HapticFeedback.heavyImpact());
                  Future.delayed(const Duration(milliseconds: 200), () =>
                      HapticFeedback.heavyImpact());
                  Get.snackbar(
                    '⚠️ DANGER ZONE',
                    warningMessage,
                    snackPosition: SnackPosition.BOTTOM,
                    backgroundColor: AppColors.error.withOpacity(0.9),
                    colorText: Colors.white,
                    icon: const Icon(Icons.warning_amber_rounded,
                        color: Colors.white, size: 28),
                    duration: const Duration(seconds: 4),
                    margin: const EdgeInsets.all(12),
                    borderRadius: 12,
                  );
                } else if (v > safeMax) {
                  // Already in danger zone — light vibration on each tick
                  HapticFeedback.mediumImpact();
                }
                onChanged(v);
              },
              activeColor: sliderColor,
              inactiveColor: Theme.of(context).colorScheme.surfaceContainerHighest,
            ),
            // Danger warning banner
            if (isOverLimit)
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: sliderColor.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: sliderColor.withOpacity(0.3)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.warning_amber_rounded,
                        color: sliderColor, size: 14),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        warningMessage,
                        style: GoogleFonts.inter(
                          fontSize: 10,
                          color: sliderColor,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }




  Widget _buildAboutCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'AI Chat',
              style: GoogleFonts.inter(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Intelligent AI Assistant\nv1.0.0 · by orailnoor',
              style: GoogleFonts.inter(fontSize: 12, color: Theme.of(context).hintColor),
            ),
          ],
        ),
      ),
    );
  }

  String _providerName(String key) {
    switch (key) {
      case 'openai':
        return 'OpenAI';
      case 'anthropic':
        return 'Anthropic';
      case 'google':
        return 'Google Gemini';
      case 'kimi':
        return 'Kimi (Moonshot)';
      default:
        return key;
    }
  }
}
