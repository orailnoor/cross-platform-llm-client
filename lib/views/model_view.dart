import 'dart:async';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import '../controllers/cloud_model_controller.dart';
import '../controllers/model_controller.dart';
import '../controllers/settings_controller.dart';
import '../core/ui.dart';
import '../models/ai_model.dart';
import '../services/download_service.dart';
import '../services/inference_service.dart';
import '../services/local_image_service.dart';

const _tabular = [FontFeature.tabularFigures()];

String _prettyModel(String name) => name.replaceAll(
    RegExp(r'\.(gguf|litertlm|task|bin)$', caseSensitive: false), '');

/// Input decoration for fields inside sheets. In dark mode the sheet itself
/// is the default field colour, so use a translucent fill that stays visible.
InputDecoration _sheetInput(BuildContext context,
    {String? hint, String? label, Widget? suffix, Widget? prefix}) {
  final t = AppTokens.of(context);
  return appInputDecoration(context,
          hint: hint, label: label, suffix: suffix, prefix: prefix)
      .copyWith(
          fillColor: t.isDark ? Colors.white.withValues(alpha: 0.07) : null);
}

/// Surface for grouped content inside a sheet (sheet bg differs from page bg).
Color _sheetSurface(AppTokens t) =>
    t.isDark ? Colors.white.withValues(alpha: 0.05) : t.surface;

