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
        title: Text('Models', style: GoogleFonts.inter(fontWeight: FontWeight.w700)),
        actions: [
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
                  icon: const Icon(Icons.eject, size: 16, color: AppColors.warning),
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

                // Download progress (list all active downloads)
                ...controller.activeDownloads.values
                    .map((dp) => _buildDownloadProgress(context, dp)),

                // Available models
                Text(
                  'AVAILABLE MODELS',
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: Theme.of(context).hintColor,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 12),
                ...controller.availableModels
                    .map((model) => _buildModelCard(context, model)),
              ],
            )),
      ),
    );
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
            border: Border.all(color: Theme.of(context).dividerColor, width: 0.5),
          ),
          child: Row(
            children: [
              Icon(Icons.info_outline, color: Theme.of(context).hintColor, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'No model loaded. Download and load a model for local inference.',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    color: Theme.of(context).textTheme.bodyMedium?.color ?? Colors.grey,
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
                color: inference.isGpuAccelerated.value ? AppColors.warning : AppColors.primary,
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
                backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
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
                backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
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
      final isCurrentlyDownloading = controller.isDownloadingModel(model.filename);

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
                                  color: Theme.of(context).colorScheme.onSurface,
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
                            color: Theme.of(context).textTheme.bodyMedium?.color ?? Colors.grey,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          model.size,
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
              Row(
                children: [
                  if (isDownloaded) ...[
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed:
                            isActive ? null : () => controller.loadModel(model.filename),
                        icon: Icon(
                          isActive ? Icons.check : Icons.play_arrow,
                          size: 16,
                        ),
                        label: Text(isActive ? 'Active' : 'Load'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor:
                              isActive ? AppColors.success : AppColors.primary,
                          side: BorderSide(
                            color: isActive ? AppColors.success : AppColors.primary,
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
                        onPressed: isCurrentlyDownloading
                            ? null
                            : () => controller.downloadModel(model),
                        icon: const Icon(Icons.download, size: 16),
                        label: Text(isCurrentlyDownloading
                            ? 'Downloading...'
                            : 'Download'),
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
}
