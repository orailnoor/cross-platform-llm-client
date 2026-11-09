import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;

import '../controllers/server_controller.dart';
import '../core/ui.dart';
import '../core/haptics.dart';
import 'advanced_settings_view.dart';

class ServerView extends GetView<ServerController> {
  const ServerView({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);

    return Scaffold(
      backgroundColor: t.bg,
      appBar: appScreenBar(context, title: 'Server'),
      body: Obx(() {
        final isRunning = controller.isRunning.value;
        final isStarting = controller.isStarting.value;
        final allowNetwork = controller.allowNetwork.value;
        final hasKey = controller.apiKey.value.trim().isNotEmpty;
        final error = controller.lastError.value;

        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
          children: [
            _StatusHero(controller: controller),

            if (error != null) ...[
              const SizedBox(height: 12),
              AppNotice(error, icon: Icons.error_outline_rounded, color: t.red),
            ],

            // ── Model ──
            const SectionHeader('Model'),
            AppGroup(children: [
              AppRow(
                icon: Icons.memory_rounded,
                title: controller.modelName,
                subtitle: controller.hasLocalModel
                    ? 'Loaded on this device'
                    : 'Load a GGUF or LiteRT-LM model to serve it',
                trailing: controller.hasLocalModel
                    ? AppTag('Ready', color: t.green)
                    : AppTag('Not loaded', color: t.orange),
              ),
            ]),

            // ── Access ──
            const SectionHeader('Access'),
            AppGroup(children: [
              AppRow(
                icon: Icons.lan_outlined,
                title: 'Allow network access',
                subtitle: allowNetwork
                    ? 'Reachable from other devices on your network'
                    : 'Only apps on this device can connect',
                trailing: Switch(
                  value: allowNetwork,
                  onChanged:
                      isStarting ? null : (v) => controller.setAllowNetwork(v),
                ),
              ),
              AppRow(
                icon: Icons.key_outlined,
                title: 'Require API key',
                subtitle: controller.noApiKey.value
                    ? 'Off: "No API key" is on (Port, start-up & advanced)'
                    : allowNetwork
                        ? 'Always on while network access is enabled'
                        : 'Clients send Authorization: Bearer <key>',
                trailing: Switch(
                  value: controller.requiresApiKey,
                  onChanged: (allowNetwork || controller.noApiKey.value)
                      ? null
                      : (v) => controller.setUseApiKey(v),
                ),
              ),
              AppRow(
                icon: Icons.settings_suggest_outlined,
                title: 'Port, start-up & advanced',
                subtitle: 'Port ${ServerController.port} · auto-start, keep-awake, '
                    'keep-alive, CORS, sampler overrides',
                chevron: true,
                onTap: () => Get.to(() => const AdvancedSettingsView()),
              ),
            ]),
            const SizedBox(height: 12),
            AppField(
              label: 'API key',
              helper: controller.requiresApiKey
                  ? 'Required for every request.'
                  : 'Optional. Only checked when "Require API key" is on.',
              child: TextField(
                controller: controller.apiKeyCtrl,
                onChanged: controller.onApiKeyEdited,
                onSubmitted: (_) => controller.saveSettings(),
                style: t.mono.copyWith(fontSize: 13.5),
                autocorrect: false,
                enableSuggestions: false,
                decoration: appInputDecoration(
                  context,
                  hint: controller.requiresApiKey ? 'Required' : 'Optional',
                  suffix: Row(mainAxisSize: MainAxisSize.min, children: [
                    IconButton(
                      tooltip: 'Generate key',
                      visualDensity: VisualDensity.compact,
                      onPressed: () {
                        Haptics.lightImpact();
                        controller.generateApiKey();
                      },
                      icon:
                          Icon(Icons.refresh_rounded, size: 19, color: t.muted),
                    ),
                    _CopyButton(
                      text: hasKey ? controller.apiKey.value : null,
                      tooltip: 'Copy key',
                    ),
                    const SizedBox(width: 4),
                  ]),
                ),
              ),
            ),

            // ── Endpoints ──
            if (isRunning) ...[
              const SectionHeader('Endpoints'),
              AppGroup(children: [
                _UrlRow(label: 'Base URL', url: controller.localUrl.value),
                _UrlRow(
                    label: 'OpenAI base URL',
                    url: controller.localUrl.value == null
                        ? null
                        : controller.openAiBaseUrl),
              ]),
              const SizedBox(height: 12),
              _HealthTest(baseUrl: controller.localUrl.value),

              // ── Examples ──
              const SectionHeader('Usage examples'),
              _CodeBlock(
                title: 'List models',
                lang: 'curl',
                code: 'curl ${controller.baseUrl}/v1/models${_authHeader()}',
              ),
              const SizedBox(height: 12),
              _CodeBlock(
                title: 'Chat completion',
                lang: 'curl',
                code:
                    'curl ${controller.baseUrl}/v1/chat/completions \\\n  -H "Content-Type: application/json"${_authHeader()} \\\n  -d \'{"model":"${controller.inference.loadedModelName.value}","messages":[{"role":"user","content":"Hello"}]}\'',
              ),
              const SizedBox(height: 12),
              _CodeBlock(
                title: 'OpenAI SDK',
                lang: 'python',
                code:
                    'from openai import OpenAI\n\nclient = OpenAI(\n    base_url="${controller.baseUrl}/v1",\n    api_key="${controller.requiresApiKey ? controller.apiKey.value : "not-needed"}"\n)\n\nresponse = client.chat.completions.create(\n    model="${controller.inference.loadedModelName.value}",\n    messages=[{"role": "user", "content": "Hello"}],\n)\nprint(response.choices[0].message.content)',
              ),
            ],
          ],
        );
      }),
    );
  }

  String _authHeader() {
    if (controller.requiresApiKey && controller.apiKey.value.isNotEmpty) {
      return ' \\\n  -H "Authorization: Bearer ${controller.apiKey.value}"';
    }
    return '';
  }
}