class ModelView extends GetView<ModelController> {
  const ModelView({super.key});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Scaffold(
      backgroundColor: t.bg,
      appBar: appScreenBar(
        context,
        title: 'Models',
        actions: [
          Obx(() {
            if (controller.modelScope.value == 'online') {
              return const SizedBox.shrink();
            }
            return _TextAction(
              icon: Icons.add_rounded,
              label: 'Import',
              color: t.accent,
              onTap: controller.isImporting.value
                  ? null
                  : () => _showImportSheet(context),
            );
          }),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          if (controller.modelScope.value != 'online') {
            await controller.refreshDownloaded();
          }
        },
        color: t.accent,
        child: Obx(() {
          final scope = controller.modelScope.value;
          return ListView(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 24),
            children: [
              _buildScopeToggle(context),
              const SizedBox(height: 8),
              _buildActiveModelBanner(context),
              _buildActiveDownloadsBanner(context),
              if (scope == 'local') ...[
                _buildImportingProgress(context),
                ..._buildLibrary(context),
              ] else if (scope == 'browse') ...[
                _buildFeatured(context),
                _buildLocalFilterChips(context),
                ..._buildBrowse(context),
              ] else
                _buildOnlineProviders(context),
            ],
          );
        }),
      ),
    );
  }

  Widget _buildScopeToggle(BuildContext context) {
    return Obx(() => AppSegmented<String>(
          items: const [
            ('local', 'My models'),
            ('browse', 'Browse'),
            ('online', 'Cloud'),
          ],
          selected: controller.modelScope.value,
          onChanged: (value) => controller.modelScope.value = value,
        ));
  }

  Widget _buildLocalActions(BuildContext context) {
    final inference = Get.find<InferenceService>();
    return Obx(() {
      final busy =
          controller.isImporting.value || inference.isLoadingModel.value;
      return PillButton(
        label: 'Import file',
        icon: Icons.file_upload_outlined,
        onPressed: busy ? null : () => _showImportSheet(context),
      );
    });
  }

  Widget _buildLocalFilterChips(BuildContext context) {
    final labels = [
      ('general', 'Chat'),
      ('image', 'Image'),
      ('uncensored', 'Uncensored'),
      ('vision', 'Vision'),
      if (ModelController.supportsAppleNpu) ('npu', 'Apple NPU'),
    ];
    return Obx(() {
      final selected = controller.localFilter.value.isEmpty
          ? controller.defaultLocalFilter
          : controller.localFilter.value;
      return AppChips<String>(
        items: labels,
        selected: selected,
        onSelected: controller.setLocalFilter,
      );
    });
  }

  // ── Import ────────────────────────────────────────────────────────────

  void _showImportSheet(BuildContext context) {
    showAppSheet<void>(
      context,
      title: 'Import model',
      subtitle: 'Add .gguf, .litertlm or .safetensors files from your phone.',
      builder: (ctx) => AppGroup(children: [
        AppRow(
          icon: Icons.insert_drive_file_outlined,
          title: 'Import file',
          subtitle: 'Choose a single model file',
          chevron: true,
          onTap: () {
            Navigator.pop(ctx);
            controller.importModelFromStorage();
          },
        ),
        if (controller.supportsFolderImport)
          AppRow(
            icon: Icons.folder_open_rounded,
            title: 'Import from folder',
            subtitle: 'Scan a folder and pick the models to add',
            chevron: true,
            onTap: () {
              Navigator.pop(ctx);
              _importFromFolder(context);
            },
          ),
      ]),
    );
  }

  Future<void> _importFromFolder(BuildContext context) async {
    final files = await controller.pickModelFolder();
    if (files == null || !context.mounted) return;
    if (files.isEmpty) {
      showToast('No models found',
          'That folder has no .gguf, .litertlm or .safetensors files.',
          tone: ToastTone.warning);
      return;
    }
    final chosen = await showAppSheet<List<FolderModelFile>>(
      context,
      title: 'Models in folder',
      subtitle: '${files.length} ${files.length == 1 ? 'file' : 'files'} found',
      builder: (_) => _FolderImportList(files: files, controller: controller),
    );
    if (chosen != null && chosen.isNotEmpty) {
      await controller.importFolderFiles(chosen);
    }
  }

  Widget _buildEmptyLibrary(BuildContext context) {
    return EmptyState(
      icon: Icons.download_rounded,
      title: 'No models on this phone yet',
      message: 'Download one from Browse, or import a model file.',
      action: Wrap(spacing: 8, children: [
        PillButton(
          label: 'Browse models',
          primary: true,
          onPressed: () => controller.modelScope.value = 'browse',
        ),
        _buildLocalActions(context),
      ]),
    );
  }

  // ── Active model ──────────────────────────────────────────────────────

  Widget _buildActiveModelBanner(BuildContext context) {
    return Obx(() {
      final t = AppTokens.of(context);
      if (controller.modelScope.value == 'online') {
        return Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _buildActiveCloudBanner(context),
        );
      }
      final inference = Get.find<InferenceService>();
      final localImage = Get.find<LocalImageService>();
      final busy =
          controller.isImporting.value || inference.isLoadingModel.value;

      final String name;
      final String meta;
      final IconData icon;
      if (localImage.isModelLoaded.value) {
        name = localImage.loadedModelName.value;
        meta =
            'Loaded · Image generation · ${localImage.isUsingGpu.value ? 'GPU accelerated' : 'CPU'}';
        icon = Icons.image_outlined;
      } else if (inference.isModelLoaded.value) {
        name = inference.loadedModelName.value;
        final gpu = inference.gpuName.value;
        meta = inference.isGpuAccelerated.value
            ? 'Loaded · GPU${gpu.isEmpty ? '' : ' · $gpu'}'
            : 'Loaded · CPU';
        icon = Icons.memory_rounded;
      } else {
        return const SizedBox.shrink();
      }

      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: _ActiveCard(
          icon: icon,
          title: _prettyModel(name),
          meta: meta,
          dot: t.green,
          action: PillButton(
            label: 'Unload',
            onPressed: busy ? null : () => controller.unloadModel(),
          ),
        ),
      );
    });
  }

  /// Compact, pinned summary of every running download (models and their
  /// helper files), so progress stays visible while browsing the list.
  Widget _buildActiveDownloadsBanner(BuildContext context) {
    return Obx(() {
      if (controller.modelScope.value == 'online') {
        return const SizedBox.shrink();
      }
      final downloads = controller.activeDownloads.values.toList();
      if (downloads.isEmpty) return const SizedBox.shrink();
      final t = AppTokens.of(context);

      String labelFor(String filename) {
        if (filename.startsWith('save:')) {
          final name = filename.substring(5);
          final m = controller.availableModels
              .firstWhereOrNull((x) => x.filename == name);
          final owner = controller.availableModels
              .firstWhereOrNull((x) => x.mmprojFilename == name);
          return 'Saving to Downloads · '
              '${m?.name ?? (owner != null ? 'Vision file · ${owner.name}' : name)}';
        }
        final model = controller.availableModels
            .firstWhereOrNull((m) => m.filename == filename);
        if (model != null) return model.name;
        final owner = controller.availableModels
            .firstWhereOrNull((m) => m.mmprojFilename == filename);
        // Lead with "Vision file" so it stays visible when the name is cut off.
        if (owner != null) return 'Vision file · ${owner.name}';
        if (filename.toLowerCase().startsWith('taesd')) {
          return 'Image decoder (TAESD)';
        }
        return filename;
      }

      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: AppCard(
          padding: EdgeInsets.zero,
          child: Column(children: [
            for (var i = 0; i < downloads.length; i++) ...[
              if (i > 0)
                Container(height: 0.5, color: t.hairline),
              Obx(() {
                final dp = downloads[i];
                final pct = (dp.progress.value * 100).clamp(0.0, 100.0);
                final eta = dp.eta;
                final meta = [
                  if (dp.status.value.isNotEmpty)
                    dp.status.value.replaceAll(RegExp(r'\.+$'), ''),
                  '${pct.toStringAsFixed(0)}%',
                  if (dp.bytesPerSecond.value > 0)
                    DownloadService.formatSpeed(dp.bytesPerSecond.value),
                  if (eta != null && eta > Duration.zero)
                    '${DownloadService.formatDuration(eta)} left',
                ].join(' · ');
                return Padding(
                  padding: const EdgeInsets.all(6),
                  child: Row(children: [
                    const IconBadge(Icons.download_rounded, size: 32),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(labelFor(dp.filename),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: t.bodyStrong.copyWith(fontSize: 14)),
                            const SizedBox(height: 6),
                            AppProgressBar(
                                value: dp.progress.value > 0
                                    ? dp.progress.value
                                    : null,
                                height: 3),
                            const SizedBox(height: 5),
                            Text(meta,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style:
                                    t.small.copyWith(fontFeatures: _tabular)),
                          ]),
                    ),
                    // Copies to Downloads are quick and can't be cancelled.
                    if (!dp.filename.startsWith('save:'))
                      IconButton(
                        tooltip: controller.canPauseDownloads
                            ? 'Pause download'
                            : 'Cancel download',
                        onPressed: () {
                          final external =
                              controller.externalDownloadId.value != null &&
                                  controller.importFileName.value ==
                                      dp.filename;
                          external
                              ? controller.cancelExternalDownload()
                              : controller.pauseDownload(dp.filename);
                        },
                        icon: Icon(
                            controller.canPauseDownloads
                                ? Icons.pause_rounded
                                : Icons.close_rounded,
                            size: 20,
                            color: t.muted),
                      ),
                  ]),
                );
              }),
            ],
          ]),
        ),
      );
    });
  }

  Widget _buildActiveCloudBanner(BuildContext context) {
    final t = AppTokens.of(context);
    final settings = Get.find<SettingsController>();
    final cloudModels = Get.find<CloudModelController>();
    final providerId = settings.cloudProvider.value;
    final provider =
        cloudModels.providers.firstWhereOrNull((p) => p.id == providerId);
    final providerName = providerId == 'custom'
        ? settings.customCloudName.value
        : provider?.name ?? providerId;
    final model = cloudModels.activeModelFor(providerId);
    final hasSelectedModel =
        cloudModels.canSelectModel(providerId) && model.isNotEmpty;

    return _ActiveCard(
      icon: Icons.cloud_outlined,
      title: hasSelectedModel ? model : 'No online model selected',
      meta: 'Cloud · $providerName',
      dot: hasSelectedModel ? t.accent : t.faint,
      action: PillButton(
        label: 'Change',
        onPressed: provider == null
            ? null
            : () {
                if (providerId == 'custom') {
                  _showCustomProviderSheet(context, cloudModels);
                } else {
                  _showProviderActionsSheet(context, cloudModels, provider);
                }
              },
      ),
    );
  }

  // ── Progress ──────────────────────────────────────────────────────────

  Widget _buildModelLoadingProgress(BuildContext context, AiModel model) {
    return Obx(() {
      final t = AppTokens.of(context);
      final inference = Get.find<InferenceService>();
      final localImage = Get.find<LocalImageService>();
      final textLoading = inference.isLoadingModel.value &&
          inference.loadingModelName.value == model.filename;
      // Image models report no percentage, so their bar is indeterminate.
      final unzipped = model.filename.toLowerCase().endsWith('.zip')
          ? model.filename.substring(0, model.filename.length - 4)
          : model.filename;
      final imageLoading = localImage.isLoadingModel.value &&
          (localImage.loadingModelName.value == model.filename ||
              localImage.loadingModelName.value == unzipped);
      if (!textLoading && !imageLoading) return const SizedBox.shrink();
      final progress = textLoading ? inference.modelLoadProgress.value : 0.0;

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 1.6,
                  color: t.orange,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Loading into memory',
                    style: t.caption.copyWith(color: t.text)),
              ),
              if (progress > 0)
                Text(
                  '${(progress * 100).clamp(0.0, 100.0).toStringAsFixed(0)}%',
                  style: t.small.copyWith(fontFeatures: _tabular),
                ),
            ],
          ),
          const SizedBox(height: 10),
          AppProgressBar(value: progress > 0 ? progress : null),
          const SizedBox(height: 6),
          Text(
            model.filename,
            style: t.small.copyWith(color: t.faint),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      );
    });
  }

  Widget _buildImportingProgress(BuildContext context) {
    return Obx(() {
      if (!controller.isImporting.value) return const SizedBox.shrink();
      // Downloads (including "save to Downloads folder") show in the pinned
      // downloads card; this card is only for file imports.
      if (controller.importStatus.value.toLowerCase().contains('download') &&
          controller.activeDownloads
              .containsKey(controller.importFileName.value)) {
        return const SizedBox.shrink();
      }
      final t = AppTokens.of(context);
      final percent = controller.importProgress * 100;
      final total = controller.importTotalBytes.value;
      final copied = controller.importCopiedBytes.value;
      final remaining = total <= 0 ? 0 : (total - copied).clamp(0, total);
      final isDownload =
          controller.importStatus.value.toLowerCase().contains('download');

      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: AppCard(
          padding: const EdgeInsets.fromLTRB(6, 6, 10, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  IconBadge(
                    isDownload
                        ? Icons.download_rounded
                        : Icons.file_upload_outlined,
                    size: 32,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(isDownload ? 'Downloading' : 'Importing',
                            style: t.bodyStrong),
                        const SizedBox(height: 2),
                        Text(
                          '${controller.importStatus.value} ${controller.importFileName.value}',
                          style: t.small,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  if (controller.externalDownloadId.value != null)
                    _IconAction(
                      icon: Icons.close_rounded,
                      tooltip: 'Cancel download',
                      destructive: true,
                      onPressed: controller.cancelExternalDownload,
                    ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 12),
                    AppProgressBar(
                      value: controller.importProgress > 0
                          ? controller.importProgress
                          : null,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      [
                        '${percent.toStringAsFixed(0)}%',
                        '${DownloadService.formatWholeMb(copied)} of ${DownloadService.formatWholeMb(total)}',
                        DownloadService.formatSpeed(
                            controller.importBytesPerSecond.value),
                        '${DownloadService.formatWholeMb(remaining)} left',
                      ].join(' · '),
                      style: t.small.copyWith(fontFeatures: _tabular),
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

  // ── Online providers ──────────────────────────────────────────────────

  Widget _buildOnlineProviders(BuildContext context) {
    final cloud = Get.find<CloudModelController>();
    return Obx(() {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionHeader('Providers',
              padding: EdgeInsets.fromLTRB(0, 12, 12, 4)),
          AppGroup(
            children: [
              for (final provider in cloud.providers)
                _buildOnlineProviderRow(context, cloud, provider),
            ],
          ),
          const SectionFootnote(
              'Tap a provider to choose a model. Keys are stored on this device.'),
        ],
      );
    });
  }

  Widget _buildOnlineProviderRow(
    BuildContext context,
    CloudModelController cloud,
    CloudProviderInfo provider,
  ) {
    final t = AppTokens.of(context);
    final settings = Get.find<SettingsController>();
    final isCustom = provider.id == 'custom';
    final isActive = cloud.activeProvider == provider.id;
    final canUse = cloud.canSelectModel(provider.id);
    final model = cloud.activeModelFor(provider.id);
    final hasSelectedModel = canUse && model.isNotEmpty;
    final name = isCustom ? settings.customCloudName.value : provider.name;
    final error = cloud.errorByProvider[provider.id];
    final meta = hasSelectedModel
        ? model
        : canUse
            ? 'No model selected'
            : cloud.statusLabel(provider.id) == 'Needs Key'
                ? 'Needs API key'
                : cloud.statusLabel(provider.id);

    return InkWell(
      onTap: () => isCustom
          ? _showCustomProviderSheet(context, cloud)
          : _openProviderFlow(context, cloud, provider),
      splashFactory: NoSplash.splashFactory,
      highlightColor: t.surfacePressed,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                IconBadge(provider.icon, size: 32),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              name.isEmpty ? provider.name : name,
                              style: t.rowTitle
                                  .copyWith(fontWeight: FontWeight.w600),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 1),
                      Row(
                        children: [
                          StatusDot(canUse ? t.green : t.faint),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              meta,
                              style: t.rowSubtitle.copyWith(
                                  color: hasSelectedModel ? t.text : t.muted),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (isActive && hasSelectedModel) ...[
                  const SizedBox(width: 8),
                  AppTag('Active', color: t.accent),
                ],
                const SizedBox(width: 4),
                _IconAction(
                  icon: Icons.more_horiz_rounded,
                  tooltip: 'Provider settings',
                  onPressed: () =>
                      _showProviderActionsSheet(context, cloud, provider),
                ),
              ],
            ),
            if (error != null) ...[
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.only(right: 10),
                child: _buildErrorBox(context, error),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _openProviderFlow(
    BuildContext context,
    CloudModelController cloud,
    CloudProviderInfo provider,
  ) async {
    if (!cloud.canSelectModel(provider.id)) {
      _showProviderKeyDialog(
        context,
        cloud,
        provider,
        openModelsAfterSave: true,
      );
      return;
    }

    await cloud.refreshModels(provider.id);
    if (!context.mounted) return;
    if ((cloud.errorByProvider[provider.id] ?? '').isNotEmpty) {
      _showProviderKeyDialog(
        context,
        cloud,
        provider,
        openModelsAfterSave: true,
      );
      return;
    }
    _showModelSelectSheet(context, cloud, provider);
  }

  void _showProviderActionsSheet(
    BuildContext context,
    CloudModelController cloud,
    CloudProviderInfo provider,
  ) {
    final settings = Get.find<SettingsController>();
    final isCustom = provider.id == 'custom';

    showAppSheet<void>(
      context,
      builder: (ctx) => Obx(() {
        final t = AppTokens.of(ctx);
        final model = cloud.activeModelFor(provider.id);
        final configured = cloud.isConfigured(provider.id);
        final name = isCustom ? settings.customCloudName.value : provider.name;

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                IconBadge(provider.icon, size: 44),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name.isEmpty ? provider.name : name,
                        style: GoogleFonts.inter(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.5,
                          color: t.text,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        model.isEmpty ? provider.description : model,
                        style: t.caption,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            AppGroup(
              children: [
                if (!isCustom)
                  AppRow(
                    icon: Icons.key_outlined,
                    title: configured ? 'Update API key' : 'Add API key',
                    subtitle: 'Required before selecting live models',
                    chevron: true,
                    onTap: () {
                      Navigator.pop(ctx);
                      _showProviderKeyDialog(
                        context,
                        cloud,
                        provider,
                        openModelsAfterSave: true,
                      );
                    },
                  ),
                AppRow(
                  icon:
                      isCustom ? Icons.tune_rounded : Icons.smart_toy_outlined,
                  title: isCustom ? 'Configure and select' : 'Select model',
                  subtitle: isCustom
                      ? 'Set base URL, key, and model ID'
                      : 'Search provider models or enter a model ID',
                  chevron: true,
                  onTap: () {
                    Navigator.pop(ctx);
                    if (isCustom) {
                      _showCustomProviderSheet(context, cloud);
                    } else {
                      _openProviderFlow(context, cloud, provider);
                    }
                  },
                ),
              ],
            ),
          ],
        );
      }),
    );
  }

  void _showProviderKeyDialog(
    BuildContext context,
    CloudModelController cloud,
    CloudProviderInfo provider, {
    bool openModelsAfterSave = false,
  }) {
    final keyController = cloud.apiKeyControllerFor(provider.id);
    final obscureKey = true.obs;
    final isVerifying = false.obs;

    showAppSheet<void>(
      context,
      title: '${provider.name} API key',
      subtitle: 'Save the key to verify it and load live models.',
      builder: (ctx) {
        final t = AppTokens.of(ctx);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Obx(
              () => TextField(
                controller: keyController,
                obscureText: obscureKey.value,
                autocorrect: false,
                enableSuggestions: false,
                style: t.mono.copyWith(fontSize: 14),
                decoration: _sheetInput(
                  ctx,
                  hint: 'Paste ${provider.name} key',
                  prefix: Icon(Icons.key_outlined, size: 18, color: t.muted),
                  suffix: IconButton(
                    tooltip: obscureKey.value ? 'Show API key' : 'Hide API key',
                    onPressed: () => obscureKey.value = !obscureKey.value,
                    icon: Icon(
                      obscureKey.value
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                      size: 20,
                      color: t.muted,
                    ),
                  ),
                ),
              ),
            ),
            Obx(() {
              final error = cloud.errorByProvider[provider.id];
              if (error == null || error.isEmpty) {
                return const SizedBox.shrink();
              }
              return Padding(
                padding: const EdgeInsets.only(top: 12),
                child: _buildErrorBox(ctx, error),
              );
            }),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: TonalButton.neutral(ctx,
                      label: 'Cancel', onTap: () => Navigator.pop(ctx)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Obx(() => PrimaryButton(
                        label: isVerifying.value ? 'Verifying' : 'Save key',
                        busy: isVerifying.value,
                        onPressed: () async {
                          final value = keyController.text.trim();
                          if (value.isEmpty || isVerifying.value) return;
                          final nav = Navigator.of(ctx);
                          isVerifying.value = true;
                          await cloud.saveApiKey(provider.id, value);
                          await cloud.refreshModels(provider.id);
                          isVerifying.value = false;
                          if ((cloud.errorByProvider[provider.id] ?? '')
                              .isNotEmpty) {
                            return;
                          }
                          if (!ctx.mounted) return;
                          nav.pop();
                          if (openModelsAfterSave && context.mounted) {
                            _showModelSelectSheet(context, cloud, provider);
                          }
                        },
                      )),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  void _showCustomProviderSheet(
    BuildContext context,
    CloudModelController cloud,
  ) {
    final obscureCustomKey = true.obs;
    showAppSheet<void>(
      context,
      title: 'Custom provider',
      subtitle:
          'Use any OpenAI-compatible endpoint. Enter the base URL without /chat/completions.',
      builder: (ctx) {
        final t = AppTokens.of(ctx);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Obx(() {
              final profiles = cloud.customProfiles;
              if (profiles.isEmpty) return const SizedBox.shrink();
              final selected = cloud.customProfileIndex;
              return Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: AppField(
                  label: 'Saved provider',
                  child: Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<int>(
                          key: ValueKey(selected),
                          initialValue: selected >= 0 ? selected : null,
                          isExpanded: true,
                          borderRadius: BorderRadius.circular(12),
                          dropdownColor:
                              t.isDark ? const Color(0xFF2C2C2E) : Colors.white,
                          icon: Icon(Icons.expand_more_rounded,
                              color: t.muted, size: 20),
                          style: t.body,
                          decoration:
                              _sheetInput(ctx, hint: 'Choose a provider'),
                          items: [
                            for (var i = 0; i < profiles.length; i++)
                              DropdownMenuItem(
                                value: i,
                                child: Text(
                                  profiles[i]['name']?.isNotEmpty == true
                                      ? profiles[i]['name']!
                                      : profiles[i]['baseUrl'] ?? 'Custom API',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                          onChanged: (index) {
                            if (index != null) {
                              cloud.selectCustomProfile(index);
                            }
                          },
                        ),
                      ),
                      const SizedBox(width: 8),
                      _SquareIconButton(
                        icon: Icons.add_rounded,
                        tooltip: 'Add another provider',
                        onTap: cloud.beginNewCustomProfile,
                      ),
                    ],
                  ),
                ),
              );
            }),
            Obx(() {
              final error = cloud.customProviderError.value;
              if (error.isEmpty) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: _buildErrorBox(ctx, error),
              );
            }),
            AppField(
              label: 'Provider name',
              child: TextField(
                controller: cloud.customNameController,
                style: t.body,
                decoration: _sheetInput(ctx, hint: 'My endpoint'),
              ),
            ),
            const SizedBox(height: 14),
            AppField(
              label: 'Base URL',
              child: TextField(
                controller: cloud.customBaseUrlController,
                keyboardType: TextInputType.url,
                autocorrect: false,
                style: t.body,
                decoration: _sheetInput(ctx, hint: 'https://example.com/v1'),
              ),
            ),
            const SizedBox(height: 14),
            AppField(
              label: 'API key',
              child: Obx(
                () => TextField(
                  controller: cloud.customApiKeyController,
                  obscureText: obscureCustomKey.value,
                  autocorrect: false,
                  enableSuggestions: false,
                  style: t.mono.copyWith(fontSize: 14),
                  decoration: _sheetInput(
                    ctx,
                    hint: 'Optional for local servers',
                    suffix: IconButton(
                      tooltip: obscureCustomKey.value
                          ? 'Show API key'
                          : 'Hide API key',
                      onPressed: () =>
                          obscureCustomKey.value = !obscureCustomKey.value,
                      icon: Icon(
                        obscureCustomKey.value
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                        size: 20,
                        color: t.muted,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),
            AppField(
              label: 'Model ID',
              child: TextField(
                controller: cloud.customModelController,
                autocorrect: false,
                style: t.body,
                decoration: _sheetInput(ctx, hint: 'e.g. llama-3.1-8b'),
              ),
            ),
            const SizedBox(height: 24),
            PrimaryButton(
              label: 'Save and select',
              onPressed: () async {
                final nav = Navigator.of(ctx);
                await cloud.saveCustomProvider();
                if (cloud.customProviderError.value.isEmpty && ctx.mounted) {
                  nav.pop();
                }
              },
            ),
            const SizedBox(height: 8),
            Center(
              child: Obx(() => _TextAction(
                    label: cloud.customProfileIndex >= 0
                        ? 'Remove selected provider'
                        : 'Clear form',
                    color: t.red,
                    onTap: () async {
                      await cloud.clearCustomProvider();
                    },
                  )),
            ),
          ],
        );
      },
    );
  }

  void _showModelSelectSheet(
    BuildContext context,
    CloudModelController cloud,
    CloudProviderInfo provider,
  ) {
    if (!cloud.canSelectModel(provider.id)) {
      _showProviderKeyDialog(
        context,
        cloud,
        provider,
        openModelsAfterSave: true,
      );
      return;
    }

    cloud.searchByProvider[provider.id] = '';
    if ((cloud.modelsByProvider[provider.id] ?? const <String>[]).isEmpty) {
      cloud.refreshModels(provider.id);
    } else if (cloud.canFetchModels(provider.id) &&
        cloud.fetchedAtByProvider[provider.id] == null) {
      cloud.refreshModels(provider.id);
    }

    showAppSheet<void>(
      context,
      title: 'Select ${provider.name} model',
      scrollable: false,
      builder: (ctx) {
        final t = AppTokens.of(ctx);
        final mq = MediaQuery.of(ctx);
        // Fixed list height that shrinks with the keyboard so the sheet
        // (handle + title + this body) always fits on screen.
        final height = ((mq.size.height - mq.viewInsets.bottom) * 0.7 - 80)
            .clamp(120.0, 900.0);

        return SizedBox(
          height: height,
          child: Obx(() {
            final isLoading = cloud.isLoadingProvider[provider.id] == true;
            final error = cloud.errorByProvider[provider.id];
            final models = cloud.filteredModelsFor(provider.id);
            final activeModel = cloud.activeModelFor(provider.id);
            final isActiveProvider = cloud.activeProvider == provider.id;
            final canFetch = cloud.canFetchModels(provider.id);
            final freeFirst = cloud.freeFirstByProvider[provider.id] == true;
            final freeModelCount = cloud.freeModelCountFor(provider.id);

            Widget modelList;
            if (isLoading && models.isEmpty) {
              modelList = Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child:
                      CircularProgressIndicator(strokeWidth: 2, color: t.muted),
                ),
              );
            } else if (models.isEmpty) {
              modelList = _buildModelSelectEmptyState(ctx, provider);
            } else {
              modelList = Container(
                decoration: BoxDecoration(
                  color: _sheetSurface(t),
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: t.hairline, width: 0.5),
                ),
                clipBehavior: Clip.antiAlias,
                child: ListView.separated(
                  padding: EdgeInsets.zero,
                  itemCount: models.length,
                  separatorBuilder: (_, __) => Padding(
                    padding: const EdgeInsets.only(left: 16),
                    child: Container(height: 0.5, color: t.hairline),
                  ),
                  itemBuilder: (_, index) => _buildCloudModelRow(
                    context,
                    ctx,
                    cloud,
                    provider,
                    models[index],
                    activeModel,
                    isActiveProvider,
                  ),
                ),
              );
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  onChanged: (value) =>
                      cloud.searchByProvider[provider.id] = value,
                  style: t.body,
                  decoration: _sheetInput(
                    ctx,
                    hint: 'Search models',
                    prefix:
                        Icon(Icons.search_rounded, size: 20, color: t.muted),
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(left: 2),
                        child: Text(
                          '${models.length} models · ${cloud.fetchedLabel(provider.id)}',
                          style: t.small.copyWith(fontFeatures: _tabular),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ),
                    if (provider.id == 'openrouter' || freeModelCount > 0)
                      _TextAction(
                        icon: freeFirst
                            ? Icons.check_circle_rounded
                            : Icons.local_offer_outlined,
                        label: freeModelCount == 0
                            ? 'Free'
                            : 'Free first ($freeModelCount)',
                        color: freeFirst ? t.accent : null,
                        onTap: freeModelCount == 0
                            ? null
                            : () => cloud.toggleFreeFirst(provider.id),
                      ),
                    _TextAction(
                      icon: Icons.refresh_rounded,
                      label: 'Refresh',
                      busy: isLoading,
                      onTap: isLoading || !canFetch
                          ? null
                          : () => cloud.refreshModels(provider.id),
                    ),
                  ],
                ),
                if (error != null) ...[
                  const SizedBox(height: 8),
                  _buildErrorBox(ctx, error),
                ],
                const SizedBox(height: 10),
                Expanded(child: modelList),
                const SizedBox(height: 12),
                TonalButton.neutral(
                  ctx,
                  label: 'Use a custom model ID',
                  onTap: () =>
                      _showCustomModelIdDialog(context, cloud, provider),
                ),
              ],
            );
          }),
        );
      },
    );
  }

  Widget _buildModelSelectEmptyState(
    BuildContext context,
    CloudProviderInfo provider,
  ) {
    return const Center(
      child: SingleChildScrollView(
        child: EmptyState(
          icon: Icons.inbox_outlined,
          title: 'No models loaded',
          message:
              'Add an API key to update the live list, or use a custom model ID.',
        ),
      ),
    );
  }

  void _showCustomModelIdDialog(
    BuildContext context,
    CloudModelController cloud,
    CloudProviderInfo provider,
  ) {
    final textController =
        TextEditingController(text: cloud.activeModelFor(provider.id));
    showAppSheet<void>(
      context,
      title: 'Custom ${provider.name} model',
      subtitle: 'Enter the exact model ID the provider expects.',
      builder: (ctx) {
        final t = AppTokens.of(ctx);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppField(
              label: 'Model ID',
              child: TextField(
                controller: textController,
                autofocus: true,
                autocorrect: false,
                style: t.mono.copyWith(fontSize: 14),
                decoration: _sheetInput(ctx, hint: 'provider/model-name'),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: TonalButton.neutral(ctx,
                      label: 'Cancel', onTap: () => Navigator.pop(ctx)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: PrimaryButton(
                    label: 'Select',
                    onPressed: () async {
                      final value = textController.text.trim();
                      if (value.isEmpty) return;
                      if (!cloud.canSelectModel(provider.id)) {
                        if (provider.id == 'custom') {
                          _showCustomProviderSheet(context, cloud);
                        } else {
                          _showProviderKeyDialog(context, cloud, provider);
                        }
                        return;
                      }
                      final nav = Navigator.of(ctx);
                      await cloud.selectModel(
                        provider.id,
                        value,
                        showSnackbar: false,
                      );
                      // Close this sheet and the model list underneath it.
                      nav.pop();
                      nav.pop();
                    },
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _buildCloudModelRow(
    BuildContext pageContext,
    BuildContext sheetContext,
    CloudModelController cloud,
    CloudProviderInfo provider,
    String id,
    String activeModel,
    bool isActiveProvider,
  ) {
    final t = AppTokens.of(sheetContext);
    final providerId = provider.id;
    final normalized =
        providerId == 'google' ? id.replaceFirst('models/', '') : id;
    final canUse = cloud.canSelectModel(providerId);
    final isActive = isActiveProvider && normalized == activeModel && canUse;
    final tags = cloud.modelTagsFor(providerId, id);

    Future<void> select() async {
      if (!canUse) {
        _showProviderKeyDialog(pageContext, cloud, provider);
        return;
      }
      final nav = Navigator.of(sheetContext);
      await cloud.selectModel(
        providerId,
        id,
        showSnackbar: false,
      );
      nav.pop();
    }

    return InkWell(
      onTap: isActive ? null : select,
      splashFactory: NoSplash.splashFactory,
      highlightColor: t.surfacePressed,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  normalized,
                  style: t.body.copyWith(
                    fontSize: 14,
                    fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              for (final tag in tags) ...[
                const SizedBox(width: 6),
                AppTag(tag == 'FREE' ? 'Free' : tag),
              ],
              const SizedBox(width: 10),
              if (isActive)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Icon(Icons.check_rounded, size: 20, color: t.accent),
                )
              else
                PillButton(
                  label: canUse ? 'Select' : 'Add key',
                  onPressed: select,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildErrorBox(BuildContext context, String error) {
    return AppNotice(
      error,
      icon: Icons.error_outline_rounded,
      color: AppTokens.of(context).red,
    );
  }

  // ── Local model cards ─────────────────────────────────────────────────

  List<AppTag> _buildModelTags(BuildContext context, AiModel model) {
    final filter = controller.localFilter.value.isEmpty
        ? controller.defaultLocalFilter
        : controller.localFilter.value;
    return [
      if (model.recommendedFor.contains(filter))
        AppTag('Recommended',
            icon: Icons.star_rounded, color: AppTokens.of(context).accent),
      if (controller.isVisionModel(model))
        const AppTag('Vision', icon: Icons.visibility_outlined),
      if (controller.isImageModel(model))
        const AppTag('Image', icon: Icons.image_outlined),
      if (controller.isNpuModel(model)) const AppTag('NPU'),
      if (controller.isUncensoredModel(model)) const AppTag('Uncensored'),
      if (model.isImported) const AppTag('Imported'),
      if (model.isCustom) const AppTag('Custom'),
    ];
  }

  void _confirmDownload(BuildContext context, AiModel model,
      {bool isToDownloadsFolder = false}) {
    showAppSheet<void>(
      context,
      title: isToDownloadsFolder ? 'Save to Downloads' : 'Download model',
      subtitle: isToDownloadsFolder
          ? 'Save ${model.name} to your phone\'s public Downloads folder.'
          : 'Download ${model.name} for use in the app.',
      builder: (ctx) {
        final t = AppTokens.of(ctx);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: _sheetSurface(t),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: t.hairline, width: 0.5),
              ),
              child: Row(
                children: [
                  Icon(Icons.sd_storage_outlined, size: 18, color: t.muted),
                  const SizedBox(width: 10),
                  Expanded(child: Text('Size', style: t.body)),
                  Text(
                    controller.modelSizeLabel(model),
                    style: t.bodyStrong.copyWith(fontFeatures: _tabular),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            AppNotice(
              'Wi-Fi is recommended. Keep the app open while it downloads.',
              icon: Icons.wifi_rounded,
              color: t.orange,
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(
                  child: TonalButton.neutral(ctx,
                      label: 'Cancel', onTap: () => Navigator.of(ctx).pop()),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: PrimaryButton(
                    label: isToDownloadsFolder ? 'Save' : 'Download',
                    onPressed: () {
                      Navigator.of(ctx).pop();
                      if (isToDownloadsFolder) {
                        controller.downloadModelToDownloads(model);
                      } else {
                        controller.downloadModel(model);
                      }
                    },
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  Future<void> _confirmDeleteModel(
      BuildContext context, String filename) async {
    final confirmed = await confirmSheet(
      context,
      title: 'Delete model?',
      message: '$filename will be permanently removed from this device.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (confirmed) await controller.deleteModel(filename);
  }

  Widget _buildModelCard(BuildContext context, AiModel model,
      {bool library = false}) {
    return Obx(() {
      final t = AppTokens.of(context);
      final actualFilename = model.filename.toLowerCase().endsWith('.zip')
          ? model.filename.substring(0, model.filename.length - 4)
          : model.filename;

      final isDownloaded = controller.isDownloaded(model.filename);
      final inference = Get.find<InferenceService>();
      final localImage = Get.find<LocalImageService>();
      final isActive = inference.loadedModelName.value == actualFilename ||
          localImage.loadedModelName.value == actualFilename;
      final isCurrentlyDownloading =
          controller.isDownloadingModel(model.filename);
      final isAnyModelLoading =
          inference.isLoadingModel.value || localImage.isLoadingModel.value;
      final isThisTextModelLoading = inference.isLoadingModel.value &&
          inference.loadingModelName.value == actualFilename;
      final isThisImageModelLoading = localImage.isLoadingModel.value &&
          localImage.loadingModelName.value == actualFilename;
      final isThisModelLoading =
          isThisTextModelLoading || isThisImageModelLoading;
      final disableActions = controller.isImporting.value ||
          isAnyModelLoading ||
          isCurrentlyDownloading;
      final loadPercent = (inference.modelLoadProgress.value * 100)
          .clamp(0.0, 100.0)
          .toStringAsFixed(0);

      final runtime = controller.isLiteRtModel(model)
          ? 'LiteRT'
          : controller.isLlamaModel(model)
              ? 'GGUF'
              : null;

      // Primary action (right). While downloading: a progress ring with the
      // percentage (cancel lives in the pinned downloads card at the top).
      final Widget primaryAction;
      if (isCurrentlyDownloading) {
        primaryAction = _DownloadRing(filename: model.filename);
      } else if (isDownloaded) {
        if (isThisModelLoading) {
          primaryAction = Text(
              isThisImageModelLoading ? 'Loading…' : '$loadPercent%',
              style: t.small.copyWith(
                  color: t.accent,
                  fontWeight: FontWeight.w600,
                  fontFeatures: _tabular));
        } else if (isActive) {
          primaryAction = AppTag('Loaded', color: t.green);
        } else if (library) {
          primaryAction = _SoftButton(
            label: 'Load',
            onPressed: disableActions
                ? null
                : () => controller.loadModel(actualFilename),
          );
        } else {
          primaryAction = Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.check_rounded, size: 15, color: t.muted),
            const SizedBox(width: 4),
            Text('On phone', style: t.small),
          ]);
        }
      } else {
        primaryAction = _RoundIconButton(
          icon: Icons.arrow_downward_rounded,
          tooltip: 'Download',
          onPressed:
              disableActions ? null : () => _confirmDownload(context, model),
        );
      }
      final VoidCallback? load = isDownloaded && !isActive && !disableActions
          ? () => controller.loadModel(actualFilename)
          : null;

      // Secondary actions live in the ⋯ sheet.
      final secondary = <(IconData, String, bool, VoidCallback)>[
        if (!isCurrentlyDownloading && isDownloaded)
          (
            Icons.save_alt_rounded,
            model.hasVisionProjector
                ? 'Save to Downloads folder (with vision file)'
                : 'Save to Downloads folder',
            false,
            () => controller.saveToDownloads(model),
          ),
        if (!isCurrentlyDownloading && isDownloaded && !isActive)
          (
            Icons.delete_outline_rounded,
            'Delete model',
            true,
            () => _confirmDeleteModel(context, actualFilename),
          ),
        if (!isCurrentlyDownloading &&
            !isDownloaded &&
            model.url.trim().isNotEmpty)
          (
            Icons.save_alt_rounded,
            'Save to phone Downloads folder',
            false,
            () => _confirmDownload(context, model, isToDownloadsFolder: true),
          ),
        if (!isCurrentlyDownloading && !isDownloaded && model.isCustom)
          (
            Icons.playlist_remove_rounded,
            'Remove from list',
            true,
            () => _confirmRemoveCustom(context, model),
          ),
      ];

      final filter = controller.localFilter.value.isEmpty
          ? controller.defaultLocalFilter
          : controller.localFilter.value;
      final recommended = !library && model.recommendedFor.contains(filter);
      // In Browse, skip the label the selected type already implies.
      final (name, variant) = _cleanName(model);
      // Uncensored is a tag next to the name; the type is the section (My
      // models) or the selected chip (Browse), so neither repeats here.
      final uncensored = controller.isUncensoredModel(model) &&
          (library || filter != 'uncensored');
      final subtitle = [
        controller.modelSizeLabel(model),
        if (runtime == 'LiteRT') 'LiteRT',
        if (variant != null) variant,
        if (!library && controller.isVisionModel(model) && filter != 'vision')
          'Vision',
        if (model.isImported) 'Imported',
      ].join(' · ');
      void openDetails() => _showModelDetails(
          context, model, subtitle, secondary, disableActions, primaryAction,
          onLoad: load);
      return Material(
        color: Colors.transparent,
        child: InkWell(
          // Tap or long-press opens the details sheet; loading has its own
          // button on the row.
          onTap: openDetails,
          onLongPress: openDetails,
          splashFactory: NoSplash.splashFactory,
          // No pressed/focus tint at all: it could stay stuck on the row
          // after a sheet opens or a model starts loading.
          highlightColor: Colors.transparent,
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _ModelAvatar(
                        name: name,
                        image: controller.isImageModel(model),
                        loaded: isActive),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Flexible(
                              child: Text(name,
                                  style: t.rowTitle
                                      .copyWith(fontWeight: FontWeight.w500),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                            ),
                          ]),
                          const SizedBox(height: 1),
                          Row(children: [
                            Flexible(
                              child: Text.rich(
                                TextSpan(children: [
                                  if (recommended && !isActive)
                                    TextSpan(
                                      text: '★ Recommended · ',
                                      style: TextStyle(
                                          color: t.accent,
                                          fontWeight: FontWeight.w600),
                                    ),
                                  TextSpan(text: subtitle),
                                ]),
                                style: t.rowSubtitle
                                    .copyWith(fontFeatures: _tabular),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ]),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    if (uncensored) ...[
                      AppTag('Uncensored', color: t.orange),
                      const SizedBox(width: 8),
                    ],
                    primaryAction,
                  ],
                ),
                if (isDownloaded && !isCurrentlyDownloading)
                  _buildVisionFileRow(context, model),
                if (isThisModelLoading) ...[
                  const SizedBox(height: 10),
                  _buildModelLoadingProgress(context, model),
                ],
              ],
            ),
          ),
        ),
      );
    });
  }

  _TextAction _sortAction() => _TextAction(
        icon: Icons.swap_vert_rounded,
        label: controller.sortSmallestFirst.value ? 'By size' : 'By name',
        onTap: controller.toggleSort,
      );

  /// My models: everything on the phone. Tap a row to load it.
  List<Widget> _buildLibrary(BuildContext context) {
    final models = controller.displayedModels
        .where((m) => controller.isDownloaded(m.filename))
        .toList();
    if (models.isEmpty) return [_buildEmptyLibrary(context)];
    final t = AppTokens.of(context);
    final image = models.where(controller.isImageModel).toList();
    final vision = models
        .where(
            (m) => !controller.isImageModel(m) && controller.isVisionModel(m))
        .toList();
    final chat =
        models.where((m) => !image.contains(m) && !vision.contains(m)).toList();
    var first = true;
    List<Widget> group(String title, List<AiModel> list) {
      if (list.isEmpty) return const [];
      final header = SectionHeader(title,
          padding: EdgeInsets.fromLTRB(0, first ? 8 : 12, 12, 4));
      first = false;
      return [
        header,
        AppGroup(children: [
          for (final m in list) _buildModelCard(context, m, library: true),
        ]),
      ];
    }

    return [
      Padding(
        padding: EdgeInsets.zero,
        child: Row(children: [
          Expanded(
              child:
                  Text('On this phone · ${models.length}', style: t.caption)),
          _sortAction(),
        ]),
      ),
      ...group('Chat', chat),
      ...group('Vision', vision),
      ...group('Image', image),
    ];
  }

  /// Browse: the catalogue for the selected type, recommended pick first.
  List<Widget> _buildBrowse(BuildContext context) {
    final models = controller.filteredDisplayedModels;
    if (models.isEmpty) {
      return [
        const EmptyState(
            icon: Icons.search_off_rounded,
            title: 'No models here yet',
            message: 'Try another type.'),
      ];
    }
    return [
      SectionHeader('All ${models.length}',
          padding: const EdgeInsets.fromLTRB(0, 12, 0, 4),
          trailing: _sortAction()),
      AppGroup(children: [
        for (final m in models) _buildModelCard(context, m),
      ]),
    ];
  }

  // ── Featured picks ────────────────────────────────────────────────────

  static const _pitch = {
    'general': 'Best for chat',
    'vision': 'Understands photos',
    'uncensored': 'No filters',
    'image': 'Creates images',
  };

  /// Horizontal row of the recommended pick for each type.
  Widget _buildFeatured(BuildContext context) {
    final t = AppTokens.of(context);
    final picks = <AiModel>[];
    for (final type in ['general', 'vision', 'uncensored', 'image']) {
      final m = controller.availableModels
          .firstWhereOrNull((m) => m.recommendedFor.contains(type));
      if (m != null && !picks.contains(m)) picks.add(m);
    }
    if (picks.isEmpty) return const SizedBox.shrink();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(0, 0, 12, 6),
        child: Text('Recommended', style: t.label),
      ),
      SizedBox(
        height: 172,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          clipBehavior: Clip.none,
          itemCount: picks.length,
          separatorBuilder: (_, __) => const SizedBox(width: 10),
          itemBuilder: (_, i) => _buildFeaturedCard(context, picks[i]),
        ),
      ),
      const SizedBox(height: 18),
    ]);
  }

  Widget _buildFeaturedCard(BuildContext context, AiModel model) {
    return Obx(() {
      final t = AppTokens.of(context);
      final (name, _) = _cleanName(model);
      final downloaded = controller.isDownloaded(model.filename);
      final downloading = controller.isDownloadingModel(model.filename);
      final busy = controller.isImporting.value ||
          Get.find<InferenceService>().isLoadingModel.value;
      final type = model.recommendedFor
          .firstWhere(_pitch.containsKey, orElse: () => 'general');
      final Widget action;
      if (downloading) {
        action = _DownloadRing(filename: model.filename);
      } else if (downloaded) {
        action = Icon(Icons.check_circle_rounded, size: 22, color: t.green);
      } else {
        action = _RoundIconButton(
          icon: Icons.arrow_downward_rounded,
          tooltip: 'Download',
          onPressed: busy ? null : () => _confirmDownload(context, model),
        );
      }
      return SizedBox(
        width: 168,
        child: Material(
          color: t.surface,
          borderRadius: BorderRadius.circular(22),
          child: InkWell(
            borderRadius: BorderRadius.circular(22),
            splashFactory: NoSplash.splashFactory,
            overlayColor: const WidgetStatePropertyAll(Colors.transparent),
            onTap: () => _showModelDetails(context, model,
                controller.modelSizeLabel(model), const [], busy, null),
            child: Padding(
              // 6 inset + 16 avatar and button radius = the card's 22.
              padding: const EdgeInsets.all(6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _ModelAvatar(
                      name: name,
                      image: controller.isImageModel(model),
                      size: 44,
                      radius: 16),
                  const Spacer(),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: t.bodyStrong.copyWith(height: 1.25)),
                          const SizedBox(height: 2),
                          Text(_pitch[type]!, style: t.small),
                        ]),
                  ),
                  const SizedBox(height: 10),
                  Row(children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: Text(controller.modelSizeLabel(model),
                            style: t.small.copyWith(fontFeatures: _tabular)),
                      ),
                    ),
                    action,
                  ]),
                ],
              ),
            ),
          ),
        ),
      );
    });
  }

  static final _quantPattern = RegExp(
      r'\b(I?Q\d(?:_[A-Z0-9]+)*|F16|FP16|BF16|F32)\b',
      caseSensitive: false);

  /// Short display name plus the variant (quant or format) shown as detail:
  /// "Gemma 3 1B Instruct (Q4_0)" → ("Gemma 3 1B", "Q4_0").
  (String, String?) _cleanName(AiModel model) {
    var raw = model.isImported ? _prettyModel(model.name) : model.name;
    String? variant;
    final quant = _quantPattern.firstMatch(raw);
    if (quant != null) variant = quant.group(0)!.toUpperCase();

    // Parenthesised extras: drop the quant / runtime, keep e.g. "SD 1.5".
    final extras = <String>[];
    raw = raw.replaceAllMapped(RegExp(r'\(([^)]*)\)'), (m) {
      final inner = m.group(1)!.trim();
      if (!_quantPattern.hasMatch(inner) &&
          !inner.toLowerCase().startsWith('litert')) {
        extras.add(inner);
      }
      return ' ';
    });
    raw = raw.replaceAll(_quantPattern, ' ');

    // File-style names ("qwen2.5-1.5b-instruct"): split and capitalise.
    final fileStyle = model.isImported || raw == raw.toLowerCase();
    final words = raw
        .split(fileStyle ? RegExp(r'[\s_-]+') : RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .where((w) =>
            !{'instruct', 'uncensored', 'it', 'gguf'}.contains(w.toLowerCase()))
        .map((w) {
      if (!fileStyle) return w;
      if (RegExp(r'^(e?\d+(\.\d+)?[bm])$', caseSensitive: false).hasMatch(w)) {
        return w.toUpperCase();
      }
      return w[0].toUpperCase() + w.substring(1);
    }).toList();
    final name = words.join(' ').trim();
    final detail = [if (variant != null) variant, ...extras];
    return (
      name.isEmpty ? model.name : name,
      detail.isEmpty ? null : detail.join(' · ')
    );
  }

  /// ⋯ sheet: full description, details and the less common actions.
  void _showModelDetails(
    BuildContext context,
    AiModel model,
    String meta,
    List<(IconData, String, bool, VoidCallback)> actions,
    bool disabled,
    Widget? primaryAction, {
    VoidCallback? onLoad,
  }) {
    final downloaded = controller.isDownloaded(model.filename);
    showAppSheet<void>(
      context,
      title: model.name,
      subtitle: meta,
      builder: (ctx) {
        final t = AppTokens.of(ctx);
        final tags = _buildModelTags(ctx, model);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (model.description.trim().isNotEmpty)
              Text(model.description, style: t.body.copyWith(color: t.muted)),
            if (tags.isNotEmpty) ...[
              const SizedBox(height: 12),
              Wrap(spacing: 6, runSpacing: 6, children: tags),
            ],
            if (onLoad != null) ...[
              const SizedBox(height: 18),
              PrimaryButton(
                label: 'Load model',
                icon: Icons.play_arrow_rounded,
                onPressed: () {
                  Navigator.pop(ctx);
                  onLoad();
                },
              ),
            ],
            if (!downloaded && !disabled) ...[
              const SizedBox(height: 18),
              PrimaryButton(
                label: 'Download',
                icon: Icons.arrow_downward_rounded,
                onPressed: () {
                  Navigator.pop(ctx);
                  _confirmDownload(context, model);
                },
              ),
            ],
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 18),
              AppGroup(children: [
                for (final (icon, label, destructive, onTap) in actions)
                  AppRow(
                    icon: icon,
                    title: label,
                    destructive: destructive,
                    onTap: disabled
                        ? null
                        : () {
                            Navigator.pop(ctx);
                            onTap();
                          },
                  ),
              ]),
            ],
          ],
        );
      },
    );
  }

  /// For a downloaded vision model whose vision file isn't on disk yet
  /// (e.g. the main file was imported): one tap fetches it in-app.
  Widget _buildVisionFileRow(BuildContext context, AiModel model) {
    // Decide outside Obx: an Obx that reads no observable throws in GetX.
    if (!model.hasVisionProjector || model.mmprojUrl.isEmpty) {
      return const SizedBox.shrink();
    }
    return Obx(() {
      if (controller.isVisionFileReady(model)) {
        return const SizedBox.shrink();
      }
      final downloading = controller.isDownloadingModel(model.mmprojFilename);
      final size = controller.visionFileSizeLabel(model);
      return Padding(
        padding: const EdgeInsets.only(top: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppNotice(
              downloading
                  ? 'Downloading the vision file… images will work once it finishes.'
                  : 'Supports images. Download its vision file'
                      '${size.isEmpty ? '' : ' ($size)'} to use them; '
                      'text chat works without it.',
              icon: Icons.visibility_outlined,
            ),
            if (!downloading) ...[
              const SizedBox(height: 10),
              PillButton(
                label: 'Download vision file',
                icon: Icons.download_rounded,
                primary: true,
                onPressed: () => controller.downloadVisionFile(model),
              ),
            ],
          ],
        ),
      );
    });
  }

  Future<void> _confirmRemoveCustom(BuildContext context, AiModel model) async {
    final confirmed = await confirmSheet(
      context,
      title: 'Remove from list?',
      message: '${model.name} will be removed from your models. You can add it '
          'again later with the correct URL.',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (confirmed) await controller.removeCustomModel(model);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Small shared pieces
// ─────────────────────────────────────────────────────────────────────────────

/// Calm summary card for the model currently in use (mirrors the home card).
class _ActiveCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String meta;
  final Color dot;
  final Widget action;

  const _ActiveCard({
    required this.icon,
    required this.title,
    required this.meta,
    required this.dot,
    required this.action,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return AppCard(
      padding: const EdgeInsets.all(6),
      child: Row(children: [
        IconBadge(icon, size: 32),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: t.rowTitle.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 1),
                Row(children: [
                  StatusDot(dot),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style:
                            t.rowSubtitle.copyWith(fontFeatures: _tabular)),
                  ),
                ]),
              ]),
        ),
        const SizedBox(width: 10),
        action,
      ]),
    );
  }
}

