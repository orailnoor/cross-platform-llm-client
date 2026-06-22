import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:get/get.dart';
import '../core/constants.dart';
import 'hive_service.dart';

/// Wraps [FlutterSecureStorage] to safely persist sensitive credentials
/// (API keys, tokens) using platform-native encrypted storage
/// (Android Keystore / iOS Keychain).
///
/// Non-sensitive settings (theme, context size, model names, etc.)
/// remain in [HiveService] — only secrets go through this service.
class SecureStorageService extends GetxService {
  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  // ─── API key convenience helpers ─────────────────

  Future<String?> readApiKey(String hiveKey) =>
      _storage.read(key: _secureKey(hiveKey));

  Future<void> writeApiKey(String hiveKey, String value) =>
      _storage.write(key: _secureKey(hiveKey), value: value);

  Future<void> deleteApiKey(String hiveKey) =>
      _storage.delete(key: _secureKey(hiveKey));

  /// Migrate a single key from Hive to secure storage, then delete it from Hive.
  Future<void> migrateFromHive(String hiveKey) async {
    final hive = Get.find<HiveService>();
    final existing = hive.getSetting<String>(hiveKey);
    if (existing != null && existing.isNotEmpty) {
      await writeApiKey(hiveKey, existing);
      await hive.setSetting(hiveKey, '');
    }
  }

  /// Migrate all known API keys from Hive to secure storage.
  /// Safe to call on every launch — only migrates non-empty keys.
  Future<void> migrateAllApiKeys() async {
    const apiKeys = [
      AppConstants.keyOpenaiKey,
      AppConstants.keyAnthropicKey,
      AppConstants.keyGoogleKey,
      AppConstants.keyKimiKey,
      AppConstants.keyStabilityKey,
      AppConstants.keyNvidiaKey,
      AppConstants.keyOpenRouterKey,
      AppConstants.keyDeepSeekKey,
      AppConstants.keyCustomCloudKey,
      AppConstants.keyServerApiKey,
    ];
    for (final key in apiKeys) {
      await migrateFromHive(key);
    }
  }

  /// Prefix to avoid collisions with other consumers of FlutterSecureStorage.
  static String _secureKey(String hiveKey) => 'secure_$hiveKey';
}