// ── Status hero ─────────────────────────────────────────────────────────

class _StatusHero extends StatelessWidget {
  final ServerController controller;
  const _StatusHero({required this.controller});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final isRunning = controller.isRunning.value;
    final isStarting = controller.isStarting.value;

    final Color dot;
    final String title;
    final String meta;
    if (isStarting) {
      dot = t.orange;
      title = 'Starting…';
      meta = controller.serverStatus.value;
    } else if (isRunning) {
      dot = t.green;
      title = 'Running on port ${ServerController.port}';
      meta = controller.allowNetwork.value
          ? 'Serving ${controller.modelName} · open to your network'
          : 'Serving ${controller.modelName} · this device only';
    } else {
      dot = t.faint;
      title = 'Stopped';
      meta = controller.hasLocalModel
          ? 'Expose ${controller.modelName} as an OpenAI-compatible API'
          : 'Expose a local model as an OpenAI-compatible API';
    }

    return AppCard(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          StatusDot(dot, size: 8),
          const SizedBox(width: 8),
          Text('Local API server', style: t.small),
        ]),
        const SizedBox(height: 10),
        Text(title, style: t.title.copyWith(fontSize: 20, letterSpacing: -0.5)),
        const SizedBox(height: 4),
        Text(meta,
            style: t.caption, maxLines: 2, overflow: TextOverflow.ellipsis),
        const SizedBox(height: 16),
        if (isRunning && !isStarting)
          SizedBox(
            width: double.infinity,
            child: TonalButton.destructive(context, label: 'Stop server',
                onTap: () {
              Haptics.mediumImpact();
              controller.toggleServer(false);
            }),
          )
        else
          PrimaryButton(
            label: isStarting ? 'Starting…' : 'Start server',
            icon: Icons.play_arrow_rounded,
            busy: isStarting,
            onPressed: () {
              Haptics.mediumImpact();
              controller.toggleServer(true);
            },
          ),
      ]),
    );
  }
}

// ── Copy button with inline confirmation ────────────────────────────────

class _CopyButton extends StatefulWidget {
  final String? text;
  final String tooltip;
  const _CopyButton({required this.text, this.tooltip = 'Copy'});