/// Circular download progress with the percentage inside, sized like the
/// row's round buttons.
class _DownloadRing extends StatelessWidget {
  final String filename;
  const _DownloadRing({required this.filename});

  @override
  Widget build(BuildContext context) {
    final controller = Get.find<ModelController>();
    return Obx(() {
      final t = AppTokens.of(context);
      final dp = controller.getDownloadProgress(filename);
      final value = dp?.progress.value ?? 0;
      final pct = (value * 100).clamp(0.0, 100.0).round();
      return SizedBox(
        width: 32,
        height: 32,
        child: Stack(alignment: Alignment.center, children: [
          SizedBox(
            width: 30,
            height: 30,
            child: CircularProgressIndicator(
              value: value > 0 ? value : null,
              strokeWidth: 2.5,
              strokeCap: StrokeCap.round,
              color: t.accent,
              backgroundColor: t.fill,
            ),
          ),
          Text('$pct%',
              style: t.small.copyWith(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: t.text,
                  fontFeatures: _tabular)),
        ]),
      );
    });
  }
}

/// Soft accent pill ("Load") for list rows.
class _SoftButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  const _SoftButton({required this.label, this.onPressed});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Opacity(
      opacity: onPressed == null ? 0.45 : 1,
      child: Material(
        color: t.accent.withValues(alpha: t.isDark ? 0.18 : 0.10),
        borderRadius: BorderRadius.circular(999),
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Text(label,
                style: t.small.copyWith(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: t.accent)),
          ),
        ),
      ),
    );
  }
}

