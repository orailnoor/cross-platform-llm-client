import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/colors.dart';

class AttachmentPreview extends StatelessWidget {
  final String fileName;
  final String? fileType;
  final int? fileSize;
  final String? imagePath;
  final String? imageBase64;
  final VoidCallback? onRemove;
  final bool compact;

  const AttachmentPreview({
    super.key,
    required this.fileName,
    this.fileType,
    this.fileSize,
    this.imagePath,
    this.imageBase64,
    this.onRemove,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final type = fileType ?? _typeFromName(fileName);
    final color = _colorForType(type);
    final label = _labelForType(type);

    return Container(
      constraints: compact ? const BoxConstraints(maxWidth: 280) : null,
      padding: EdgeInsets.all(compact ? 8 : 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.28)),
      ),
      child: Row(
        mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
        children: [
          _leading(context, type, color),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  fileName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: compact ? 12 : 13,
                    color: Theme.of(context).colorScheme.onSurface,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  fileSize != null && fileSize! > 0
                      ? '$label - ${formatFileSize(fileSize!)}'
                      : label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    color: Theme.of(context).hintColor,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          if (onRemove != null) ...[
            const SizedBox(width: 6),
            IconButton(
              onPressed: onRemove,
              icon: const Icon(Icons.close_rounded, size: 18),
              visualDensity: VisualDensity.compact,
              color: Theme.of(context).hintColor,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 30, height: 30),
            ),
          ],
        ],
      ),
    );
  }

  Widget _leading(BuildContext context, String type, Color color) {
    final image = _imageThumbnail();
    return ClipRRect(
      borderRadius: BorderRadius.circular(9),
      child: Container(
        width: compact ? 38 : 44,
        height: compact ? 38 : 44,
        color: color.withValues(alpha: 0.16),
        child: image ??
            Icon(
              _iconForType(type),
              color: color,
              size: compact ? 20 : 23,
            ),
      ),
    );
  }

  Widget? _imageThumbnail() {
    if ((fileType ?? _typeFromName(fileName)) != 'image') return null;
    if (imageBase64 != null && imageBase64!.isNotEmpty) {
      return Image.memory(
        base64Decode(imageBase64!),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const Icon(Icons.broken_image_outlined),
      );
    }
    if (imagePath != null && imagePath!.isNotEmpty) {
      return Image.file(
        File(imagePath!),
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => const Icon(Icons.broken_image_outlined),
      );
    }
    return null;
  }

  static String formatFileSize(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).round()} MB';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).round()} KB';
    }
    return '$bytes B';
  }

  String _typeFromName(String name) {
    final ext = name.split('.').last.toLowerCase();
    if (['png', 'jpg', 'jpeg', 'webp', 'gif', 'heic'].contains(ext)) {
      return 'image';
    }
    if (['mp3', 'm4a', 'wav', 'aac', 'ogg', 'flac'].contains(ext)) {
      return 'audio';
    }
    if (ext == 'pdf') return 'pdf';
    if ([
      'txt',
      'md',
      'json',
      'csv',
      'log',
      'yaml',
      'yml',
      'xml',
      'dart',
      'kt',
      'java',
      'js',
      'ts',
      'py'
    ].contains(ext)) {
      return 'text';
    }
    return 'file';
  }

  String _labelForType(String type) {
    switch (type) {
      case 'image':
        return 'Image';
      case 'pdf':
        return 'PDF';
      case 'audio':
        return 'Audio';
      case 'text':
        return 'Text file';
      default:
        return 'Attachment';
    }
  }

  IconData _iconForType(String type) {
    switch (type) {
      case 'image':
        return Icons.image_outlined;
      case 'pdf':
        return Icons.picture_as_pdf_outlined;
      case 'audio':
        return Icons.graphic_eq_rounded;
      case 'text':
        return Icons.description_outlined;
      default:
        return Icons.insert_drive_file_outlined;
    }
  }

  Color _colorForType(String type) {
    switch (type) {
      case 'image':
        return AppColors.primary;
      case 'pdf':
        return AppColors.error;
      case 'audio':
        return AppColors.warning;
      case 'text':
        return AppColors.info;
      default:
        return AppColors.secondary;
    }
  }
}
