import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class TunnelStartResult {
  final bool success;
  final String? publicUrl;
  final String? error;

  const TunnelStartResult({
    required this.success,
    this.publicUrl,
    this.error,
  });
}

class TunnelService {
  static const MethodChannel _channel =
      MethodChannel('com.aichat.ai_chat/tunnel');

  Future<TunnelStartResult> start({
    required String provider,
    required int port,
    String cloudflareToken = '',
    String cloudflarePublicUrl = '',
    String ngrokAuthToken = '',
    String ngrokDomain = '',
  }) async {
    if (kIsWeb) {
      return const TunnelStartResult(
        success: false,
        error: 'Public tunnels are not available on web.',
      );
    }
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'startTunnel',
        {
          'provider': provider,
          'port': port,
          'cloudflareToken': cloudflareToken,
          'cloudflarePublicUrl': cloudflarePublicUrl,
          'ngrokAuthToken': ngrokAuthToken,
          'ngrokDomain': ngrokDomain,
        },
      );
      return TunnelStartResult(
        success: result?['success'] == true,
        publicUrl: result?['publicUrl'] as String?,
        error: result?['error'] as String?,
      );
    } on PlatformException catch (e) {
      return TunnelStartResult(success: false, error: e.message ?? e.code);
    } catch (e) {
      return TunnelStartResult(success: false, error: '$e');
    }
  }

  Future<void> stop() async {
    if (kIsWeb) return;
    try {
      await _channel.invokeMethod('stopTunnel');
    } catch (_) {}
  }
}
