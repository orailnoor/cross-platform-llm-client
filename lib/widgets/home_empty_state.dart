import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import '../controllers/chat_controller.dart';
import '../controllers/home_controller.dart';
import '../controllers/model_controller.dart';
import '../controllers/settings_controller.dart';
import '../ffi/sd_ffi_bindings.dart';
import '../services/cluster_service.dart';
import '../services/inference_service.dart';
import '../services/local_image_service.dart';
import '../core/haptics.dart';

/// Landing screen shown in the Chat tab before the first message is sent.
///
/// Layout, top to bottom: the model that will answer (with the one action
/// needed to get it ready), a centred greeting, and prompt starters. Past
/// conversations live in the sidebar (see `ChatDrawer`).
class HomeEmptyState extends StatelessWidget {
  const HomeEmptyState({super.key});

  @override
  Widget build(BuildContext context) {
    final t = _HomeTokens.of(context);
    return LayoutBuilder(builder: (context, box) {
      // Keep a readable column on tablets / desktop.
      final hPad = box.maxWidth > 640 ? (box.maxWidth - 600) / 2 : 20.0;
      // While typing, drop the suggestions and icon so nothing gets clipped
      // behind the composer — the greeting alone stays centred.
      final typing = View.of(context).viewInsets.bottom > 0;
      // Model up top, greeting centred, suggestions just above the composer.
      return SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(hPad, 8, hPad, 8),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: box.maxHeight - 16),
          child: IntrinsicHeight(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _ModelCard(t: t),
                const Spacer(),
                const SizedBox(height: 32),
                _Greeting(t: t, compact: typing),
                const SizedBox(height: 32),
                const Spacer(),
                if (!typing)
                  Obx(() {
                    final settings = Get.find<SettingsController>();
                    final models = Get.find<ModelController>();
                    final needsModel =
                        settings.inferenceMode.value == 'local' &&
                            models.downloadedCount == 0;
                    return needsModel ? _GettingStarted(t: t) : _Starters(t: t);
                  }),
              ],
            ),
          ),
        ),
      );
    });
  }
}

// ── Tokens ──────────────────────────────────────────────────────────────

class _HomeTokens {
  final bool isDark;
  final Color text;
  final Color muted;
  final Color faint;
  final Color accent;
  final Color card;
  final Color cardPressed;
  final Color hairline;
  final Color outline;
  final Color green;
  final Color orange;

  const _HomeTokens({
    required this.isDark,
    required this.text,
    required this.muted,
    required this.faint,
    required this.accent,
    required this.card,
    required this.cardPressed,
    required this.hairline,
    required this.outline,
    required this.green,
    required this.orange,
  });

  factory _HomeTokens.of(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return _HomeTokens(
      isDark: isDark,
      text: isDark ? Colors.white : const Color(0xFF0B0B0C),
      muted: isDark ? const Color(0xFF8E8E93) : const Color(0xFF6E6E73),
      faint: isDark ? const Color(0xFF5A5A5F) : const Color(0xFFAEAEB2),
      accent: isDark ? const Color(0xFF0A84FF) : const Color(0xFF007AFF),
      card: isDark ? const Color(0xFF141416) : const Color(0xFFF5F5F7),
      cardPressed: isDark ? const Color(0xFF1E1E21) : const Color(0xFFEBEBED),
      hairline: isDark
          ? Colors.white.withValues(alpha: 0.07)
          : Colors.black.withValues(alpha: 0.06),
      outline: isDark
          ? Colors.white.withValues(alpha: 0.14)
          : Colors.black.withValues(alpha: 0.10),
      green: isDark ? const Color(0xFF30D158) : const Color(0xFF28A745),
      orange: isDark ? const Color(0xFFFF9F0A) : const Color(0xFFE08600),
    );
  }

  TextStyle get sectionLabel => GoogleFonts.inter(
      fontSize: 13,
      fontWeight: FontWeight.w600,
      color: muted,
      letterSpacing: -0.08);
}

/// Card surface with a pressed state instead of a ripple — calmer and closer
/// to native iOS list cells.
class _Pressable extends StatefulWidget {
  final _HomeTokens t;
  final VoidCallback? onTap;
  final Widget child;
  final EdgeInsetsGeometry padding;

