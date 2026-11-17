import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Stores the Supabase Auth session in Android Keystore-backed secure storage.
class NiptoSecureSessionStorage extends LocalStorage {
  static const _sessionKey = 'nipto.supabase.session.v1';
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  @override
  Future<void> initialize() async {}

  @override
  Future<String?> accessToken() => _storage.read(key: _sessionKey);

  @override
  Future<bool> hasAccessToken() async =>
      await _storage.containsKey(key: _sessionKey);

  @override
  Future<void> persistSession(String persistSessionString) =>
      _storage.write(key: _sessionKey, value: persistSessionString);

  @override
  Future<void> removePersistedSession() =>
      _storage.delete(key: _sessionKey);
}

/// PKCE verifiers are credentials too; keep them in secure storage as well.
class NiptoSecurePkceStorage extends GotrueAsyncStorage {
  static const _prefix = 'nipto.supabase.pkce.v1.';
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  String _key(String key) => '$_prefix$key';

  @override
  Future<String?> getItem({required String key}) =>
      _storage.read(key: _key(key));

  @override
  Future<void> setItem({required String key, required String value}) =>
      _storage.write(key: _key(key), value: value);

  @override
  Future<void> removeItem({required String key}) =>
      _storage.delete(key: _key(key));
}