/// Small round icon button (download) for list rows.
class _RoundIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  const _RoundIconButton(
      {required this.icon, required this.tooltip, this.onPressed});

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Tooltip(
      message: tooltip,
      child: Opacity(
        opacity: onPressed == null ? 0.45 : 1,
        child: Material(
          color: t.fill,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: SizedBox(
              width: 32,
              height: 32,
              child: Icon(icon, size: 18, color: t.text.withValues(alpha: 0.8)),
            ),
          ),
        ),
      ),
    );
  }
}

/// Small muted text button (sort toggle, refresh, filters).
class _TextAction extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final Color? color;
  final bool busy;

  const _TextAction({
    required this.label,
    this.icon,
    this.onTap,
    this.color,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final fg = onTap == null && !busy ? t.faint : (color ?? t.muted);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      splashFactory: NoSplash.splashFactory,
      highlightColor: t.fill,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy)
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 1.6, color: fg),
              )
            else if (icon != null)
              Icon(icon, size: 15, color: fg),
            if (busy || icon != null) const SizedBox(width: 5),
            Text(
              label,
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: fg,
                fontFeatures: _tabular,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Compact round icon button for secondary row actions.
class _IconAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final bool destructive;

  const _IconAction({
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final color = onPressed == null
        ? t.faint
        : destructive
            ? t.red
            : t.muted;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onPressed,
          splashFactory: NoSplash.splashFactory,
          highlightColor: t.fill,
          child: SizedBox(
            width: 32,
            height: 32,
            child: Icon(icon, size: 19, color: color),
          ),
        ),
      ),
    );
  }
}

