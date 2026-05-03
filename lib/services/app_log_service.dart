import 'package:flutter/services.dart';
import 'package:get/get.dart';

class AppLogEntry {
  final DateTime timestamp;
  final String level;
  final String message;
  final String? details;

  AppLogEntry({
    required this.level,
    required this.message,
    this.details,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  bool get isImportant => level == 'ERROR' || level == 'WARNING';

  String format() {
    final buffer = StringBuffer()
      ..write('[${timestamp.toIso8601String()}] ')
      ..write('$level: $message');
    if (details != null && details!.trim().isNotEmpty) {
      buffer.write('\n$details');
    }
    return buffer.toString();
  }
}

class AppLogService extends GetxService {
  final entries = <AppLogEntry>[].obs;

  void warning(String message, {Object? details}) {
    _add('WARNING', message, details);
  }

  void error(String message, {Object? details}) {
    _add('ERROR', message, details);
  }

  void info(String message, {Object? details}) {
    _add('INFO', message, details);
  }

  void _add(String level, String message, Object? details) {
    entries.insert(
      0,
      AppLogEntry(
        level: level,
        message: message,
        details: details?.toString(),
      ),
    );
    if (entries.length > 200) {
      entries.removeRange(200, entries.length);
    }
  }

  List<AppLogEntry> get importantEntries =>
      entries.where((entry) => entry.isImportant).toList();

  String get shareText {
    final selected = importantEntries.isEmpty ? entries : importantEntries;
    return selected.map((entry) => entry.format()).join('\n\n');
  }

  Future<void> copyImportantLogs() async {
    await Clipboard.setData(ClipboardData(text: shareText));
  }

  void clear() {
    entries.clear();
  }
}