  const _Pressable({
    required this.t,
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(16),
  });

  @override
  State<_Pressable> createState() => _PressableState();
}

class _PressableState extends State<_Pressable> {
  bool _down = false;

  void _set(bool v) {
    if (widget.onTap == null || _down == v) return;
    setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (_) => _set(true),
      onTapUp: (_) => _set(false),
      onTapCancel: () => _set(false),
      onTap: widget.onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: widget.padding,
        decoration: BoxDecoration(
          // Outlined, like the suggestion pills — the composer is the only
          // filled surface on the home screen.
          color: _down ? widget.t.cardPressed : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: widget.t.outline),
        ),
        child: widget.child,
      ),
    );
  }
}

// ── Greeting ────────────────────────────────────────────────────────────

class _Greeting extends StatelessWidget {
  final _HomeTokens t;
  final bool compact;
  const _Greeting({required this.t, this.compact = false});

  String get _salutation {
    final h = DateTime.now().hour;
    if (h < 5) return 'Up late?';
    if (h < 12) return 'Good morning,';
    if (h < 17) return 'Good afternoon,';
    return 'Good evening,';
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      if (!compact) ...[
        Image.asset('assets/icons/appicon.png', width: 44, height: 44),
        const SizedBox(height: 18),
      ],
      Text(
        "$_salutation\nwhat's on your mind?",
        textAlign: TextAlign.center,
        style: GoogleFonts.inter(
          fontSize: compact ? 24 : 28,
          height: 1.25,
          fontWeight: FontWeight.w400,
          letterSpacing: -0.7,
          color: t.text.withValues(alpha: 0.88),
        ),
      ),
    ]);
  }
}

String providerLabel(SettingsController s) {
  switch (s.cloudProvider.value) {
    case 'openai':
      return 'OpenAI';
    case 'anthropic':
      return 'Anthropic';
    case 'google':
      return 'Google';
    case 'stability':
      return 'Stability AI';
    case 'nvidia':
      return 'NVIDIA';
    case 'openrouter':
      return 'OpenRouter';
    case 'deepseek':
      return 'DeepSeek';
    case 'kimi':
      return 'Kimi';
    case 'custom':
      final n = s.customCloudName.value.trim();
      return n.isEmpty ? 'a custom endpoint' : n;
    default:
      return 'the cloud';
  }
}

String _prettyModel(String name) => name.replaceAll(
    RegExp(r'\.(gguf|litertlm|task|bin)$', caseSensitive: false), '');

// ── Model card ──────────────────────────────────────────────────────────

enum _ModelState { noModels, idle, loading, readyText, readyImage, cloud }

class _ModelCard extends StatelessWidget {
  final _HomeTokens t;
  const _ModelCard({required this.t});