/// Square neutral icon button that matches the height of a text field.
class _SquareIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  const _SquareIconButton({
    required this.icon,
    required this.tooltip,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    return Tooltip(
      message: tooltip,
      child: Material(
        color: t.isDark ? Colors.white.withValues(alpha: 0.07) : t.fill,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            width: 46,
            height: 46,
            child: Center(
              child: Icon(icon,
                  size: 20,
                  color:
                      onTap == null ? t.faint : t.text.withValues(alpha: 0.8)),
            ),
          ),
        ),
      ),
    );
  }
}

/// Checklist of model files found in a folder. Files already in the app
/// are shown but can't be picked again.
class _FolderImportList extends StatefulWidget {
  final List<FolderModelFile> files;
  final ModelController controller;
  const _FolderImportList({required this.files, required this.controller});

  @override
  State<_FolderImportList> createState() => _FolderImportListState();
}

class _FolderImportListState extends State<_FolderImportList> {
  late final Set<String> _selected = {
    for (final f in widget.files)
      if (!_imported(f)) f.uri,
  };

  bool _imported(FolderModelFile f) => widget.controller.isDownloaded(f.name);

  static String _size(int bytes) => bytes >= 1024 * 1024 * 1024
      ? '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB'
      : '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final picked =
        widget.files.where((f) => _selected.contains(f.uri)).toList();
    final total = picked.fold<int>(0, (sum, f) => sum + f.size);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      AppGroup(children: [
        for (final f in widget.files)
          AppRow(
            title: f.name,
            subtitle: _imported(f)
                ? '${_size(f.size)} · Already in the app'
                : _size(f.size),
            trailing: Checkbox(
              value: _imported(f) ? true : _selected.contains(f.uri),
              onChanged: _imported(f)
                  ? null
                  : (v) => setState(() => v == true
                      ? _selected.add(f.uri)
                      : _selected.remove(f.uri)),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(5)),
              activeColor: t.accent,
            ),
            onTap: _imported(f)
                ? null
                : () => setState(() => _selected.contains(f.uri)
                    ? _selected.remove(f.uri)
                    : _selected.add(f.uri)),
          ),
      ]),
      const SizedBox(height: 16),
      PrimaryButton(
        label: picked.isEmpty
            ? 'Nothing selected'
            : 'Import ${picked.length} · ${_size(total)}',
        icon: Icons.download_rounded,
        onPressed: picked.isEmpty ? null : () => Navigator.pop(context, picked),
      ),
      const SizedBox(height: 8),
      Text('Files are copied into app storage, so make sure there is room.',
          textAlign: TextAlign.center, style: t.small),
    ]);
  }
}

