import 'dart:io';
import 'package:path/path.dart' as p;

void main() {
  final pubCache = Platform.environment['PUB_CACHE'] ?? 
      p.join(Platform.environment['LOCALAPPDATA']!, 'Pub', 'Cache');
  print('Pub cache: $pubCache');
}
