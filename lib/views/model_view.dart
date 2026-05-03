import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import '../controllers/model_controller.dart';
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
          Obx(() {
            final inference = Get.find<InferenceService>();
            if (inference.isModelLoaded.value) {
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: TextButton.icon(
                  onPressed: () => controller.unloadModel(),
                  icon: const Icon(Icons.eject,
                      size: 16, color: AppColors.warning),
                  label: Text(
                    'Unload',
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      color: AppColors.warning,
                    ),
                  ),
                ),
              );
            }
            return const SizedBox.shrink();
          }),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async => controller.refreshDownloaded(),
        color: AppColors.primary,
        child: Obx(() => ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // Active model banner
                _buildActiveModelBanner(context),
                const SizedBox(height: 12),

                // Model importing progress
                _buildImportingProgress(context),

                // Available models
                Text(
                  'AVAILABLE MODELS (${controller.displayedModels.length})',
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: Theme.of(context).hintColor,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 12),
                ...controller.displayedModels
                    .map((model) => _buildModelCard(context, model)),
              ],
            )),
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
      final inference = Get.find<InferenceService>();
      if (!inference.isModelLoaded.value) {
        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Theme.of(context).cardColor,
            borderRadius: BorderRadius.circular(12),
            border:
                Border.all(color: Theme.of(context).dividerColor, width: 0.5),
          ),
          child: Row(
            children: [
              Icon(Icons.info_outline,
                  color: Theme.of(context).hintColor, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'No model loaded. Download and load a model for local inference.',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    color: Theme.of(context).textTheme.bodyMedium?.color ??
                        Colors.grey,
                  ),
                ),
              ),
            ],
          ),
        );
      }

      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              AppColors.primary.withOpacity(0.15),
              AppColors.secondary.withOpacity(0.1),
            ],
          ),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.primary.withOpacity(0.3)),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.primary.withOpacity(0.2),
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

  Widget _buildModelLoadingProgress(BuildContext context, AiModel model) {
    return Obx(() {
      final inference = Get.find<InferenceService>();
      if (!inference.isLoadingModel.value ||
          inference.loadingModelName.value != model.filename) {
        return const SizedBox.shrink();
      }

      return Container(
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.secondary.withOpacity(0.3)),
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
                  'Loading into memory...',
                  style: GoogleFonts.inter(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: AppColors.secondary,
                  ),
                ),
                const Spacer(),
                Text(
                  '${(inference.modelLoadProgress.value * 100).toStringAsFixed(0)}%',
                  style: GoogleFonts.firaCode(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: AppColors.secondary,
                  ),
                ),
              ],
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

      return Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.secondary.withOpacity(0.3)),
        ),
        child: Row(
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.secondary,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              'Importing model from storage...',
              style: GoogleFonts.inter(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: AppColors.secondary,
              ),
            ),
          ],
        ),
      );
    });
  }

  Widget _buildDownloadProgress(BuildContext context, DownloadProgress dp) {
    return Obx(() {
      return Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.primary.withOpacity(0.3)),
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
              '${DownloadService.formatBytes(dp.downloadedBytes.value)} / ${DownloadService.formatBytes(dp.totalBytes.value)} · ${(dp.progress.value * 100).toStringAsFixed(1)}%',
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

  Widget _buildModelCard(BuildContext context, AiModel model) {
    return Obx(() {
      final isDownloaded = controller.isDownloaded(model.filename);
      final inference = Get.find<InferenceService>();
      final isActive = inference.loadedModelName.value == model.filename;
      final isCurrentlyDownloading =
          controller.isDownloadingModel(model.filename);

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
                            if (model.isVision) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: AppColors.info.withOpacity(0.15),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  '👁 VISION',
                                  style: GoogleFonts.inter(
                                    fontSize: 9,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.info,
                                  ),
                                ),
                              ),
                            ],
                            if (model.isImported) ...[
                              const SizedBox(width: 6),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: AppColors.secondary.withOpacity(0.15),
                                  borderRadius: BorderRadius.circular(4),
                                ),
                                child: Text(
                                  '⬇ IMPORTED',
                                  style: GoogleFonts.inter(
                                    fontSize: 9,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.secondary,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 4),
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
                          onPressed: isActive
                              ? null
                              : () => controller.loadModel(model.filename),
                          icon: Icon(
                            isActive ? Icons.check : Icons.play_arrow,
                            size: 16,
                          ),
                          label: Text(isActive ? 'Active' : 'Load'),
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
                        onPressed: () => controller.deleteModel(model.filename),
                        icon: const Icon(Icons.delete_outline,
                            size: 18, color: AppColors.error),
                      ),
                    ] else ...[
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: () => controller.downloadModel(model),
                          icon: const Icon(Icons.download, size: 16),
                          label: const Text('Download'),
                        ),
                      ),
                    ],
                  ],
                ),
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
          ? DownloadService.formatBytes(dp.totalBytes.value)
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
                  color: AppColors.secondary.withOpacity(0.16),
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
                '${DownloadService.formatBytes(dp.downloadedBytes.value)} / $totalLabel',
                style: GoogleFonts.inter(
                    fontSize: 11, color: Theme.of(context).hintColor),
              ),
              if (dp.totalBytes.value > 0)
                Text(
                  '${DownloadService.formatBytes(remaining)} left',
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
