import 'dart:convert';
import 'package:get/get.dart';
import 'package:http/http.dart' as http;
import '../core/constants.dart';
import 'hive_service.dart';
import 'app_log_service.dart';

/// Cloud API service supporting OpenAI, Anthropic, Google Gemini, Kimi, and NVIDIA NIM.
class CloudService extends GetxService {
  final HiveService _hive = Get.find<HiveService>();

  String get _provider =>
      _hive.getSetting(AppConstants.keyCloudProvider, defaultValue: 'kimi') ??
      'kimi';

  String get _apiKey {
    switch (_provider) {
      case 'anthropic':
        return _hive.getSetting(AppConstants.keyAnthropicKey) ?? '';
      case 'google':
        return _hive.getSetting(AppConstants.keyGoogleKey) ?? '';
      case 'kimi':
        return _hive.getSetting(AppConstants.keyKimiKey) ?? '';
      case 'stability':
        return _hive.getSetting(AppConstants.keyStabilityKey) ?? '';
      case 'nvidia':
        return _hive.getSetting(AppConstants.keyNvidiaKey) ?? '';
      default:
        return _hive.getSetting(AppConstants.keyOpenaiKey) ?? '';
    }
  }

  String get _model {
    switch (_provider) {
      case 'anthropic':
        return _hive.getSetting(AppConstants.keyAnthropicModel) ??
            'claude-sonnet-4-6';
      case 'google':
        return _hive.getSetting(AppConstants.keyGoogleModel) ??
            'gemini-2.5-flash';
      case 'kimi':
        return _hive.getSetting(AppConstants.keyKimiModel) ?? 'kimi-k2.6';
      case 'stability':
        return _hive.getSetting(AppConstants.keyStabilityModel) ??
            'sd3.5-flash';
      case 'nvidia':
        return _hive.getSetting(AppConstants.keyNvidiaModel) ??
            'meta/llama-3.1-8b-instruct';
      default:
        return _hive.getSetting(AppConstants.keyOpenaiModel) ?? 'gpt-5.2';
    }
  }

  bool get isConfigured => _apiKey.isNotEmpty;

  /// Send a message to the cloud API. Returns the response text.
  /// [messages] is a list of {role, content} maps forming the conversation.
  /// [imageBase64] is optional for multimodal requests.
  Future<String> sendMessage({
    required List<Map<String, String>> messages,
    String? imageBase64,
    double? temperature,
    int? maxTokens,
  }) async {
    if (!isConfigured) {
      return 'ERROR: No API key configured for $_provider. Go to Settings.';
    }

    try {
      switch (_provider) {
        case 'anthropic':
          return await _sendAnthropic(
              messages, imageBase64, temperature, maxTokens);
        case 'google':
          return await _sendGoogle(
              messages, imageBase64, temperature, maxTokens);
        case 'kimi':
          return await _sendKimi(messages, imageBase64, temperature, maxTokens);
        case 'stability':
          return await _sendStability(messages);
        case 'nvidia':
          return await _sendNvidia(
              messages, imageBase64, temperature, maxTokens);
        default:
          return await _sendOpenAI(
              messages, imageBase64, temperature, maxTokens);
      }
    } catch (e) {
      Get.find<AppLogService>().error('Cloud API request failed', details: e);
      return 'ERROR: Cloud API request failed — $e';
    }
  }

  // ─── OpenAI ─────────────────────────────────────

  Future<String> _sendOpenAI(
    List<Map<String, String>> messages,
    String? imageBase64,
    double? temperature,
    int? maxTokens,
  ) async {
    final apiMessages = <Map<String, dynamic>>[];

    for (final msg in messages) {
      if (msg['role'] == 'user' &&
          imageBase64 != null &&
          msg == messages.last) {
        apiMessages.add({
          'role': 'user',
          'content': [
            {'type': 'text', 'text': msg['content']},
            {
              'type': 'image_url',
              'image_url': {'url': 'data:image/jpeg;base64,$imageBase64'}
            },
          ],
        });
      } else {
        apiMessages.add({'role': msg['role'], 'content': msg['content']});
      }
    }

    final response = await http.post(
      Uri.parse(AppConstants.openaiEndpoint),
      headers: {
        'Authorization': 'Bearer $_apiKey',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'model': _model,
        'messages': apiMessages,
        'temperature': temperature ?? AppConstants.defaultTemperature,
        'max_tokens': maxTokens ?? AppConstants.defaultMaxTokens,
      }),
    );

    if (response.statusCode != 200) {
      return 'ERROR: OpenAI returned ${response.statusCode} — ${response.body}';
    }

