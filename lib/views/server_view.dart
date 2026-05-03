import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;

import '../controllers/server_controller.dart';
import '../core/colors.dart';

class ServerView extends GetView<ServerController> {
  const ServerView({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Server',
          style: GoogleFonts.inter(fontWeight: FontWeight.w700),
        ),
      ),
      body: Obx(() {
        final isRunning = controller.isRunning.value;
        final hasKey = controller.apiKey.value.trim().isNotEmpty;
        final publicWithoutKey =
            controller.useTunnel.value && !controller.useApiKey.value;

        return ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
          children: [
            _StatusCard(
              title: isRunning ? 'API Server Running' : 'API Server Stopped',
              subtitle: isRunning
                  ? controller.serverStatus.value
                  : 'Expose your loaded LiteRT-LM model as an OpenAI-compatible API.',
              icon: isRunning ? Icons.dns : Icons.dns_outlined,
              color: isRunning ? AppColors.success : AppColors.textMuted,
              trailing: Switch(
                value: isRunning,
                onChanged: controller.isStarting.value
                    ? null
                    : (value) => controller.toggleServer(value),
              ),
            ),
            const SizedBox(height: 12),
            _ModelCard(controller: controller),
            const SizedBox(height: 12),
            if (publicWithoutKey) ...[
              _WarningCard(
                text:
                    'Public tunnel is enabled without an API key. Anyone with the URL can use your local model while the server is running.',
              ),
              const SizedBox(height: 12),
            ],
            _SectionCard(
              title: 'Security',
              icon: Icons.key_outlined,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: controller.useApiKey.value,
                  onChanged: (value) {
                    controller.useApiKey.value = value;
                    controller.saveSettings();
                  },
                  title: const Text('Require API key'),
                  subtitle: const Text('Uses Authorization: Bearer <key> for /v1 requests'),
                ),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: TextEditingController(text: controller.apiKey.value)
                          ..selection = TextSelection.collapsed(
                            offset: controller.apiKey.value.length,
                          ),
                        onChanged: (value) => controller.apiKey.value = value,
                        onSubmitted: (_) => controller.saveSettings(),
                        decoration: const InputDecoration(
                          labelText: 'API key',
                          hintText: 'Optional',
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: 'Generate key',
                      onPressed: controller.generateApiKey,
                      icon: const Icon(Icons.auto_awesome),
                    ),
                    IconButton(
                      tooltip: 'Copy key',
                      onPressed: hasKey
                          ? () => controller.copyText(controller.apiKey.value, 'API key')
                          : null,
                      icon: const Icon(Icons.copy_outlined),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),
            _SectionCard(
              title: 'Tunnel',
              icon: Icons.public,
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: controller.useTunnel.value,
                  onChanged: (value) {
                    controller.useTunnel.value = value;
                    controller.saveSettings();
                    if (!value) controller.stopTunnel();
                  },
                  title: const Text('Public tunnel'),
                  subtitle: Text(controller.tunnelStatus.value),
                ),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                      value: 'cloudflare',
                      label: Text('Cloudflare'),
                      icon: Icon(Icons.cloud_outlined),
                    ),
                    ButtonSegment(
                      value: 'ngrok',
                      label: Text('ngrok'),
                      icon: Icon(Icons.lan_outlined),
                    ),
                  ],
                  selected: {controller.tunnelProvider.value},
                  onSelectionChanged: (values) {
                    controller.tunnelProvider.value = values.first;
                    controller.saveSettings();
                  },
                ),
                const SizedBox(height: 12),
                if (controller.tunnelProvider.value == 'cloudflare') ...[
                  _SettingField(
                    label: 'Cloudflare tunnel token',
                    value: controller.cloudflareToken.value,
                    onChanged: (v) => controller.cloudflareToken.value = v,
                    onSubmitted: (_) => controller.saveSettings(),
                  ),
                  const SizedBox(height: 8),
                  _SettingField(
                    label: 'Stable public URL',
                    value: controller.cloudflarePublicUrl.value,
                    onChanged: (v) => controller.cloudflarePublicUrl.value = v,
                    onSubmitted: (_) => controller.saveSettings(),
                  ),
                ] else ...[
                  _SettingField(
                    label: 'ngrok auth token',
                    value: controller.ngrokAuthToken.value,
                    onChanged: (v) => controller.ngrokAuthToken.value = v,
                    onSubmitted: (_) => controller.saveSettings(),
                  ),
                  const SizedBox(height: 8),
                  _SettingField(
                    label: 'ngrok reserved domain',
                    value: controller.ngrokDomain.value,
                    onChanged: (v) => controller.ngrokDomain.value = v,
                    onSubmitted: (_) => controller.saveSettings(),
                  ),
                ],
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: isRunning && controller.useTunnel.value
                            ? controller.startTunnel
                            : null,
                        icon: controller.isTunnelStarting.value
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.play_arrow),
                        label: const Text('Start tunnel'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: controller.publicUrl.value != null
                          ? controller.stopTunnel
                          : null,
                      child: const Icon(Icons.stop),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (isRunning) _EndpointsCard(controller: controller),
            if (isRunning) const SizedBox(height: 12),
            if (isRunning) _ExamplesCard(controller: controller),
            if (controller.lastError.value != null) ...[
              const SizedBox(height: 12),
              _WarningCard(text: controller.lastError.value!),
            ],
          ],
        );
      }),
    );
  }
}

class _ModelCard extends StatelessWidget {
  final ServerController controller;
  const _ModelCard({required this.controller});

