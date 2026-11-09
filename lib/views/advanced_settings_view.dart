import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:llama_flutter_android/llama_flutter_android.dart' show LlamaExt;

import '../controllers/server_controller.dart';
import '../core/constants.dart';
import '../core/ui.dart';
import '../services/companion_files.dart';
import '../services/download_service.dart';
import '../services/hive_service.dart';
import '../services/inference_service.dart';

/// GGUF helper files (vision projector, MTP draft head) and the OlliteRT-style
/// server/start-up options. Every option is off by default.
class AdvancedSettingsView extends StatefulWidget {
  const AdvancedSettingsView({super.key});

  @override
  State<AdvancedSettingsView> createState() => _AdvancedSettingsViewState();
}

class _AdvancedSettingsViewState extends State<AdvancedSettingsView> {
  final HiveService _hive = Get.find<HiveService>();
  final InferenceService _inference = Get.find<InferenceService>();

  String _modelsDir = '';
  List<String> _models = const []; // GGUF/LiteRT model file names
  List<String> _mmprojFiles = const []; // full paths
  List<String> _mtpFiles = const [];
  String? _overrideModel; // model file the per-model pickers apply to

  late final TextEditingController _portCtrl;
  late final TextEditingController _corsCtrl;
  late final TextEditingController _seedCtrl;
  late final TextEditingController _keepAliveCtrl;
  late final TextEditingController _threadsCtrl;
  late final TextEditingController _maskCtrl;

  @override
  void initState() {
    super.initState();
    _portCtrl = TextEditingController(
        text: '${_int(AppConstants.keyServerPort, AppConstants.defaultServerPort)}');
    _corsCtrl = TextEditingController(
        text: _hive.getSetting<String>(AppConstants.keyCorsOrigins) ?? '');
    final seed = _int(AppConstants.keyDefaultSeed, -1);
    _seedCtrl = TextEditingController(text: seed >= 0 ? '$seed' : '');
    _keepAliveCtrl = TextEditingController(
        text: '${_int(AppConstants.keyKeepAliveMinutes, 0)}');
    final threads = _int(AppConstants.keyCpuThreads, 0);
    _threadsCtrl = TextEditingController(text: threads > 0 ? '$threads' : '');
    _maskCtrl = TextEditingController(
        text: _hive.getSetting<String>(AppConstants.keyCpuAffinityMask) ?? '');
    _scan();
  }

  @override
  void dispose() {
    _portCtrl.dispose();
    _corsCtrl.dispose();
    _seedCtrl.dispose();
    _keepAliveCtrl.dispose();
    _threadsCtrl.dispose();
    _maskCtrl.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final download = Get.find<DownloadService>();
    final dir = await download.modelsDir;
    final files = await download.getDownloadedModels();
    final models = files
        .where((f) {
          final l = f.toLowerCase();
          return (l.endsWith('.gguf') || l.endsWith('.litertlm')) &&
              !CompanionFiles.isHelperName(f);
        })
        .toList()
      ..sort();
    final mmproj = await CompanionFiles.listHelpers(dir, mtp: false);
    final mtp = await CompanionFiles.listHelpers(dir, mtp: true);
    if (!mounted) return;
    final loaded = _inference.loadedModelPath.value.split('/').last;
    setState(() {
      _modelsDir = dir;
      _models = models;
      _mmprojFiles = mmproj;
      _mtpFiles = mtp;
      _overrideModel ??= models.contains(loaded)
          ? loaded
          : (models.where((m) => m.toLowerCase().endsWith('.gguf')).firstOrNull);
    });
  }

  bool _bool(String key) => _hive.getSetting<bool>(key) ?? false;
  int _int(String key, int def) => _hive.getSetting<int>(key) ?? def;

  Future<void> _setBool(String key, bool value) async {
    await _hive.setSetting(key, value);
    if (key == AppConstants.keyStartOnBoot) {
      try {
        await LlamaExt.setStartOnBoot(value);
      } catch (_) {}
    }
    if (key == AppConstants.keyServerKeepAwake &&
        Get.isRegistered<ServerController>()) {
      await Get.find<ServerController>().refreshKeepAwake();
    }
    setState(() {});
  }

  Future<void> _saveInt(String key, String text, {int? min, int? max, int? empty}) async {
    final trimmed = text.trim();
    int? v = trimmed.isEmpty ? empty : int.tryParse(trimmed);
    if (v == null) {
      showToast('Invalid number', '"$text" is not a whole number.', tone: ToastTone.warning);
      return;
    }
    if (min != null && v < min) v = min;
    if (max != null && v > max) v = max;
    await _hive.setSetting(key, v);
    if (key == AppConstants.keyKeepAliveMinutes) _inference.refreshKeepAlive();
    if (key == AppConstants.keyServerPort && Get.isRegistered<ServerController>()) {
      await Get.find<ServerController>().restartIfRunning();
    }
    showToast('Saved', 'Setting updated.', tone: ToastTone.success);
    setState(() {});
  }