    final data = jsonDecode(response.body);
    return data['choices'][0]['message']['content'] ?? '';
  }

  // ─── Anthropic ──────────────────────────────────

  Future<String> _sendAnthropic(
    List<Map<String, String>> messages,
    String? imageBase64,
    double? temperature,
    int? maxTokens,
  ) async {
    // Extract system message
    String? systemMsg;
    final apiMessages = <Map<String, dynamic>>[];

    for (final msg in messages) {
      if (msg['role'] == 'system') {
        systemMsg = msg['content'];
        continue;
      }

      if (msg['role'] == 'user' &&
          imageBase64 != null &&
          msg == messages.last) {
        apiMessages.add({
          'role': 'user',
          'content': [
            {
              'type': 'image',
              'source': {
                'type': 'base64',
                'media_type': 'image/jpeg',
                'data': imageBase64,
              }
            },
            {'type': 'text', 'text': msg['content']},
          ],
        });
      } else {
        apiMessages.add({
          'role': msg['role'],
          'content': msg['content'],
        });
      }
    }

    final body = <String, dynamic>{
      'model': _model,
      'messages': apiMessages,
      'max_tokens': maxTokens ?? AppConstants.defaultMaxTokens,
      'temperature': temperature ?? AppConstants.defaultTemperature,
    };
    if (systemMsg != null) body['system'] = systemMsg;

    final response = await http.post(
      Uri.parse(AppConstants.anthropicEndpoint),
      headers: {
        'x-api-key': _apiKey,
        'anthropic-version': '2023-06-01',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(body),
    );

    if (response.statusCode != 200) {
      return 'ERROR: Anthropic returned ${response.statusCode} — ${response.body}';
    }

    final data = jsonDecode(response.body);
    final content = data['content'] as List;
    return content.isNotEmpty ? content[0]['text'] ?? '' : '';
  }

  // ─── Google Gemini ──────────────────────────────

  Future<String> _sendGoogle(
    List<Map<String, String>> messages,
    String? imageBase64,
    double? temperature,
    int? maxTokens,
  ) async {
    final parts = <Map<String, dynamic>>[];

    // Combine all messages into parts
    for (final msg in messages) {
      parts.add({'text': '${msg['role']}: ${msg['content']}'});
    }

    // Add image if present
    if (imageBase64 != null) {
      parts.add({
        'inline_data': {
          'mime_type': 'image/jpeg',
          'data': imageBase64,
        }
      });
    }

    final url =
        '${AppConstants.googleEndpoint}/$_model:generateContent?key=$_apiKey';

    final response = await http.post(
      Uri.parse(url),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'contents': [
          {'parts': parts}
        ],
        'generationConfig': {
          'temperature': temperature ?? AppConstants.defaultTemperature,
          'maxOutputTokens': maxTokens ?? AppConstants.defaultMaxTokens,
        },
      }),
    );

    if (response.statusCode != 200) {
      return 'ERROR: Google returned ${response.statusCode} — ${response.body}';
    }

    final data = jsonDecode(response.body);
    final candidates = data['candidates'] as List?;
    if (candidates != null && candidates.isNotEmpty) {
      final contentParts = candidates[0]['content']['parts'] as List;
      return contentParts.map((p) => p['text'] ?? '').join('');
    }
    return '';
  }

  // ─── Kimi (Moonshot AI — OpenAI-compatible) ─────

  Future<String> _sendKimi(
    List<Map<String, String>> messages,
    String? imageBase64,
    double? temperature,
    int? maxTokens,
  ) async {
    final apiMessages = <Map<String, dynamic>>[];

    for (final msg in messages) {
      apiMessages.add({'role': msg['role'], 'content': msg['content']});
    }

    final response = await http.post(
      Uri.parse(AppConstants.kimiEndpoint),
      headers: {
        'Authorization': 'Bearer $_apiKey',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'model': _model,
        'messages': apiMessages,
        'temperature': temperature ?? AppConstants.defaultTemperature,
        'max_tokens': maxTokens ?? AppConstants.defaultMaxTokens,
      }),
    );

    if (response.statusCode != 200) {
      return 'ERROR: Kimi returned ${response.statusCode} — ${response.body}';
    }

    final data = jsonDecode(response.body);
    return data['choices'][0]['message']['content'] ?? '';
  }

  Future<String> _sendNvidia(
    List<Map<String, String>> messages,
    String? imageBase64,
    double? temperature,
    int? maxTokens,
  ) async {
    final apiMessages = <Map<String, dynamic>>[];

    for (final msg in messages) {
      if (msg['role'] == 'user' &&
          imageBase64 != null &&
          msg == messages.last) {
        apiMessages.add({
          'role': 'user',
          'content': [
            {'type': 'text', 'text': msg['content']},
            {
              'type': 'image_url',
              'image_url': {'url': 'data:image/jpeg;base64,$imageBase64'}
            },
          ],
        });
      } else {
        apiMessages.add({'role': msg['role'], 'content': msg['content']});
      }
    }

    final response = await http.post(
      Uri.parse('${AppConstants.nvidiaEndpoint}/chat/completions'),
      headers: {
        'Authorization': 'Bearer $_apiKey',
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'model': _model,
        'messages': apiMessages,
        'temperature': temperature ?? AppConstants.defaultTemperature,
        'max_tokens': maxTokens ?? AppConstants.defaultMaxTokens,
      }),
    );

    if (response.statusCode != 200) {
      return 'ERROR: NVIDIA NIM returned ${response.statusCode} — ${response.body}';
    }

    final data = jsonDecode(response.body);
    return data['choices'][0]['message']['content'] ?? '';
  }

  // ─── Stability AI (Image Generation) ────────────

  Future<String> _sendStability(
    List<Map<String, String>> messages,
  ) async {
    // Extract the latest user prompt for the image generation
    final userMessages = messages.where((m) => m['role'] == 'user').toList();
    if (userMessages.isEmpty) {
      return 'ERROR: No user prompt found for image generation.';
    }

    final prompt = userMessages.last['content'] ?? '';

    // Create a multipart request since stability AI v2beta uses multipart/form-data
    var request = http.MultipartRequest(
        'POST', Uri.parse(AppConstants.stabilityEndpoint));
    request.headers.addAll({
      'Authorization': 'Bearer $_apiKey',
      'Accept': 'application/json',
    });

    request.fields['prompt'] = prompt;
    request.fields['model'] = _model;
    request.fields['output_format'] = 'jpeg';

    final response = await request.send();
    final responseBody = await response.stream.bytesToString();

    if (response.statusCode != 200) {
      return 'ERROR: Stability AI returned ${response.statusCode} — $responseBody';
    }

    final data = jsonDecode(responseBody);
    final base64Image = data['image'];
    if (base64Image != null) {
      return '[IMAGE_BASE64]$base64Image';
    }

    return 'ERROR: No image generated.';
  }
}