  @override
  Widget build(BuildContext context) {
    final liteRt = controller.hasLiteRtModel;
    return _StatusCard(
      title: controller.modelName,
      subtitle: liteRt
          ? 'LiteRT-LM ready: text, image, audio, streaming'
          : 'Server requires a loaded .litertlm model.',
      icon: liteRt ? Icons.check_circle_outline : Icons.info_outline,
      color: liteRt ? AppColors.primary : AppColors.warning,
    );
  }
}

class _EndpointsCard extends StatelessWidget {
  final ServerController controller;
  const _EndpointsCard({required this.controller});

  @override
  Widget build(BuildContext context) {
    return _SectionCard(
      title: 'Endpoints',
      icon: Icons.link,
      children: [
        _UrlRow(label: 'Local', url: controller.localUrl.value, controller: controller),
        _UrlRow(label: 'Public', url: controller.publicUrl.value, controller: controller),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: controller.localUrl.value == null
                    ? null
                    : () => _testHealth(controller.localUrl.value!),
                icon: const Icon(Icons.wifi),
                label: const Text('Test local'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: controller.publicUrl.value == null
                    ? null
                    : () => _testHealth(controller.publicUrl.value!),
                icon: const Icon(Icons.public),
                label: const Text('Test public'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _testHealth(String baseUrl) async {
    try {
      final response = await http
          .get(Uri.parse('${baseUrl.replaceAll(RegExp(r'/$'), '')}/health'))
          .timeout(const Duration(seconds: 8));
      Get.snackbar('Health check', 'Status ${response.statusCode}');
    } catch (e) {
      Get.snackbar('Health failed', '$e');
    }
  }
}

class _ExamplesCard extends StatelessWidget {
  final ServerController controller;
  const _ExamplesCard({required this.controller});

  @override
  Widget build(BuildContext context) {
    final base = controller.baseUrl;
    final model = controller.inference.loadedModelName.value;
    final auth = controller.useApiKey.value && controller.apiKey.value.isNotEmpty
        ? ' \\\n  -H "Authorization: Bearer ${controller.apiKey.value}"'
        : '';
    return _SectionCard(
      title: 'Usage Examples',
      icon: Icons.terminal,
      children: [
        _CodeBlock(
          title: 'List models',
          code: 'curl $base/v1/models$auth',
          onCopy: controller.copyText,
        ),
        _CodeBlock(
          title: 'Chat completion',
          code: '''curl $base/v1/chat/completions \\
  -H "Content-Type: application/json"$auth \\
  -d '{"model":"$model","messages":[{"role":"user","content":"Hello"}]}' ''',
          onCopy: controller.copyText,
        ),
        _CodeBlock(
          title: 'Python OpenAI SDK',
          code: '''from openai import OpenAI

client = OpenAI(
    base_url="$base/v1",
    api_key="${controller.useApiKey.value ? controller.apiKey.value : 'not-needed'}"
)

response = client.chat.completions.create(
    model="$model",
    messages=[{"role": "user", "content": "Hello"}],
)
print(response.choices[0].message.content)''',
          onCopy: controller.copyText,
        ),
      ],
    );
  }
}

class _StatusCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final Widget? trailing;

  const _StatusCard({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(icon, color: color, size: 28),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: GoogleFonts.inter(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      color: Theme.of(context).hintColor,
                    ),
                  ),
                ],
              ),
            ),
            if (trailing != null) trailing!,
          ],
        ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<Widget> children;

  const _SectionCard({
    required this.title,
    required this.icon,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: AppColors.primary),
                const SizedBox(width: 8),
                Text(title, style: GoogleFonts.inter(fontWeight: FontWeight.w700)),
              ],
            ),
            const SizedBox(height: 12),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _UrlRow extends StatelessWidget {
  final String label;
  final String? url;
  final ServerController controller;

  const _UrlRow({
    required this.label,
    required this.url,
    required this.controller,
  });

  @override
  Widget build(BuildContext context) {
    final value = url ?? 'Not available';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          SizedBox(
            width: 58,
            child: Text(label, style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
          ),
          Expanded(
            child: SelectableText(
              value,
              maxLines: 1,
              style: GoogleFonts.firaCode(fontSize: 12),
            ),
          ),
          IconButton(
            tooltip: 'Copy $label URL',
            onPressed: url == null ? null : () => controller.copyText(url!, '$label URL'),
            icon: const Icon(Icons.copy_outlined, size: 18),
          ),
        ],
      ),
    );
  }
}

class _CodeBlock extends StatelessWidget {
  final String title;
  final String code;
  final Future<void> Function(String, String) onCopy;

  const _CodeBlock({
    required this.title,
    required this.code,
    required this.onCopy,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(title, style: GoogleFonts.inter(fontWeight: FontWeight.w700)),
              ),
              IconButton(
                tooltip: 'Copy',
                onPressed: () => onCopy(code, title),
                icon: const Icon(Icons.copy_outlined, size: 18),
              ),
            ],
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Text(code, style: GoogleFonts.firaCode(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

class _WarningCard extends StatelessWidget {
  final String text;
  const _WarningCard({required this.text});

  @override
  Widget build(BuildContext context) {
    return Card(
      color: AppColors.warning.withOpacity(0.14),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.warning_amber_outlined, color: AppColors.warning),
            const SizedBox(width: 10),
            Expanded(child: Text(text)),
          ],
        ),
      ),
    );
  }
}

class _SettingField extends StatelessWidget {
  final String label;
  final String value;
  final ValueChanged<String> onChanged;
  final ValueChanged<String> onSubmitted;

  const _SettingField({
    required this.label,
    required this.value,
    required this.onChanged,
    required this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: TextEditingController(text: value)
        ..selection = TextSelection.collapsed(offset: value.length),
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      decoration: InputDecoration(labelText: label),
    );
  }
}