  String _name(String path) => path.split('/').last;

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final defaultPath = _hive.getSetting<String>(AppConstants.keyDefaultModelPath) ?? '';
    final defaultFile = defaultPath.isEmpty ? null : _name(defaultPath);
    return Scaffold(
      backgroundColor: t.bg,
      appBar: appScreenBar(context, title: 'Engine, vision & server', showBack: true),
      body: ListView(
        padding: kPagePadding,
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        children: [
          const SectionHeader('CPU engine (GGUF)'),
          AppGroup(dividerIndent: 60, children: [
            _textRow(Icons.memory_rounded, 'Threads', _threadsCtrl,
                hint: 'auto',
                subtitle: 'Compute threads (empty = auto by device tier). Next load.',
                onSave: (v) => _saveInt(AppConstants.keyCpuThreads, v,
                    min: 0, max: 16, empty: 0)),
            _textRow(Icons.developer_board_rounded, 'CPU cores (hex mask)', _maskCtrl,
                hint: 'off',
                keyboard: TextInputType.text,
                subtitle: 'Pin compute threads to these CPUs, e.g. e0 = cpu5-7 '
                    '(Exynos 2100: X1 + 2x A78). Threads are capped at the core '
                    'count. Empty = off. Next load.',
                onSave: (v) async {
                  final m = v.trim().toLowerCase().replaceFirst('0x', '');
                  if (m.isNotEmpty && int.tryParse(m, radix: 16) == null) {
                    showToast('Invalid mask', '"$v" is not a hex number.',
                        tone: ToastTone.warning);
                    return;
                  }
                  await _hive.setSetting(AppConstants.keyCpuAffinityMask, m);
                  showToast('Saved', 'CPU cores updated.', tone: ToastTone.success);
                }),
            AppRow(
              icon: Icons.storage_rounded,
              title: 'KV cache type',
              subtitle: 'q8_0 halves KV memory (longer context). Next load.',
              trailing: DropdownButton<String>(
                value: const ['f16', 'q8_0', 'q4_0'].contains(
                        _hive.getSetting<String>(AppConstants.keyKvCacheType))
                    ? _hive.getSetting<String>(AppConstants.keyKvCacheType)
                    : 'f16',
                items: const [
                  DropdownMenuItem(value: 'f16', child: Text('f16')),
                  DropdownMenuItem(value: 'q8_0', child: Text('q8_0')),
                  DropdownMenuItem(value: 'q4_0', child: Text('q4_0')),
                ],
                onChanged: (v) async {
                  if (v == null) return;
                  await _hive.setSetting(AppConstants.keyKvCacheType, v);
                  setState(() {});
                },
              ),
            ),
            AppRow(
              icon: Icons.copy_all_rounded,
              title: 'CPU weight repack',
              subtitle: 'Faster prompt processing but a second copy of the '
                  'weights in RAM (off on 8 GB phones). Next load.',
              trailing: Switch(
                value: _hive.getSetting<bool>(AppConstants.keyCpuRepack) ?? true,
                onChanged: (v) async {
                  await _hive.setSetting(AppConstants.keyCpuRepack, v);
                  setState(() {});
                },
              ),
            ),
          ]),
          const SectionHeader('Vision (GGUF)'),
          AppGroup(dividerIndent: 60, children: [
            _switch(
              icon: Icons.hourglass_bottom_rounded,
              title: 'Lazy-load vision projector',
              subtitle: 'Load the mmproj file on the first image instead of at '
                  'model load (saves RAM and load time). Next load.',
              key: AppConstants.keyVisionLazyLoad,
            ),
          ]),
          const SectionHeader('MTP speculative decoding (GGUF)'),
          AppGroup(dividerIndent: 60, children: [
            _switch(
              icon: Icons.fast_forward_rounded,
              title: 'MTP draft',
              subtitle: 'Use a draft head (an "mtp" GGUF next to the model, or '
                  "the model's own NextN layers) to propose tokens the model "
                  'verifies in one pass. Not used with the phone cluster. Next load.',
              key: AppConstants.keyMtpEnabled,
            ),
            AppRow(
              icon: Icons.format_list_numbered_rounded,
              title: 'Draft tokens',
              subtitle: 'Tokens drafted per step (default 3)',
              trailing: DropdownButton<int>(
                value: _int(AppConstants.keyMtpDraftTokens,
                        AppConstants.defaultMtpDraftTokens)
                    .clamp(1, 8),
                items: [
                  for (var i = 1; i <= 8; i++)
                    DropdownMenuItem(value: i, child: Text('$i')),
                ],
                onChanged: (v) async {
                  if (v == null) return;
                  await _hive.setSetting(AppConstants.keyMtpDraftTokens, v);
                  try {
                    await LlamaExt.setMtp(enabled: true, nDraft: v);
                  } catch (_) {}
                  setState(() {});
                },
              ),
            ),
            if (_inference.mtpStatus.isNotEmpty)
              AppRow(
                icon: Icons.info_outline_rounded,
                title: 'Loaded model',
                subtitle: _inference.mtpStatus,
              ),
          ]),
          const SectionHeader('Helper files per model'),
          AppGroup(dividerIndent: 16, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: Text(
                  'Auto pairs files in the models folder by name '
                  '(e.g. mmproj-<model>.gguf, mtp-<model>.gguf). Pick a file '
                  'or None to override. Applies on the next load.',
                  style: t.small),
            ),
            _dropdownRow(
              label: 'Model',
              value: _overrideModel,
              items: {for (final m in _models) m: m},
              onChanged: (v) => setState(() => _overrideModel = v),
            ),
            if (_overrideModel != null) ...[
              _helperRow('Vision (mmproj)', AppConstants.keyMmprojOverrides, _mmprojFiles),
              _helperRow('MTP draft', AppConstants.keyMtpOverrides, _mtpFiles),
            ],
          ]),
          const SectionHeader('Start-up'),
          AppGroup(dividerIndent: 60, children: [
            _dropdownRowWithIcon(
              icon: Icons.star_outline_rounded,
              title: 'Default model',
              value: _models.contains(defaultFile) ? defaultFile : null,
              items: {for (final m in _models) m: m},
              onChanged: (v) async {
                await _hive.setSetting(AppConstants.keyDefaultModelPath,
                    v == null ? '' : '$_modelsDir/$v');
                setState(() {});
              },
            ),
            _switch(
              icon: Icons.play_circle_outline_rounded,
              title: 'Load model on app start',
              subtitle: 'Loads the default model once per launch (skipped if the file is missing)',
              key: AppConstants.keyLoadModelOnStart,
            ),
            _switch(
              icon: Icons.dns_outlined,
              title: 'Start API server on app start',
              subtitle: 'After the model loads',
              key: AppConstants.keyStartServerOnStart,
            ),
            _switch(
              icon: Icons.restart_alt_rounded,
              title: 'Start on boot',
              subtitle: 'Runs PrivateLM in the background after a restart; '
                  'with the two options above it loads the model and serves the API. '
                  'Allow unrestricted battery use for reliability.',
              key: AppConstants.keyStartOnBoot,
            ),
          ]),
          const SectionHeader('API server'),
          AppGroup(dividerIndent: 60, children: [
            _textRow(Icons.numbers_rounded, 'Port', _portCtrl,
                hint: '8080',
                onSave: (v) => _saveInt(AppConstants.keyServerPort, v,
                    min: 1024, max: 65535, empty: AppConstants.defaultServerPort)),
            AppRow(
              icon: Icons.lock_open_rounded,
              title: 'No API key',
              subtitle: 'Serve without authentication, also to other devices on '
                  'the network. Anyone who can reach the port can use the model.',
              trailing: Switch(
                value: _bool(AppConstants.keyServerNoApiKey),
                onChanged: (v) async {
                  if (Get.isRegistered<ServerController>()) {
                    await Get.find<ServerController>().setNoApiKey(v);
                  } else {
                    await _hive.setSetting(AppConstants.keyServerNoApiKey, v);
                  }
                  setState(() {});
                },
              ),
            ),
            _switch(
              icon: Icons.battery_charging_full_rounded,
              title: 'Keep awake while serving',
              subtitle: 'Foreground service with a partial wake lock and a '
                  'high-performance Wi-Fi lock while the server runs',
              key: AppConstants.keyServerKeepAwake,
            ),
            _textRow(Icons.timer_outlined, 'Keep-alive (minutes)', _keepAliveCtrl,
                hint: '0 = off',
                subtitle: 'Unload the model after this long idle; the next request reloads it',
                onSave: (v) => _saveInt(AppConstants.keyKeepAliveMinutes, v,
                    min: 0, max: 1440, empty: 0)),
            _textRow(Icons.public_rounded, 'CORS allowed origins', _corsCtrl,
                hint: 'https://a.example, *',
                keyboard: TextInputType.url,
                subtitle: 'Comma-separated. Empty = only when an API key is set (any origin)',
                onSave: (v) async {
                  await _hive.setSetting(AppConstants.keyCorsOrigins, v.trim());
                  showToast('Saved', 'CORS origins updated.', tone: ToastTone.success);
                }),
            _switch(
              icon: Icons.tune_rounded,
              title: 'Ignore client sampler parameters',
              subtitle: 'Use the app settings instead of temperature/top_p/top_k/'
                  'penalties/seed sent by clients',
              key: AppConstants.keyIgnoreClientSampler,
            ),
            _textRow(Icons.casino_outlined, 'Default seed', _seedCtrl,
                hint: 'random',
                subtitle: 'Used when a request has no seed (empty = random)',
                onSave: (v) => _saveInt(AppConstants.keyDefaultSeed, v,
                    min: -1, empty: -1)),
            _switch(
              icon: Icons.data_usage_rounded,
              title: 'Always send usage in streams',
              subtitle: 'As if every client asked for stream_options.include_usage',
              key: AppConstants.keyForceStreamUsage,
            ),
            _switch(
              icon: Icons.scatter_plot_outlined,
              title: 'Embeddings endpoint',
              subtitle: '/v1/embeddings from the loaded GGUF model (clears its chat cache)',
              key: AppConstants.keyServerEmbeddings,
            ),
          ]),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _switch({
    required IconData icon,
    required String title,
    required String subtitle,
    required String key,
  }) {
    final value = _bool(key);
    return AppRow(
      icon: icon,
      title: title,
      subtitle: subtitle,
      trailing: Switch(value: value, onChanged: (v) => _setBool(key, v)),
      onTap: () => _setBool(key, !value),
    );
  }

  Widget _textRow(
    IconData icon,
    String title,
    TextEditingController ctrl, {
    required String hint,
    String? subtitle,
    TextInputType keyboard = TextInputType.number,
    required Future<void> Function(String) onSave,
  }) {
    final t = AppTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
      child: Row(children: [
        Icon(icon, size: 22, color: t.muted),
        const SizedBox(width: 22),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: t.body),
            if (subtitle != null) Text(subtitle, style: t.small),
            TextField(
              controller: ctrl,
              keyboardType: keyboard,
              decoration: InputDecoration(hintText: hint, isDense: true),
              onSubmitted: onSave,
            ),
          ]),
        ),
        IconButton(
          tooltip: 'Save',
          icon: const Icon(Icons.check_rounded),
          onPressed: () => onSave(ctrl.text),
        ),
      ]),
    );
  }

  Widget _dropdownRow({
    required String label,
    required String? value,
    required Map<String, String> items,
    required ValueChanged<String?> onChanged,
  }) {
    final t = AppTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Row(children: [
        SizedBox(width: 110, child: Text(label, style: t.body)),
        Expanded(
          child: DropdownButton<String>(
            isExpanded: true,
            value: items.containsKey(value) ? value : null,
            hint: const Text('—'),
            items: [
              for (final e in items.entries)
                DropdownMenuItem(
                    value: e.key,
                    child: Text(e.value, overflow: TextOverflow.ellipsis)),
            ],
            onChanged: onChanged,
          ),
        ),
      ]),
    );
  }

  Widget _dropdownRowWithIcon({
    required IconData icon,
    required String title,
    required String? value,
    required Map<String, String> items,
    required ValueChanged<String?> onChanged,
  }) {
    final t = AppTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: Row(children: [
        Icon(icon, size: 22, color: t.muted),
        const SizedBox(width: 22),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: t.body),
            DropdownButton<String>(
              isExpanded: true,
              value: value,
              hint: const Text('None'),
              items: [
                const DropdownMenuItem<String>(value: null, child: Text('None')),
                for (final e in items.entries)
                  DropdownMenuItem(
                      value: e.key,
                      child: Text(e.value, overflow: TextOverflow.ellipsis)),
              ],
              onChanged: onChanged,
            ),
          ]),
        ),
      ]),
    );
  }

  Widget _helperRow(String label, String key, List<String> files) {
    final model = _overrideModel!;
    final current = _inference.helperOverride(key, model) ?? '';
    final items = <String, String>{
      '': 'Auto',
      CompanionFiles.none: 'None',
      for (final f in files) f: _name(f),
    };
    return _dropdownRow(
      label: label,
      value: items.containsKey(current) ? current : '',
      items: items,
      onChanged: (v) async {
        await _inference.setHelperOverride(key, model, v);
        setState(() {});
      },
    );
  }
}