  @override
  State<_CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<_CopyButton> {
  bool _copied = false;
  Timer? _timer;

  Future<void> _copy() async {
    final text = widget.text;
    if (text == null) return;
    await Clipboard.setData(ClipboardData(text: text));
    Haptics.lightImpact();
    if (!mounted) return;
    setState(() => _copied = true);
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final enabled = widget.text != null;
    return IconButton(
      tooltip: _copied ? 'Copied' : widget.tooltip,
      visualDensity: VisualDensity.compact,
      onPressed: enabled ? _copy : null,
      icon: AnimatedSwitcher(
        duration: const Duration(milliseconds: 160),
        transitionBuilder: (child, anim) =>
            ScaleTransition(scale: anim, child: child),
        child: _copied
            ? Icon(Icons.check_rounded,
                key: const ValueKey('check'), size: 18, color: t.green)
            : Icon(Icons.copy_rounded,
                key: const ValueKey('copy'),
                size: 17,
                color: enabled ? t.muted : t.faint),
      ),
    );
  }
}

// ── URL row ─────────────────────────────────────────────────────────────

class _UrlRow extends StatelessWidget {
  final String label;
  final String? url;
  const _UrlRow({required this.label, required this.url});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 6, 10),
      child: Row(children: [
        Expanded(
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: t.small),
            const SizedBox(height: 3),
            Text(
              url ?? 'Not available',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: t.mono.copyWith(color: url == null ? t.faint : t.text),
            ),
          ]),
        ),
        _CopyButton(text: url, tooltip: 'Copy $label'),
      ]),
    );
  }
}

// ── Health test ─────────────────────────────────────────────────────────

class _HealthTest extends StatefulWidget {
  final String? baseUrl;
  const _HealthTest({required this.baseUrl});

  @override
  State<_HealthTest> createState() => _HealthTestState();
}

class _HealthTestState extends State<_HealthTest> {
  bool _busy = false;
  bool? _ok;
  String? _message;

  Future<void> _run() async {
    final baseUrl = widget.baseUrl;
    if (baseUrl == null || _busy) return;
    Haptics.selectionClick();
    setState(() {
      _busy = true;
      _ok = null;
      _message = null;
    });
    try {
      final r = await http
          .get(Uri.parse('${baseUrl.replaceAll(RegExp(r'/$'), '')}/health'))
          .timeout(const Duration(seconds: 8));
      final ok = r.statusCode >= 200 && r.statusCode < 300;
      if (!mounted) return;
      setState(() {
        _ok = ok;
        _message = ok
            ? 'Server is healthy · HTTP ${r.statusCode}'
            : 'Health check returned HTTP ${r.statusCode}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _ok = false;
        _message = 'Health check failed: $e';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        PillButton(
          label: _busy ? 'Testing…' : 'Test connection',
          icon: Icons.network_check_rounded,
          onPressed: widget.baseUrl == null || _busy ? null : _run,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text('Calls GET /health',
              style: t.small, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ]),
      if (_message != null) ...[
        const SizedBox(height: 10),
        AppNotice(
          _message!,
          icon: _ok == true
              ? Icons.check_circle_outline_rounded
              : Icons.error_outline_rounded,
          color: _ok == true ? t.green : t.red,
        ),
      ],
    ]);
  }
}

// ── Code block ──────────────────────────────────────────────────────────

class _CodeBlock extends StatelessWidget {
  final String title;
  final String lang;
  final String code;
  const _CodeBlock(
      {required this.title, required this.lang, required this.code});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Container(
      decoration: BoxDecoration(
        color: t.isDark ? const Color(0xFF0E0E10) : const Color(0xFFF0F0F2),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: t.hairline, width: 0.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 4, 4, 0),
          child: Row(children: [
            Flexible(
              child: Text(title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: t.label.copyWith(color: t.text)),
            ),
            const SizedBox(width: 8),
            AppTag(lang),
            const Spacer(),
            _CopyButton(text: code, tooltip: 'Copy snippet'),
          ]),
        ),
        Container(height: 0.5, color: t.hairline),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
          child: Text(code, style: t.mono.copyWith(height: 1.5)),
        ),
      ]),
    );
  }
}
