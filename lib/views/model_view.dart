import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import '../controllers/cloud_model_controller.dart';
import '../controllers/model_controller.dart';
import '../controllers/settings_controller.dart';
import '../core/colors.dart';
import '../models/ai_model.dart';
import '../services/download_service.dart';
import '../services/inference_service.dart';

class ModelView extends GetView<ModelController> {
  const ModelView({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Models',
            style: GoogleFonts.inter(fontWeight: FontWeight.w700)),
        actions: [
          Obx(() {
            if (controller.modelScope.value != 'local') {
              return const SizedBox.shrink();
            }
            return Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.add_link),
                  tooltip: 'Add Model URL',
                  onPressed: () => _showAddUrlDialog(context),
                ),
                IconButton(
                  icon: const Icon(Icons.file_upload_outlined),
                  tooltip: 'Import from Storage',
                  onPressed: () => controller.importModelFromStorage(),
                ),
              ],
            );
          }),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          if (controller.modelScope.value == 'local') {
            await controller.refreshDownloaded();
          }
        },
        color: AppColors.primary,
        child: Obx(() => ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _buildScopeToggle(context),
                const SizedBox(height: 14),
                // Active model banner
                _buildActiveModelBanner(context),
                const SizedBox(height: 12),

                if (controller.modelScope.value == 'local') ...[
                  _buildImportingProgress(context),
                  _buildLocalSummary(context),
                  const SizedBox(height: 10),
                  _buildLocalFilterChips(context),
                  const SizedBox(height: 12),
                  Text(
                    'LOCAL MODELS (${controller.filteredDisplayedModels.length})',
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: Theme.of(context).hintColor,
                      letterSpacing: 1.2,
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (controller.filteredDisplayedModels.isEmpty)
                    _buildEmptyLocalState(context)
                  else
                    ...controller.filteredDisplayedModels
                        .map((model) => _buildModelCard(context, model)),
                ] else ...[
                  _buildOnlineProviders(context),
                ],
              ],
            )),
      ),
    );
  }

  Widget _buildScopeToggle(BuildContext context) {
    return Obx(() {
      return SegmentedButton<String>(
        segments: const [
          ButtonSegment(
            value: 'local',
            icon: Icon(Icons.phone_android),
            label: Text('Local'),
          ),
          ButtonSegment(
            value: 'online',
            icon: Icon(Icons.cloud_outlined),
            label: Text('Online'),
          ),
        ],
        selected: {controller.modelScope.value},
        onSelectionChanged: (selection) =>
            controller.modelScope.value = selection.first,
      );
    });
  }

  Widget _buildLocalActions(BuildContext context) {
    final inference = Get.find<InferenceService>();
    return Row(
      children: [
        Expanded(
          child: Obx(() => OutlinedButton.icon(
                onPressed: controller.isImporting.value ||
                        inference.isLoadingModel.value
                    ? null
                    : () => _showAddUrlDialog(context),
                icon: const Icon(Icons.add_link, size: 16),
                label: const Text('URL'),
              )),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Obx(() => OutlinedButton.icon(
                onPressed: controller.isImporting.value ||
                        inference.isLoadingModel.value
                    ? null
                    : () => controller.importModelFromStorage(),
                icon: const Icon(Icons.file_upload_outlined, size: 16),
                label: const Text('Import'),
              )),
        ),
      ],
    );
  }

  Widget _buildLocalSummary(BuildContext context) {
    return Obx(() {
      final active = controller.activeLocalModelName;
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          'Downloaded: ${controller.downloadedCount} · Total: ${controller.displayedModels.length}'
          '${active.isEmpty ? '' : ' · Active: $active'}',
          style: GoogleFonts.inter(
            fontSize: 12,
            color: Theme.of(context).hintColor,
            fontWeight: FontWeight.w600,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      );
    });
  }

  Widget _buildLocalFilterChips(BuildContext context) {
    const labels = {
      'downloaded': 'Downloaded',
      'general': 'General',
      'uncensored': 'Uncensored',
      'vision': 'Vision',
    };
    return Obx(() {
      final selected = controller.localFilter.value.isEmpty
          ? controller.defaultLocalFilter
          : controller.localFilter.value;
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final entry in labels.entries) ...[
              ChoiceChip(
                label: Text(entry.value),
                selected: selected == entry.key,
                onSelected: (_) => controller.setLocalFilter(entry.key),
                selectedColor: AppColors.primary.withValues(alpha: 0.18),
                labelStyle: GoogleFonts.inter(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: selected == entry.key
                      ? AppColors.primary
                      : Theme.of(context).hintColor,
                ),
              ),
              const SizedBox(width: 8),
            ],
          ],
        ),
      );
    });
  }

  Widget _buildEmptyLocalState(BuildContext context) {
    final filter = controller.localFilter.value.isEmpty
        ? controller.defaultLocalFilter
        : controller.localFilter.value;
    final title = filter == 'downloaded'
        ? 'No downloaded models yet'
        : 'No ${filter == 'vision' ? 'vision' : filter} models found';
    final subtitle = filter == 'downloaded'
        ? 'Import a local model or add a downloadable URL.'
        : 'Try another filter or add a custom model URL.';

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).dividerColor, width: 0.5),
      ),
      child: Column(
        children: [
          Icon(Icons.search_off, size: 32, color: Theme.of(context).hintColor),
          const SizedBox(height: 10),
          Text(
            title,
            style: GoogleFonts.inter(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: Theme.of(context).colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: GoogleFonts.inter(
              fontSize: 12,
              color: Theme.of(context).hintColor,
            ),
          ),
          if (filter == 'downloaded') ...[
            const SizedBox(height: 14),
            _buildLocalActions(context),
          ],
        ],
      ),
    );
  }

  void _showAddUrlDialog(BuildContext context) {
    final nameController = TextEditingController();
    final urlController = TextEditingController();
    final filenameController = TextEditingController();
    final sizeController = TextEditingController();
    final descriptionController = TextEditingController();
    final templateController = TextEditingController(text: 'chatml');
    final isVision = false.obs;
    final isDetecting = false.obs;

    Get.dialog(AlertDialog(
      title: Text('Add Model URL',
          style: GoogleFonts.inter(fontWeight: FontWeight.w700)),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: urlController,
              decoration: const InputDecoration(labelText: 'Model URL'),
              onChanged: (value) {
                if (filenameController.text.trim().isEmpty &&
                    value.trim().isNotEmpty) {
                  filenameController.text =
                      controller.filenameFromUrl(value.trim());
                }
              },
            ),
            const SizedBox(height: 10),
            TextField(
                controller: nameController,
                decoration: const InputDecoration(labelText: 'Display name')),
            const SizedBox(height: 10),
            TextField(
                controller: filenameController,
                decoration: const InputDecoration(labelText: 'Filename')),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                    child: TextField(
                        controller: sizeController,
                        decoration: const InputDecoration(labelText: 'Size'))),
                const SizedBox(width: 8),
                Obx(() => IconButton(
                      tooltip: 'Detect size',
                      onPressed: isDetecting.value
                          ? null
                          : () async {
                              final url = urlController.text.trim();
                              if (url.isEmpty) return;
                              isDetecting.value = true;
                              try {
                                sizeController.text =
                                    await controller.detectUrlSize(url);
                              } finally {
                                isDetecting.value = false;
                              }
                            },
                      icon: isDetecting.value
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.speed),
                    )),
              ],
            ),
            const SizedBox(height: 10),
            TextField(
                controller: templateController,
                decoration: const InputDecoration(labelText: 'Template')),
            const SizedBox(height: 10),
            TextField(
                controller: descriptionController,
                decoration: const InputDecoration(labelText: 'Description')),
            const SizedBox(height: 8),
            Obx(() => SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: isVision.value,
                  onChanged: (value) => isVision.value = value,
                  title: Text('Vision model',
                      style: GoogleFonts.inter(fontSize: 13)),
                )),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: Get.back, child: const Text('Cancel')),
        ElevatedButton(
          onPressed: () async {
            final url = urlController.text.trim();
            if (url.isEmpty) return;
            await controller.addModelFromUrl(
              name: nameController.text,
              url: url,
              filename: filenameController.text,
              size: sizeController.text,
              description: descriptionController.text,
              template: templateController.text,
              isVision: isVision.value,
            );
            Get.back();
          },
          child: const Text('Add'),
        ),
      ],
    ));
  }

  Widget _buildActiveModelBanner(BuildContext context) {
    return Obx(() {
      if (controller.modelScope.value == 'online') {
        return _buildActiveCloudBanner(context);
      }

      final inference = Get.find<InferenceService>();
      if (!inference.isModelLoaded.value) {
        return const SizedBox.shrink();
      }

      final percent = inference.modelLoadProgress.value * 100;
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              AppColors.primary.withValues(alpha: 0.15),
              AppColors.secondary.withValues(alpha: 0.1),
            ],
          ),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                inference.isGpuAccelerated.value ? Icons.bolt : Icons.memory,
                color: inference.isGpuAccelerated.value
                    ? AppColors.warning
                    : AppColors.primary,
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Active Model',
                    style: GoogleFonts.inter(
                      fontSize: 11,
                      color: Theme.of(context).hintColor,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Text(
                    inference.loadedModelName.value,
                    style: GoogleFonts.inter(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (inference.isGpuAccelerated.value) ...[
                    const SizedBox(height: 2),
                    Text(
                      '⚡ GPU: ${inference.gpuName.value}',
                      style: GoogleFonts.firaCode(
                        fontSize: 10,
                        color: AppColors.success,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            const Icon(Icons.check_circle, color: AppColors.success, size: 20),
          ],
        ),
      );
    });
  }

  Widget _buildActiveCloudBanner(BuildContext context) {
    final settings = Get.find<SettingsController>();
    final cloudModels = Get.find<CloudModelController>();
    final providerId = settings.cloudProvider.value;
    final provider = cloudModels.providers.firstWhereOrNull(
      (p) => p.id == providerId,
    );
    final providerName = providerId == 'custom'
        ? settings.customCloudName.value
        : provider?.name ?? providerId;
    final model = cloudModels.activeModelFor(providerId);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.secondary.withValues(alpha: 0.32)),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(9),
            decoration: BoxDecoration(
              color: AppColors.secondary.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.cloud_done_outlined,
                color: AppColors.secondary, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'CLOUD · $providerName',
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    color: Theme.of(context).hintColor,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  model.isEmpty ? 'No online model selected' : model,
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () => controller.modelScope.value = 'online',
            child: const Text('Change'),
          ),
        ],
      ),
    );
  }

  Widget _buildModelLoadingProgress(BuildContext context, AiModel model) {
    return Obx(() {
      final inference = Get.find<InferenceService>();
      if (!inference.isLoadingModel.value ||
          inference.loadingModelName.value != model.filename) {
        return const SizedBox.shrink();
      }
      final progress = inference.modelLoadProgress.value;
      final percent = progress * 100;

      return Container(
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.secondary.withValues(alpha: 0.3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.secondary,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  'Loading into memory · ${percent.toStringAsFixed(0)}%',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: AppColors.secondary,
                  ),
                ),
                const Spacer(),
                Text(
                  '${percent.toStringAsFixed(0)}%',
                  style: GoogleFonts.firaCode(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: AppColors.secondary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              model.filename,
              style: GoogleFonts.inter(
                fontSize: 11,
                color: Theme.of(context).hintColor,
                fontWeight: FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: inference.modelLoadProgress.value > 0
                    ? inference.modelLoadProgress.value
                    : null,
                backgroundColor:
                    Theme.of(context).colorScheme.surfaceContainerHighest,
                color: AppColors.secondary,
                minHeight: 3,
              ),
            ),
          ],
        ),
      );
    });
  }

  Widget _buildImportingProgress(BuildContext context) {
    return Obx(() {
      if (!controller.isImporting.value) return const SizedBox.shrink();
      final percent = controller.importProgress * 100;
      final total = controller.importTotalBytes.value;
      final copied = controller.importCopiedBytes.value;
      final remaining = total <= 0 ? 0 : (total - copied).clamp(0, total);

      return Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.secondary.withValues(alpha: 0.3)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.secondary,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Importing',
                          style: GoogleFonts.inter(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: AppColors.secondary,
                          ),
                        ),
                      ),
                      Text(
                        '${percent.toStringAsFixed(1)}%',
                        style: GoogleFonts.firaCode(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: AppColors.secondary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${controller.importStatus.value} ${controller.importFileName.value}',
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 10),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: controller.importProgress > 0
                          ? controller.importProgress
                          : null,
                      backgroundColor:
                          Theme.of(context).colorScheme.surfaceContainerHighest,
                      color: AppColors.secondary,
                      minHeight: 5,
                    ),
                  ),
                  const SizedBox(height: 7),
                  Wrap(
                    spacing: 12,
                    runSpacing: 4,
                    children: [
                      Text(
                        '${DownloadService.formatWholeMb(copied)} / ${DownloadService.formatWholeMb(total)}',
                        style: GoogleFonts.inter(
                            fontSize: 11, color: Theme.of(context).hintColor),
                      ),
                      Text(
                        '${DownloadService.formatWholeMb(remaining)} left',
                        style: GoogleFonts.inter(
                            fontSize: 11, color: Theme.of(context).hintColor),
                      ),
                      Text(
                        DownloadService.formatSpeed(
                            controller.importBytesPerSecond.value),
                        style: GoogleFonts.inter(
                            fontSize: 11, color: Theme.of(context).hintColor),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    });
  }

  // ignore: unused_element
  Widget _buildDownloadProgress(BuildContext context, DownloadProgress dp) {
    return Obx(() {
      return Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.primary,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Downloading ${dp.filename}',
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                TextButton(
                  onPressed: () => controller.pauseDownload(dp.filename),
                  child: Text('Pause',
                      style: GoogleFonts.inter(
                          fontSize: 12, color: AppColors.warning)),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: dp.progress.value,
                backgroundColor:
                    Theme.of(context).colorScheme.surfaceContainerHighest,
                color: AppColors.primary,
                minHeight: 4,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '${DownloadService.formatWholeMb(dp.downloadedBytes.value)} / ${DownloadService.formatWholeMb(dp.totalBytes.value)} · ${(dp.progress.value * 100).toStringAsFixed(1)}%',
              style: GoogleFonts.inter(
                fontSize: 11,
                color: Theme.of(context).hintColor,
              ),
            ),
          ],
        ),
      );
    });
  }

  Widget _buildOnlineProviders(BuildContext context) {
    final cloud = Get.find<CloudModelController>();
    return Obx(() {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'ONLINE PROVIDERS',
            style: GoogleFonts.inter(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: Theme.of(context).hintColor,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 12),
          for (final provider in cloud.providers)
            _buildProviderCard(context, cloud, provider),
        ],
      );
    });
  }

  Widget _buildProviderCard(
    BuildContext context,
    CloudModelController cloud,
    CloudProviderInfo provider,
  ) {
    final isCustom = provider.id == 'custom';
    final isActiveProvider = cloud.activeProvider == provider.id;
    final activeModel = cloud.activeModelFor(provider.id);
    final error = cloud.errorByProvider[provider.id];
    final configured = cloud.isConfigured(provider.id);
    final hasModel = activeModel.isNotEmpty;
    final status = isActiveProvider && hasModel
        ? 'ACTIVE'
        : configured
            ? (hasModel ? 'Ready' : 'No Model')
            : cloud.statusLabel(provider.id);
    final providerName = isCustom
        ? Get.find<SettingsController>().customCloudName.value
        : provider.name;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: isActiveProvider
              ? AppColors.secondary.withValues(alpha: 0.45)
              : Colors.transparent,
          width: 1.2,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    color: (configured ? AppColors.success : AppColors.warning)
                        .withValues(alpha: 0.13),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    provider.icon,
                    size: 18,
                    color: configured ? AppColors.success : AppColors.warning,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        providerName.isEmpty ? provider.name : providerName,
                        style: GoogleFonts.inter(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        hasModel ? activeModel : provider.description,
                        style: GoogleFonts.inter(
                          fontSize: 11,
                          color: hasModel
                              ? Theme.of(context).colorScheme.onSurface
                              : Theme.of(context).hintColor,
                          fontWeight:
                              hasModel ? FontWeight.w600 : FontWeight.w400,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                _buildStatusPill(context, status, configured: configured),
              ],
            ),
            if (error != null) ...[
              const SizedBox(height: 10),
              _buildErrorBox(context, error),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                if (!isCustom) ...[
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () =>
                          _showProviderKeyDialog(context, cloud, provider),
                      icon: const Icon(Icons.key_outlined, size: 16),
                      label: Text(provider.id == 'openrouter'
                          ? 'API Key'
                          : configured
                              ? 'Update Key'
                              : 'Add Key'),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: () => isCustom
                        ? _showCustomProviderSheet(context, cloud)
                        : _showModelSelectSheet(context, cloud, provider),
                    icon: Icon(
                      isCustom ? Icons.tune : Icons.smart_toy_outlined,
                      size: 16,
                    ),
                    label: Text(isCustom ? 'Configure' : 'Select Model'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  void _showProviderKeyDialog(
    BuildContext context,
    CloudModelController cloud,
    CloudProviderInfo provider,
  ) {
    final keyController = cloud.apiKeyControllerFor(provider.id);
    Get.dialog(AlertDialog(
      title: Text('${provider.name} API Key',
          style: GoogleFonts.inter(fontWeight: FontWeight.w700)),
      content: TextField(
        controller: keyController,
        obscureText: true,
        style: GoogleFonts.firaCode(fontSize: 12),
        decoration: InputDecoration(
          labelText: provider.id == 'openrouter'
              ? 'Optional for list, required for chat'
              : 'API key',
          prefixIcon: const Icon(Icons.key_outlined, size: 18),
        ),
      ),
      actions: [
        TextButton(onPressed: Get.back, child: const Text('Cancel')),
        ElevatedButton(
          onPressed: () async {
            await cloud.saveApiKey(provider.id, keyController.text);
            Get.back();
          },
          child: const Text('Save'),
        ),
      ],
    ));
  }

  void _showCustomProviderSheet(
    BuildContext context,
    CloudModelController cloud,
  ) {
    Get.bottomSheet(
      SafeArea(
        child: Padding(
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: MediaQuery.of(context).viewInsets.bottom + 16,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Custom Provider',
                    style: GoogleFonts.inter(
                        fontSize: 18, fontWeight: FontWeight.w800)),
                const SizedBox(height: 14),
                TextField(
                  controller: cloud.customNameController,
                  decoration: const InputDecoration(
                    labelText: 'Provider name',
                    prefixIcon: Icon(Icons.badge_outlined, size: 18),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: cloud.customBaseUrlController,
                  decoration: const InputDecoration(
                    labelText: 'Base URL',
                    hintText: 'https://example.com/v1',
                    prefixIcon: Icon(Icons.link, size: 18),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: cloud.customApiKeyController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'API key',
                    prefixIcon: Icon(Icons.key_outlined, size: 18),
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: cloud.customModelController,
                  decoration: const InputDecoration(
                    labelText: 'Model ID',
                    prefixIcon: Icon(Icons.smart_toy_outlined, size: 18),
                  ),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () async {
                      await cloud.saveCustomProvider();
                      Get.back();
                    },
                    icon: const Icon(Icons.check, size: 16),
                    label: const Text('Save and Select'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      isScrollControlled: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
    );
  }

  void _showModelSelectSheet(
    BuildContext context,
    CloudModelController cloud,
    CloudProviderInfo provider,
  ) {
    if (provider.requiresKeyForList && cloud.apiKeyFor(provider.id).isEmpty) {
      _showProviderKeyDialog(context, cloud, provider);
      return;
    }

    cloud.searchByProvider[provider.id] = '';
    if ((cloud.modelsByProvider[provider.id] ?? const <String>[]).isEmpty) {
      cloud.refreshModels(provider.id);
    }

    Get.bottomSheet(
      SafeArea(
        child: Obx(() {
          final isLoading = cloud.isLoadingProvider[provider.id] == true;
          final error = cloud.errorByProvider[provider.id];
          final models = cloud.filteredModelsFor(provider.id);
          final activeModel = cloud.activeModelFor(provider.id);
          final isActiveProvider = cloud.activeProvider == provider.id;

          return Padding(
            padding: EdgeInsets.only(
              left: 16,
              right: 16,
              top: 16,
              bottom: MediaQuery.of(context).viewInsets.bottom + 16,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text('Select ${provider.name} Model',
                          style: GoogleFonts.inter(
                              fontSize: 18, fontWeight: FontWeight.w800)),
                    ),
                    IconButton(
                      onPressed: Get.back,
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                TextField(
                  onChanged: (value) =>
                      cloud.searchByProvider[provider.id] = value,
                  style: GoogleFonts.inter(fontSize: 13),
                  decoration: const InputDecoration(
                    hintText: 'Search models...',
                    prefixIcon: Icon(Icons.search, size: 18),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${models.length} models - ${cloud.fetchedLabel(provider.id)}',
                        style: GoogleFonts.inter(
                          fontSize: 11,
                          color: Theme.of(context).hintColor,
                        ),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: isLoading
                          ? null
                          : () => cloud.refreshModels(provider.id),
                      icon: isLoading
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.refresh, size: 16),
                      label: const Text('Refresh'),
                    ),
                  ],
                ),
                if (error != null) ...[
                  const SizedBox(height: 8),
                  _buildErrorBox(context, error),
                ],
                const SizedBox(height: 8),
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.of(context).size.height * 0.52,
                  ),
                  child: isLoading && models.isEmpty
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.all(30),
                            child: CircularProgressIndicator(),
                          ),
                        )
                      : models.isEmpty
                          ? _buildModelSelectEmptyState(context, provider)
                          : ListView.separated(
                              shrinkWrap: true,
                              itemCount: models.length,
                              separatorBuilder: (_, __) =>
                                  const SizedBox(height: 6),
                              itemBuilder: (context, index) {
                                final id = models[index];
                                return _buildCloudModelRow(
                                  context,
                                  cloud,
                                  provider.id,
                                  id,
                                  activeModel,
                                  isActiveProvider,
                                );
                              },
                            ),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () =>
                        _showCustomModelIdDialog(context, cloud, provider),
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('Use custom model ID'),
                  ),
                ),
              ],
            ),
          );
        }),
      ),
      isScrollControlled: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
    );
  }

  Widget _buildModelSelectEmptyState(
    BuildContext context,
    CloudProviderInfo provider,
  ) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).dividerColor, width: 0.5),
      ),
      child: Text(
        provider.requiresKeyForList
            ? 'No models loaded. Check the API key and refresh.'
            : 'No models loaded. Refresh or use a custom model ID.',
        textAlign: TextAlign.center,
        style: GoogleFonts.inter(
          fontSize: 12,
          color: Theme.of(context).hintColor,
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
    Get.dialog(AlertDialog(
      title: Text('Custom ${provider.name} Model',
          style: GoogleFonts.inter(fontWeight: FontWeight.w700)),
      content: TextField(
        controller: textController,
        style: GoogleFonts.firaCode(fontSize: 12),
        decoration: const InputDecoration(
          labelText: 'Model ID',
          prefixIcon: Icon(Icons.smart_toy_outlined, size: 18),
        ),
      ),
      actions: [
        TextButton(onPressed: Get.back, child: const Text('Cancel')),
        ElevatedButton(
          onPressed: () async {
            final value = textController.text.trim();
            if (value.isEmpty) return;
            await cloud.selectModel(provider.id, value);
            Get.back();
            Get.back();
          },
          child: const Text('Select'),
        ),
      ],
    ));
  }

  Widget _buildCloudModelRow(
    BuildContext context,
    CloudModelController cloud,
    String provider,
    String id,
    String activeModel,
    bool isActiveProvider,
  ) {
    final normalized =
        provider == 'google' ? id.replaceFirst('models/', '') : id;
    final isActive = isActiveProvider && normalized == activeModel;
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: isActive
            ? AppColors.secondary.withValues(alpha: 0.12)
            : Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isActive
              ? AppColors.secondary.withValues(alpha: 0.35)
              : Colors.transparent,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              normalized,
              style: GoogleFonts.firaCode(
                fontSize: 11,
                fontWeight: isActive ? FontWeight.w700 : FontWeight.w500,
                color: Theme.of(context).colorScheme.onSurface,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          isActive
              ? _buildStatusPill(context, 'ACTIVE', configured: true)
              : TextButton(
                  onPressed: () async {
                    await cloud.selectModel(provider, id);
                    Get.back();
                  },
                  child: const Text('Select'),
                ),
        ],
      ),
    );
  }

  Widget _buildStatusPill(
    BuildContext context,
    String label, {
    required bool configured,
  }) {
    final color = configured ? AppColors.success : AppColors.warning;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: GoogleFonts.inter(
          fontSize: 10,
          fontWeight: FontWeight.w800,
          color: color,
        ),
      ),
    );
  }

  Widget _buildErrorBox(BuildContext context, String error) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.error.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.error.withValues(alpha: 0.25)),
      ),
      child: Text(
        error,
        style: GoogleFonts.inter(
          fontSize: 11,
          color: AppColors.error,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  Widget _buildModelBadges(BuildContext context, AiModel model) {
    final badges = <({String label, Color color})>[];
    if (controller.isDownloaded(model.filename)) {
      badges.add((label: 'DOWNLOADED', color: AppColors.success));
    }
    if (controller.isLiteRtModel(model)) {
      badges.add((label: 'LiteRT', color: AppColors.primary));
    } else if (controller.isLlamaModel(model)) {
      badges.add((label: 'GGUF', color: AppColors.info));
    }
    if (controller.isUncensoredModel(model)) {
      badges.add((label: 'UNCENSORED', color: AppColors.error));
    }
    if (controller.isVisionModel(model)) {
      badges.add((label: 'VISION', color: AppColors.info));
    }
    if (model.isImported) {
      badges.add((label: 'IMPORTED', color: AppColors.secondary));
    }
    if (model.isCustom) {
      badges.add((label: 'CUSTOM', color: AppColors.warning));
    }

    if (badges.isEmpty) return const SizedBox.shrink();

    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final badge in badges)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: badge.color.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(5),
            ),
            child: Text(
              badge.label,
              style: GoogleFonts.inter(
                fontSize: 9,
                fontWeight: FontWeight.w800,
                color: badge.color,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildModelCard(BuildContext context, AiModel model) {
    return Obx(() {
      final isDownloaded = controller.isDownloaded(model.filename);
      final inference = Get.find<InferenceService>();
      final isActive = inference.loadedModelName.value == model.filename;
      final isCurrentlyDownloading =
          controller.isDownloadingModel(model.filename);
      final isAnyModelLoading = inference.isLoadingModel.value;
      final isThisModelLoading = isAnyModelLoading &&
          inference.loadingModelName.value == model.filename;
      final disableActions = controller.isImporting.value ||
          isAnyModelLoading ||
          isCurrentlyDownloading;
      final loadPercent = (inference.modelLoadProgress.value * 100)
          .clamp(0.0, 100.0)
          .toStringAsFixed(0);

      return Card(
        margin: const EdgeInsets.only(bottom: 10),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                model.name,
                                style: GoogleFonts.inter(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                  color:
                                      Theme.of(context).colorScheme.onSurface,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        _buildModelBadges(context, model),
                        const SizedBox(height: 6),
                        Text(
                          model.description,
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            color:
                                Theme.of(context).textTheme.bodyMedium?.color ??
                                    Colors.grey,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          controller.modelSizeLabel(model),
                          style: GoogleFonts.inter(
                            fontSize: 11,
                            color: Theme.of(context).hintColor,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (isCurrentlyDownloading)
                _buildInlineDownloadProgress(context, model)
              else
                Row(
                  children: [
                    if (isDownloaded) ...[
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: isActive || disableActions
                              ? null
                              : () => controller.loadModel(model.filename),
                          icon: Icon(
                            isThisModelLoading
                                ? Icons.hourglass_top_rounded
                                : isActive
                                    ? Icons.check
                                    : Icons.play_arrow,
                            size: 16,
                          ),
                          label: Text(
                            isThisModelLoading
                                ? 'Loading $loadPercent%'
                                : isActive
                                    ? 'Active'
                                    : 'Load',
                          ),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: isActive
                                ? AppColors.success
                                : AppColors.primary,
                            side: BorderSide(
                              color: isActive
                                  ? AppColors.success
                                  : AppColors.primary,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: isActive ? 'Unload model' : 'Delete model',
                        onPressed: disableActions
                            ? null
                            : isActive
                                ? () => controller.unloadModel()
                                : () => controller.deleteModel(model.filename),
                        icon: Icon(
                          isActive
                              ? Icons.eject_outlined
                              : Icons.delete_outline,
                          size: 18,
                          color:
                              isActive ? AppColors.warning : AppColors.error,
                        ),
                      ),
                    ] else ...[
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            ElevatedButton.icon(
                              onPressed: disableActions
                                  ? null
                                  : () => controller.downloadModel(model),
                              icon: const Icon(Icons.download, size: 16),
                              label: const Text('Download'),
                            ),
                            if (model.url.trim().isNotEmpty)
                              TextButton(
                                onPressed: disableActions
                                    ? null
                                    : () => controller
                                        .downloadModelToDownloads(model),
                                child:
                                    const Text('Download to phone Downloads'),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              if (isThisModelLoading)
                _buildModelLoadingProgress(context, model),
            ],
          ),
        ),
      );
    });
  }

  Widget _buildInlineDownloadProgress(BuildContext context, AiModel model) {
    final dp = controller.getDownloadProgress(model.filename)!;
    return Obx(() {
      final percent = dp.progress.value * 100;
      final totalLabel = dp.totalBytes.value > 0
          ? DownloadService.formatWholeMb(dp.totalBytes.value)
          : controller.modelSizeLabel(model);
      final remaining = dp.totalBytes.value <= 0
          ? 0
          : (dp.totalBytes.value - dp.downloadedBytes.value)
              .clamp(0, dp.totalBytes.value);

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: dp.progress.value > 0 ? dp.progress.value : null,
              backgroundColor:
                  Theme.of(context).colorScheme.surfaceContainerHighest,
              color: AppColors.secondary,
              minHeight: 5,
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Text(
                '${percent.toStringAsFixed(1)}%',
                style: GoogleFonts.firaCode(
                  fontSize: 13,
                  color: AppColors.secondary,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.secondary.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  DownloadService.formatSpeed(dp.bytesPerSecond.value),
                  style: GoogleFonts.firaCode(
                    fontSize: 12,
                    color: AppColors.secondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: () => controller.pauseDownload(model.filename),
                icon: const Icon(Icons.close, size: 16),
                label: const Text('Cancel'),
                style: TextButton.styleFrom(foregroundColor: AppColors.error),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 14,
            runSpacing: 4,
            children: [
              Text(
                '${DownloadService.formatWholeMb(dp.downloadedBytes.value)} / $totalLabel',
                style: GoogleFonts.inter(
                    fontSize: 11, color: Theme.of(context).hintColor),
              ),
              if (dp.totalBytes.value > 0)
                Text(
                  '${DownloadService.formatWholeMb(remaining)} left',
                  style: GoogleFonts.inter(
                      fontSize: 11, color: Theme.of(context).hintColor),
                ),
              Text(
                'ETA: ${DownloadService.formatDuration(dp.eta)}',
                style: GoogleFonts.inter(
                    fontSize: 11, color: Theme.of(context).hintColor),
              ),
            ],
          ),
        ],
      );
    });
  }
}
