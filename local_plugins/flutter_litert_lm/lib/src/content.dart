import 'dart:typed_data';

/// Base class for message content parts.
sealed class LiteLmContent {
  Map<String, dynamic> toMap();

  /// Create a text content.
  factory LiteLmContent.text(String text) = LiteLmTextContent;

  /// Create an image content from file path.
  factory LiteLmContent.imageFile(String path) = LiteLmImageFileContent;

  /// Create an image content from bytes.
  factory LiteLmContent.imageBytes(Uint8List bytes) = LiteLmImageBytesContent;

  /// Create an audio content from file path.
  factory LiteLmContent.audioFile(String path) = LiteLmAudioFileContent;

  /// Create an audio content from bytes.
  factory LiteLmContent.audioBytes(Uint8List bytes) = LiteLmAudioBytesContent;

  /// Create a tool response content.
  factory LiteLmContent.toolResponse(String name, String result) =
      LiteLmToolResponseContent;
}

class LiteLmTextContent implements LiteLmContent {
  final String text;
  LiteLmTextContent(this.text);

  @override
  Map<String, dynamic> toMap() => {'type': 'text', 'text': text};
}

class LiteLmImageFileContent implements LiteLmContent {
  final String path;
  LiteLmImageFileContent(this.path);

  @override
  Map<String, dynamic> toMap() => {'type': 'imageFile', 'path': path};
}

class LiteLmImageBytesContent implements LiteLmContent {
  final Uint8List bytes;
  LiteLmImageBytesContent(this.bytes);

  @override
  Map<String, dynamic> toMap() => {'type': 'imageBytes', 'bytes': bytes};
}

class LiteLmAudioFileContent implements LiteLmContent {
  final String path;
  LiteLmAudioFileContent(this.path);

  @override
  Map<String, dynamic> toMap() => {'type': 'audioFile', 'path': path};
}

class LiteLmAudioBytesContent implements LiteLmContent {
  final Uint8List bytes;
  LiteLmAudioBytesContent(this.bytes);

  @override
  Map<String, dynamic> toMap() => {'type': 'audioBytes', 'bytes': bytes};
}

class LiteLmToolResponseContent implements LiteLmContent {
  final String name;
  final String result;
  LiteLmToolResponseContent(this.name, this.result);

  @override
  Map<String, dynamic> toMap() => {
        'type': 'toolResponse',
        'name': name,
        'result': result,
      };
}
