import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:gal/gal.dart';

import '../core/platform_capabilities.dart';

class ImageExportService {
  /// Returns the destination, or null when the user cancels the picker.
  static Future<String?> saveImages(List<Uint8List> images) async {
    if (images.isEmpty) throw ArgumentError.value(images, 'images', 'Empty');
    if (PlatformCapabilities.isWindows) {
      final name = 'privatelm_${DateTime.now().microsecondsSinceEpoch}';
      if (images.length == 1) {
        final path = await FilePicker.saveFile(
          dialogTitle: 'Save image',
          fileName: '$name.png',
          type: FileType.custom,
          allowedExtensions: ['png'],
        );
        if (path == null) return null;
        await File(path).writeAsBytes(images.single, flush: true);
        return path;
      }
      final directory = await FilePicker.getDirectoryPath(
        dialogTitle: 'Save generated images',
      );
      if (directory == null) return null;
      for (var i = 0; i < images.length; i++) {
        await File('$directory${Platform.pathSeparator}${name}_${i + 1}.png')
            .writeAsBytes(images[i], flush: true);
      }
      return directory;
    }

    if (!await Gal.hasAccess() && !await Gal.requestAccess()) {
      throw StateError('Cannot save images without gallery access.');
    }
    for (final image in images) {
      await Gal.putImageBytes(image);
    }
    return 'gallery';
  }
}
