class AiModel {
  final String name;
  final String filename;
  final String url;
  final String size;
  final String description;
  final String template;
  final bool isVision;

  const AiModel({
    required this.name,
    required this.filename,
    required this.url,
    required this.size,
    required this.description,
    required this.template,
    this.isVision = false,
  });

  factory AiModel.fromMap(Map<String, String> map) => AiModel(
        name: map['name'] ?? '',
        filename: map['filename'] ?? '',
        url: map['url'] ?? '',
        size: map['size'] ?? '',
        description: map['description'] ?? '',
        template: map['template'] ?? 'chatml',
        isVision: map['vision'] == 'true',
      );
}
