class AiModel {
  static const runtimeLlama = 'llama';
  static const runtimeLiteRt = 'litert';
  static const runtimeSd = 'sd';

  final String name;
  final String filename;
  final String url;
  final String size;
  final String description;
  final String template;
  final String runtime;
  final bool isVision;
  final bool isImported;
  final bool isCustom;

  AiModel({
    required this.name,
    required this.filename,
    required this.url,
    required this.size,
    required this.description,
    required this.template,
    String? runtime,
    this.isVision = false,
    this.isImported = false,
    this.isCustom = false,
  }) : runtime = runtime ?? runtimeFromFilename(filename, template: template);

  factory AiModel.fromMap(Map<String, String> map) => AiModel(
        name: map['name'] ?? '',
        filename: map['filename'] ?? '',
        url: map['url'] ?? '',
        size: map['size'] ?? '',
        description: map['description'] ?? '',
        template: map['template'] ?? 'chatml',
        runtime: map['runtime'],
        isVision: map['vision'] == 'true',
        isImported: map['imported'] == 'true',
        isCustom: map['custom'] == 'true',
      );

  Map<String, String> toMap() => {
        'name': name,
        'filename': filename,
        'url': url,
        'size': size,
        'description': description,
        'template': template,
        'runtime': runtime,
        if (isVision) 'vision': 'true',
        if (isImported) 'imported': 'true',
        if (isCustom) 'custom': 'true',
      };

  static String runtimeFromFilename(String filename, {String? template}) {
    final lower = filename.toLowerCase();
    if (lower.endsWith('.litertlm')) return runtimeLiteRt;
    if (lower.endsWith('.safetensors') || template == runtimeSd) {
      return runtimeSd;
    }
    return runtimeLlama;
  }

  AiModel copyWith({
    String? name,
    String? filename,
    String? url,
    String? size,
    String? description,
    String? template,
    String? runtime,
    bool? isVision,
    bool? isImported,
    bool? isCustom,
  }) {
    return AiModel(
      name: name ?? this.name,
      filename: filename ?? this.filename,
      url: url ?? this.url,
      size: size ?? this.size,
      description: description ?? this.description,
      template: template ?? this.template,
      runtime: runtime ?? this.runtime,
      isVision: isVision ?? this.isVision,
      isImported: isImported ?? this.isImported,
      isCustom: isCustom ?? this.isCustom,
    );
  }
}