  void _openModels() {
    Haptics.selectionClick();
    Get.find<HomeController>().changeTab(1);
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final settings = Get.find<SettingsController>();
      final models = Get.find<ModelController>();
      final inf = Get.find<InferenceService>();
      final img = Get.find<LocalImageService>();

      final _ModelState state;
      if (settings.inferenceMode.value != 'local') {
        state = _ModelState.cloud;
      } else if (inf.isLoadingModel.value) {
        state = _ModelState.loading;
      } else if (inf.isModelLoaded.value) {
        state = _ModelState.readyText;
      } else if (img.isModelLoaded.value) {
        state = _ModelState.readyImage;
      } else if (models.downloadedCount == 0) {
        state = _ModelState.noModels;
      } else {
        state = _ModelState.idle;
      }

      late final IconData icon;
      late final String title;
      late final String meta;
      late final Color dot;
      Widget? action;

      switch (state) {
        case _ModelState.cloud:
          final m = settings.selectedCloudModelName;
          icon = Icons.cloud_outlined;
          title = m.isEmpty ? 'No model selected' : m;
          meta = providerLabel(settings);
          dot = t.accent;
          action = _ActionChip(t: t, label: 'Change', onTap: _openModels);
        case _ModelState.loading:
          icon = Icons.memory_rounded;
          title = _prettyModel(inf.loadedModelName.value.isNotEmpty
              ? inf.loadedModelName.value
              : models.lastLoadedModelName);
          meta = 'Loading · ${(inf.modelLoadProgress.value * 100).round()}%';
          dot = t.orange;
        case _ModelState.readyText:
          final runtime =
              inf.loadedModelRuntime.value == 'litert' ? 'LiteRT' : 'GGUF';
          icon = Icons.memory_rounded;
          title = _prettyModel(inf.loadedModelName.value);
          meta = [
            'Ready',
            Get.isRegistered<ClusterService>()
              ? Get.find<ClusterService>().splitSummary ??
                  (inf.isGpuAccelerated.value ? 'GPU' : 'CPU')
              : (inf.isGpuAccelerated.value ? 'GPU' : 'CPU'),
            runtime,
          ].join(' · ');
          dot = t.green;
          action = _ActionChip(t: t, label: 'Switch', onTap: _openModels);
        case _ModelState.readyImage:
          final backend = img.currentBackend.value;
          icon = Icons.image_outlined;
          title = _prettyModel(img.loadedModelName.value);
          meta =
              'Ready · Image generation · ${backend == Backend.cpu ? 'CPU' : backend.displayName.split(' ').first}';
          dot = t.green;
          action = _ActionChip(t: t, label: 'Switch', onTap: _openModels);
        case _ModelState.noModels:
          icon = Icons.download_rounded;
          title = 'No model on this device';
          meta = 'Download one to chat offline';
          dot = t.orange;
          action = _ActionChip(
              t: t, label: 'Browse', primary: true, onTap: _openModels);
        case _ModelState.idle:
          final last =
              models.canLoadLastModel ? models.lastLoadedModelName : '';
          icon = Icons.memory_rounded;
          title = last.isEmpty ? 'No model loaded' : _prettyModel(last);
          meta = last.isEmpty
              ? '${models.downloadedCount} downloaded'
              : 'Not loaded · last used';
          dot = t.faint;
          action = last.isEmpty
              ? _ActionChip(
                  t: t, label: 'Choose', primary: true, onTap: _openModels)
              : _ActionChip(
                  t: t,
                  label: 'Load',
                  primary: true,
                  onTap: () {
                    Haptics.lightImpact();
                    models.loadModel(last);
                  });
      }

      return _Pressable(
        t: t,
        onTap: _openModels,
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
        child: Column(children: [
          Row(children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: t.isDark
                    ? Colors.white.withValues(alpha: 0.08)
                    : Colors.black.withValues(alpha: 0.05),
              ),
              child: Icon(icon, size: 20, color: t.text.withValues(alpha: 0.8)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: GoogleFonts.inter(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.2,
                            color: t.text)),
                    const SizedBox(height: 3),
                    Row(children: [
                      Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                              color: dot, shape: BoxShape.circle)),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(meta,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: GoogleFonts.inter(
                                fontSize: 12.5,
                                color: t.muted,
                                fontFeatures: const [
                                  FontFeature.tabularFigures()
                                ])),
                      ),
                    ]),
                  ]),
            ),
            if (action != null) ...[const SizedBox(width: 10), action],
          ]),
          if (state == _ModelState.loading) ...[
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(
                value: inf.modelLoadProgress.value,
                minHeight: 3,
                color: t.accent,
                backgroundColor: t.hairline,
              ),
            ),
          ],
        ]),
      );
    });
  }
}

class _ActionChip extends StatelessWidget {
  final _HomeTokens t;
  final String label;
  final bool primary;
  final VoidCallback onTap;

  const _ActionChip({
    required this.t,
    required this.label,
    required this.onTap,
    this.primary = false,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: primary
          ? t.accent
          : (t.isDark
              ? Colors.white.withValues(alpha: 0.08)
              : Colors.black.withValues(alpha: 0.05)),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          child: Text(label,
              style: GoogleFonts.inter(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: primary ? Colors.white : t.text)),
        ),
      ),
    );
  }
}

// ── Starters ────────────────────────────────────────────────────────────