/// Rounded monogram tile coloured by model family, so rows are easy to tell
/// apart at a glance.
class _ModelAvatar extends StatelessWidget {
  final String name;
  final bool image;
  final bool loaded;
  final double size;
  final double? radius;
  const _ModelAvatar(
      {required this.name,
      this.image = false,
      this.loaded = false,
      this.size = 32,
      this.radius});

  static const _families = <(String, String, Color)>[
    ('gemma', 'Ge', Color(0xFF4285F4)),
    ('qwen', 'Qw', Color(0xFF7C5CFF)),
    ('lfm', 'LF', Color(0xFF14B8A6)),
    ('llama', 'Ll', Color(0xFFF97316)),
    ('phi', 'Ph', Color(0xFF6366F1)),
    ('mistral', 'Mi', Color(0xFFF59E0B)),
    ('deepseek', 'DS', Color(0xFF0EA5E9)),
    ('smol', 'Sm', Color(0xFF22C55E)),
    ('minicpm', 'Mc', Color(0xFFE11D48)),
  ];
  static const _fallback = [
    Color(0xFF8B5CF6),
    Color(0xFF06B6D4),
    Color(0xFF84CC16),
    Color(0xFFEC4899),
    Color(0xFFF59E0B),
  ];

  (String, Color) _style() {
    final lower = name.toLowerCase();
    if (image) {
      final letters = name.replaceAll(RegExp(r'[^A-Za-z]'), '');
      return (
        letters.length >= 2 ? letters.substring(0, 2) : 'SD',
        const Color(0xFFEC4899)
      );
    }
    for (final (key, mono, color) in _families) {
      if (lower.contains(key)) return (mono, color);
    }
    final letters = name.replaceAll(RegExp(r'[^A-Za-z]'), '');
    final mono = letters.isEmpty
        ? '?'
        : letters.substring(0, letters.length >= 2 ? 2 : 1);
    return (mono, _fallback[name.hashCode.abs() % _fallback.length]);
  }

  @override
  Widget build(BuildContext context) {
    final t = AppTokens.of(context);
    final (mono, color) = _style();
    return SizedBox(
      width: size,
      height: size,
      child: Stack(clipBehavior: Clip.none, children: [
        Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: color.withValues(alpha: t.isDark ? 0.22 : 0.14),
            borderRadius: BorderRadius.circular(radius ?? size / 2),
          ),
          child: Text(
            mono[0].toUpperCase() + mono.substring(1),
            style: GoogleFonts.inter(
              fontSize: size * 0.36,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.3,
              color: t.isDark ? Color.lerp(color, Colors.white, 0.35) : color,
            ),
          ),
        ),
        if (loaded)
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: t.green,
                shape: BoxShape.circle,
                border: Border.all(color: t.surface, width: 2),
              ),
            ),
          ),
      ]),
    );
  }
}
