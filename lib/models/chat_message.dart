class ChatMessage {
  final String id;
  final String chatId;
  final String role; // 'user', 'assistant', 'system', 'cmd'
  final String content;
  final String? imageBase64; // For multimodal
  final String? imagePath;
  final String? cmdOutput; // Result of CMD: execution
  final bool isCommand;
  final double? tokensPerSec;
  final DateTime timestamp;

  ChatMessage({
    required this.id,
    required this.chatId,
    required this.role,
    required this.content,
    this.imageBase64,
    this.imagePath,
    this.cmdOutput,
    this.isCommand = false,
    this.tokensPerSec,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  Map<String, dynamic> toMap() => {
        'id': id,
        'chatId': chatId,
        'role': role,
        'content': content,
        'imageBase64': imageBase64,
        'imagePath': imagePath,
        'cmdOutput': cmdOutput,
        'isCommand': isCommand,
        'tokensPerSec': tokensPerSec,
        'timestamp': timestamp.toIso8601String(),
      };

  factory ChatMessage.fromMap(Map<dynamic, dynamic> map) => ChatMessage(
        id: map['id'] ?? '',
        chatId: map['chatId'] ?? '',
        role: map['role'] ?? 'user',
        content: map['content'] ?? '',
        imageBase64: map['imageBase64'],
        imagePath: map['imagePath'],
        cmdOutput: map['cmdOutput'],
        isCommand: map['isCommand'] ?? false,
        tokensPerSec: map['tokensPerSec'] != null ? (map['tokensPerSec'] as num).toDouble() : null,
        timestamp: DateTime.tryParse(map['timestamp'] ?? '') ?? DateTime.now(),
      );
}
