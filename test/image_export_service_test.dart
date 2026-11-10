import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:file_picker/src/platform/file_picker_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:privatelm/services/image_export_service.dart';

class _FilePicker extends FilePickerPlatform {
  String? destination;
  String? directory;

  @override
  Future<String?> saveFile({
    String? dialogTitle,
    String? fileName,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Uint8List? bytes,
    bool lockParentWindow = false,
  }) async => destination;

  @override
  Future<String?> getDirectoryPath({
    String? dialogTitle,
    bool lockParentWindow = false,
    String? initialDirectory,
  }) async => directory;
}

void main() {
  late Directory directory;
  late FilePickerPlatform originalPicker;
  late _FilePicker picker;
  final image = Uint8List.fromList([137, 80, 78, 71]);

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    directory = await Directory.systemTemp.createTemp('image_export_test');
    originalPicker = FilePickerPlatform.instance;
    picker = _FilePicker();
    FilePickerPlatform.instance = picker;
  });

  tearDown(() async {
    FilePickerPlatform.instance = originalPicker;
    debugDefaultTargetPlatformOverride = null;
    await directory.delete(recursive: true);
  });

  test('saves image bytes to the chosen Windows path', () async {
    final file = File('${directory.path}${Platform.pathSeparator}image.png');
    picker.destination = file.path;
    expect(await ImageExportService.saveImages([image]), file.path);
    expect(await file.readAsBytes(), image);
  });

  test('cancelled save creates no file and reports no success', () async {
    expect(await ImageExportService.saveImages([image]), isNull);
    expect(await directory.list().toList(), isEmpty);
  });

  test('saves every batch image to the selected directory', () async {
    picker.directory = directory.path;
    final second = Uint8List.fromList([1, 2, 3]);
    expect(await ImageExportService.saveImages([image, second]), directory.path);
    final files = await directory.list().where((e) => e is File).toList();
    files.sort((a, b) => a.path.compareTo(b.path));
    expect(files.length, 2);
    expect(await File(files[0].path).readAsBytes(), image);
    expect(await File(files[1].path).readAsBytes(), second);
  });

  test('cancelled batch preserves the destination directory', () async {
    expect(await ImageExportService.saveImages([image, image]), isNull);
    expect(await directory.list().toList(), isEmpty);
  });

  test('write errors propagate instead of reporting success', () async {
    picker.destination =
        '${directory.path}${Platform.pathSeparator}missing'
        '${Platform.pathSeparator}image.png';
    await expectLater(ImageExportService.saveImages([image]),
        throwsA(isA<FileSystemException>()));
  });
}
