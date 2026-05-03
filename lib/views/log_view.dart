import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:google_fonts/google_fonts.dart';
import '../core/colors.dart';
import '../services/app_log_service.dart';

class LogView extends StatelessWidget {
  const LogView({super.key});

  @override
  Widget build(BuildContext context) {
    final logs = Get.find<AppLogService>();
    return Scaffold(
      appBar: AppBar(
        title:
            Text('Logs', style: GoogleFonts.inter(fontWeight: FontWeight.w700)),
        actions: [
          IconButton(
            tooltip: 'Share logs',
            icon: const Icon(Icons.share_outlined),
            onPressed: () async {
              await logs.copyImportantLogs();
              Get.snackbar('Logs copied',
                  'Important errors and warnings are ready to share.',
                  snackPosition: SnackPosition.BOTTOM);
            },
          ),
          IconButton(
            tooltip: 'Clear logs',
            icon: const Icon(Icons.delete_outline),
            onPressed: logs.clear,
          ),
        ],
      ),
      body: Obx(() {
        final important = logs.importantEntries;
        if (important.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.check_circle_outline,
                    size: 56, color: AppColors.success.withOpacity(0.35)),
                const SizedBox(height: 14),
                Text(
                  'No Important Logs',
                  style: GoogleFonts.inter(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Errors and warnings will appear here.',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    color: Theme.of(context).hintColor,
                  ),
                ),
              ],
            ),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: important.length,
          itemBuilder: (context, index) {
            final entry = important[index];
            final isError = entry.level == 'ERROR';
            final color = isError ? AppColors.error : AppColors.warning;
            return Card(
              margin: const EdgeInsets.only(bottom: 10),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          isError
                              ? Icons.error_outline
                              : Icons.warning_amber_outlined,
                          color: color,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          entry.level,
                          style: GoogleFonts.inter(
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            color: color,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          _formatTime(entry.timestamp),
                          style: GoogleFonts.inter(
                            fontSize: 11,
                            color: Theme.of(context).hintColor,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SelectableText(
                      entry.message,
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    if (entry.details != null && entry.details!.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      SelectableText(
                        entry.details!,
                        style: GoogleFonts.firaCode(
                          fontSize: 11,
                          color: Theme.of(context).hintColor,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        );
      }),
    );
  }

  String _formatTime(DateTime time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    final second = time.second.toString().padLeft(2, '0');
    return '$hour:$minute:$second';
  }
}