class _Starter {
  final IconData icon;
  final String label;
  final String prompt;
  const _Starter(this.icon, this.label, this.prompt);
}

const _textStarters = [
  _Starter(Icons.lightbulb_outline_rounded, 'Explain quantum computing simply',
      'Explain quantum computing simply, like I\'m new to it.'),
  _Starter(Icons.mail_outline_rounded, 'Write a polite follow-up email',
      'Write a short, polite follow-up email to someone who hasn\'t replied in a week.'),
  _Starter(Icons.flight_takeoff_rounded, 'Plan a 3-day trip to Tokyo',
      'Plan a relaxed 3-day trip to Tokyo with food and sightseeing.'),
];

const _imageStarters = [
  _Starter(Icons.landscape_outlined, 'A mountain lake at golden hour',
      'Mountain lake at golden hour, wide shot, photorealistic'),
  _Starter(Icons.person_outline_rounded, 'A portrait in soft studio light',
      'Portrait of a person, soft studio lighting, 85mm, detailed'),
  _Starter(Icons.brush_outlined, 'A flat editorial illustration',
      'Flat editorial illustration of a city street, muted palette'),
];

/// Three tappable prompt pills. Sends right away when a model is ready;
/// otherwise opens Models so the user can load one.
class _Starters extends StatelessWidget {
  final _HomeTokens t;
  const _Starters({required this.t});

  void _use(_Starter s, {required bool ready}) {
    Haptics.selectionClick();
    // No local model yet: the composer is disabled, so go pick one.
    if (!ready) {
      Get.find<HomeController>().changeTab(1);
      return;
    }
    final chat = Get.find<ChatController>();
    chat.textController.value = TextEditingValue(
      text: s.prompt,
      selection: TextSelection.collapsed(offset: s.prompt.length),
    );
    chat.inputText.value = s.prompt;
    chat.sendMessage();
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final inf = Get.find<InferenceService>();
      final img = Get.find<LocalImageService>();
      final isLocal =
          Get.find<SettingsController>().inferenceMode.value == 'local';
      final imageMode =
          isLocal && img.isModelLoaded.value && !inf.isModelLoaded.value;
      final ready =
          !isLocal || inf.isModelLoaded.value || img.isModelLoaded.value;
      final items = imageMode ? _imageStarters : _textStarters;

      return Column(crossAxisAlignment: CrossAxisAlignment.center, children: [
        for (final s in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Material(
              color: Colors.transparent,
              shape: StadiumBorder(side: BorderSide(color: t.outline)),
              child: InkWell(
                customBorder: const StadiumBorder(),
                onTap: () => _use(s, ready: ready),
                splashFactory: NoSplash.splashFactory,
                highlightColor: t.cardPressed,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 10, 18, 10),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(s.icon, size: 18, color: t.muted),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(s.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: GoogleFonts.inter(
                              fontSize: 15,
                              letterSpacing: -0.15,
                              color: t.text.withValues(alpha: 0.9))),
                    ),
                  ]),
                ),
              ),
            ),
          ),
      ]);
    });
  }
}

// ── Getting started (no models yet) ─────────────────────────────────────

class _GettingStarted extends StatelessWidget {
  final _HomeTokens t;
  const _GettingStarted({required this.t});

  @override
  Widget build(BuildContext context) {
    const steps = [
      ('Pick a model', 'Smaller models are faster; larger ones are smarter.'),
      ('Download it once', 'Usually 0.5–3 GB. Wi-Fi recommended.'),
      ('Chat offline', 'Runs on this device. No account, no server.'),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('How it works', style: t.sectionLabel),
      const SizedBox(height: 14),
      for (var i = 0; i < steps.length; i++)
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 24,
              height: 24,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: t.faint, width: 1),
              ),
              child: Text('${i + 1}',
                  style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: t.muted)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 2),
                    Text(steps[i].$1,
                        style: GoogleFonts.inter(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: t.text)),
                    const SizedBox(height: 2),
                    Text(steps[i].$2,
                        style: GoogleFonts.inter(
                            fontSize: 13.5, height: 1.35, color: t.muted)),
                  ]),
            ),
          ]),
        ),
    ]);
  }
}
