import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Stores Supabase Auth access/refresh tokens in the platform secure store.
///
/// On Android, flutter_secure_storage uses Android Keystore-backed key
/// wrapping and authenticated encryption. Keep this storage dedicated to
/// authentication sessions; never use it as a general application database.
class NiptoSecureAuthStorage extends AuthAsyncStorage {
  const NiptoSecureAuthStorage();

  static const FlutterSecureStorage _storage = FlutterSecureStorage();

  @override
  Future<String?> getItem(String key) => _storage.read(key: key);

  @override
  Future<void> setItem(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> removeItem(String key) => _storage.delete(key: key);
}
