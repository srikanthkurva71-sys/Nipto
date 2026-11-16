import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class NiptoSession {
  const NiptoSession({
    required this.userId,
    required this.niptoId,
    required this.displayName,
  });

  final String userId;
  final String niptoId;
  final String displayName;

  factory NiptoSession.fromJson(Map<String, dynamic> json) {
    return NiptoSession(
      userId: json['id'] as String,
      niptoId: json['nipto_id'] as String,
      displayName: json['display_name'] as String,
    );
  }
}

class NiptoAuthException implements Exception {
  const NiptoAuthException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// Owns Nipto credentials and refresh sessions. Supabase receives only the
/// short-lived Nipto-issued access JWT through its accessToken callback; the
/// Supabase Auth namespace must not be used with this client configuration.
class NiptoSessionManager {
  NiptoSessionManager._();

  static final NiptoSessionManager instance = NiptoSessionManager._();

  static const _refreshTokenKey = 'nipto.refresh_token.v1';
  static const _recoveryIdKey = 'nipto.recovery.challenge_id.v1';
  static const _recoverySecretKey = 'nipto.recovery.challenge_secret.v1';
  static const _resetGrantKey = 'nipto.recovery.reset_grant.v1';
  static const _legacyAccessKey = 'nipto.legacy.access_token.v1';
  static const _legacyRefreshKey = 'nipto.legacy.refresh_token.v1';

  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  final SharedPreferencesAsync _legacyPreferences = SharedPreferencesAsync();
  final HttpClient _http = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15);

  final StreamController<NiptoSession?> _changes =
      StreamController<NiptoSession?>.broadcast();

  String? _baseUrl;
  String? _supabaseUrl;
  String? _publishableKey;
  String? _legacyStorageKey;
  String? _legacyAccessToken;
  String? _legacyRefreshToken;
  DateTime? _legacyExpiresAt;
  String? _accessToken;
  String? _refreshToken;
  DateTime? _accessExpiresAt;
  NiptoSession? _session;
  Future<void>? _refreshInFlight;
  bool _initialized = false;

  Stream<NiptoSession?> get changes => _changes.stream;
  NiptoSession? get currentSession => _session;
  String? get userId => _session?.userId;
  bool get isSignedIn => _session != null;
  bool get hasLegacySession => _legacyRefreshToken != null;

  Future<void> initialize(String supabaseUrl, String publishableKey) async {
    if (_initialized) return;
    _supabaseUrl = supabaseUrl.replaceAll(RegExp(r'/

  Future<String?> accessToken() async {
    if (!_initialized) return null;
    final expiresAt = _accessExpiresAt;
    if (_accessToken == null ||
        expiresAt == null ||
        expiresAt.isBefore(DateTime.now().add(const Duration(seconds: 60)))) {
      if (_refreshToken == null) return null;
      try {
        await _refreshSession();
      } catch (error) {
        if (error is NiptoAuthException &&
            (error.statusCode == 401 || error.statusCode == 400)) {
          await _clearSession();
        }
        final currentExpiry = _accessExpiresAt;
        if (_accessToken != null &&
            currentExpiry != null &&
            currentExpiry.isAfter(DateTime.now())) {
          return _accessToken;
        }
        return null;
      }
    }
    return _accessToken;
  }

  Future<NiptoSession> register({
    required String niptoId,
    required String displayName,
    required String password,
    String? recoveryNiptoId,
  }) async {
    final response = await _post('register', {
      'nipto_id': niptoId.trim().replaceFirst(RegExp(r'^@'), ''),
      'display_name': displayName.trim(),
      'password': password,
      if (recoveryNiptoId != null && recoveryNiptoId.trim().isNotEmpty)
        'recovery_nipto_id':
            recoveryNiptoId.trim().replaceFirst(RegExp(r'^@'), ''),
      'device_label': 'Android device',
    });
    await _applySession(response);
    return _session!;
  }

  Future<NiptoSession> signIn({
    required String niptoId,
    required String password,
  }) async {
    final response = await _post('login', {
      'nipto_id': niptoId.trim().replaceFirst(RegExp(r'^@'), ''),
      'password': password,
      'device_label': 'Android device',
    });
    await _applySession(response);
    return _session!;
  }

  Future<void> signOut() async {
    try {
      await _post('logout', const {}, authenticated: true);
    } catch (_) {
      // Local credentials are still cleared if the device is offline.
    } finally {
      await _clearSession();
    }
  }

  Future<void> signOutEverywhere() async {
    try {
      await _post('logout-all', const {}, authenticated: true);
    } finally {
      await _clearSession();
    }
  }

  Future<void> startPasswordRecovery(String niptoId) async {
    final response = await _post('recovery/start', {
      'nipto_id': niptoId.trim().replaceFirst(RegExp(r'^@'), ''),
    });
    final challengeId = response['challenge_id'] as String?;
    final challengeSecret = response['challenge_secret'] as String?;
    if (challengeId == null || challengeSecret == null) {
      throw const NiptoAuthException('Could not start account recovery.');
    }
    await _storage.write(key: _recoveryIdKey, value: challengeId);
    await _storage.write(key: _recoverySecretKey, value: challengeSecret);
  }

  Future<String?> checkPasswordRecoveryApproval() async {
    final challengeId = await _storage.read(key: _recoveryIdKey);
    final challengeSecret = await _storage.read(key: _recoverySecretKey);
    if (challengeId == null || challengeSecret == null) {
      throw const NiptoAuthException('Start a new recovery request.');
    }
    final response = await _post('recovery/claim', {
      'challenge_id': challengeId,
      'challenge_secret': challengeSecret,
    });
    final grant = response['reset_grant'] as String?;
    if (response['status'] == 'approved' && grant != null) {
      await _storage.write(key: _resetGrantKey, value: grant);
      return grant;
    }
    return null;
  }

  Future<void> resetPassword({
    required String resetGrant,
    required String newPassword,
  }) async {
    await _post('recovery/reset', {
      'reset_grant': resetGrant,
      'new_password': newPassword,
    });
    await _storage.delete(key: _recoveryIdKey);
    await _storage.delete(key: _recoverySecretKey);
    await _storage.delete(key: _resetGrantKey);
  }

  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    await _post('change-password', {
      'current_password': currentPassword,
      'new_password': newPassword,
    }, authenticated: true);
    await _clearSession();
  }

  Future<List<Map<String, dynamic>>> listRecoveryContacts() async {
    final response = await _get('recovery/contacts');
    return _asMapList(response['contacts']);
  }

  Future<List<Map<String, dynamic>>> listPasswordRecoveryRequests() async {
    final response = await _get('recovery/requests');
    return _asMapList(response['requests']);
  }

  Future<void> requestRecoveryContact(String niptoId) async {
    await _post('recovery/link', {'recovery_nipto_id': niptoId}, authenticated: true);
  }

  Future<void> respondRecoveryContact({
    required String requestId,
    required bool accept,
  }) async {
    await _post('recovery/contact-response', {
      'request_id': requestId,
      'accept': accept,
    }, authenticated: true);
  }

  Future<void> respondPasswordRecovery({
    required String challengeId,
    required bool approve,
  }) async {
    await _post('recovery/respond', {
      'challenge_id': challengeId,
      'approve': approve,
    }, authenticated: true);
  }

  Future<void> _refreshSession() {
    final existing = _refreshInFlight;
    if (existing != null) return existing;
    final operation = _performRefresh();
    _refreshInFlight = operation;
    return operation.whenComplete(() => _refreshInFlight = null);
  }

  Future<void> _performRefresh() async {
    final refreshToken = _refreshToken;
    if (refreshToken == null) throw const NiptoAuthException('Session expired.');
    final response = await _post('refresh', {'refresh_token': refreshToken});
    await _applySession(response);
  }

  Future<void> _applySession(Map<String, dynamic> response) async {
    final accessToken = response['access_token'] as String?;
    final refreshToken = response['refresh_token'] as String?;
    final expiresIn = response['expires_in'] as int?;
    final user = response['user'];
    if (accessToken == null ||
        refreshToken == null ||
        expiresIn == null ||
        user is! Map) {
      throw const NiptoAuthException('The identity service returned an invalid session.');
    }

    final nextSession = NiptoSession.fromJson(
      Map<String, dynamic>.from(user),
    );
    await _storage.write(key: _refreshTokenKey, value: refreshToken);
    _accessToken = accessToken;
    _refreshToken = refreshToken;
    _accessExpiresAt = DateTime.now().add(Duration(seconds: expiresIn));
    _session = nextSession;
    _changes.add(nextSession);
  }

  Future<void> _clearSession() async {
    _accessToken = null;
    _refreshToken = null;
    _accessExpiresAt = null;
    _session = null;
    await _storage.delete(key: _refreshTokenKey);
    _changes.add(null);
  }

  Future<Map<String, dynamic>> _get(String path) async {
    return _send('GET', path, null, authenticated: true);
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> payload, {
    bool authenticated = false,
  }) async {
    return _send('POST', path, payload, authenticated: authenticated);
  }

  Future<Map<String, dynamic>> _send(
    String method,
    String path,
    Map<String, dynamic>? payload, {
    required bool authenticated,
  }) async {
    final baseUrl = _baseUrl;
    if (baseUrl == null) {
      throw const NiptoAuthException('Nipto is not initialized.');
    }
    final request = await (method == 'GET'
        ? _http.getUrl(Uri.parse('$baseUrl/$path'))
        : _http.postUrl(Uri.parse('$baseUrl/$path')));
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (payload != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(payload));
    }
    if (authenticated) {
      final token = await accessToken();
      if (token == null) {
        throw const NiptoAuthException('Sign in to continue.');
      }
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }

    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    Map<String, dynamic> decoded = {};
    if (text.isNotEmpty) {
      final value = jsonDecode(text);
      if (value is Map) decoded = Map<String, dynamic>.from(value);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw NiptoAuthException(
        decoded['error'] as String? ?? 'Nipto could not complete that request.',
        statusCode: response.statusCode,
      );
    }
    return decoded;
  }

  List<Map<String, dynamic>> _asMapList(dynamic value) {
    if (value is! List) return const [];
    return value.whereType<Map>().map(Map<String, dynamic>.from).toList();
  }
}
), '');
    _publishableKey = publishableKey;
    _baseUrl = _supabaseUrl! + '/functions/v1/nipto-identity';
    final projectRef = Uri.parse(_supabaseUrl!).host.split('.').first;
    _legacyStorageKey = 'sb-$projectRef-auth-token';

    _refreshToken = await _storage.read(key: _refreshTokenKey);
    await _loadLegacySession();
    _initialized = true;
    if (_refreshToken != null) {
      try {
        await _refreshSession();
      } on NiptoAuthException catch (error) {
        if (error.statusCode == 401 || error.statusCode == 400) {
          await _clearSession();
        }
      } catch (_) {
        // Preserve the encrypted refresh token during transient network errors.
      }
    }
  }

  Future<void> _loadLegacySession() async {
    _legacyAccessToken = await _storage.read(key: _legacyAccessKey);
    _legacyRefreshToken = await _storage.read(key: _legacyRefreshKey);
    if (_legacyRefreshToken != null) return;

    final storageKey = _legacyStorageKey;
    if (storageKey == null) return;
    final raw = await _legacyPreferences.getString(storageKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      final access = decoded['access_token'];
      final refresh = decoded['refresh_token'];
      if (access is! String || refresh is! String || refresh.isEmpty) return;
      _legacyAccessToken = access;
      _legacyRefreshToken = refresh;
      final expiresAt = decoded['expires_at'];
      if (expiresAt is int) {
        _legacyExpiresAt = DateTime.fromMillisecondsSinceEpoch(expiresAt * 1000);
      }
      await _storage.write(key: _legacyAccessKey, value: access);
      await _storage.write(key: _legacyRefreshKey, value: refresh);
      await _legacyPreferences.remove(storageKey);
    } catch (_) {
      // Do not treat malformed legacy preferences as a valid signed-in account.
    }
  }

  Future<void> _refreshLegacySession() async {
    final expiresAt = _legacyExpiresAt;
    if (_legacyAccessToken != null &&
        expiresAt != null &&
        expiresAt.isAfter(DateTime.now().add(const Duration(seconds: 60)))) {
      return;
    }
    final refreshToken = _legacyRefreshToken;
    final baseUrl = _supabaseUrl;
    final publishableKey = _publishableKey;
    if (refreshToken == null || baseUrl == null || publishableKey == null) {
      throw const NiptoAuthException('The previous signed-in session is unavailable.');
    }

    final request = await _http.postUrl(
      Uri.parse('$baseUrl/auth/v1/token?grant_type=refresh_token'),
    );
    request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    request.headers.set('apikey', publishableKey);
    request.write(jsonEncode({'refresh_token': refreshToken}));
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    Map<String, dynamic> data = {};
    if (text.isNotEmpty) {
      final value = jsonDecode(text);
      if (value is Map) data = Map<String, dynamic>.from(value);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      await _clearLegacySession();
      throw NiptoAuthException(
        'Your previous session expired. Open the previous Nipto version and sign in before migrating.',
        statusCode: response.statusCode,
      );
    }
    final access = data['access_token'] as String?;
    final refresh = data['refresh_token'] as String?;
    final expiresIn = data['expires_in'] as int?;
    if (access == null || refresh == null || expiresIn == null) {
      throw const NiptoAuthException('The previous session could not be refreshed.');
    }
    _legacyAccessToken = access;
    _legacyRefreshToken = refresh;
    _legacyExpiresAt = DateTime.now().add(Duration(seconds: expiresIn));
    await _storage.write(key: _legacyAccessKey, value: access);
    await _storage.write(key: _legacyRefreshKey, value: refresh);
  }

  Future<NiptoSession> migrateLegacyAccount(String newPassword) async {
    await _refreshLegacySession();
    final token = _legacyAccessToken;
    if (token == null) {
      throw const NiptoAuthException('An existing signed-in session is required to migrate this account.');
    }
    final response = await _postWithBearer(
      'migrate',
      {'new_password': newPassword, 'device_label': 'Android device'},
      token,
    );
    await _applySession(response);
    await _clearLegacySession();
    return _session!;
  }

  Future<Map<String, dynamic>> _postWithBearer(
    String path,
    Map<String, dynamic> payload,
    String bearer,
  ) async {
    final baseUrl = _baseUrl;
    if (baseUrl == null) throw const NiptoAuthException('Nipto is not initialized.');
    final request = await _http.postUrl(Uri.parse('$baseUrl/$path'));
    request.headers.contentType = ContentType.json;
    request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $bearer');
    request.write(jsonEncode(payload));
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    Map<String, dynamic> decoded = {};
    if (text.isNotEmpty) {
      final value = jsonDecode(text);
      if (value is Map) decoded = Map<String, dynamic>.from(value);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw NiptoAuthException(
        decoded['error'] as String? ?? 'Account migration could not be completed.',
        statusCode: response.statusCode,
      );
    }
    return decoded;
  }

  Future<void> _clearLegacySession() async {
    _legacyAccessToken = null;
    _legacyRefreshToken = null;
    _legacyExpiresAt = null;
    await _storage.delete(key: _legacyAccessKey);
    await _storage.delete(key: _legacyRefreshKey);
    final storageKey = _legacyStorageKey;
    if (storageKey != null) await _legacyPreferences.remove(storageKey);
  }

  Future<String?> accessToken() async {
    if (!_initialized) return null;
    final expiresAt = _accessExpiresAt;
    if (_accessToken == null ||
        expiresAt == null ||
        expiresAt.isBefore(DateTime.now().add(const Duration(seconds: 60)))) {
      if (_refreshToken == null) return null;
      try {
        await _refreshSession();
      } catch (error) {
        if (error is NiptoAuthException &&
            (error.statusCode == 401 || error.statusCode == 400)) {
          await _clearSession();
        }
        final currentExpiry = _accessExpiresAt;
        if (_accessToken != null &&
            currentExpiry != null &&
            currentExpiry.isAfter(DateTime.now())) {
          return _accessToken;
        }
        return null;
      }
    }
    return _accessToken;
  }

  Future<NiptoSession> register({
    required String niptoId,
    required String displayName,
    required String password,
    String? recoveryNiptoId,
  }) async {
    final response = await _post('register', {
      'nipto_id': niptoId.trim().replaceFirst(RegExp(r'^@'), ''),
      'display_name': displayName.trim(),
      'password': password,
      if (recoveryNiptoId != null && recoveryNiptoId.trim().isNotEmpty)
        'recovery_nipto_id':
            recoveryNiptoId.trim().replaceFirst(RegExp(r'^@'), ''),
      'device_label': 'Android device',
    });
    await _applySession(response);
    return _session!;
  }

  Future<NiptoSession> signIn({
    required String niptoId,
    required String password,
  }) async {
    final response = await _post('login', {
      'nipto_id': niptoId.trim().replaceFirst(RegExp(r'^@'), ''),
      'password': password,
      'device_label': 'Android device',
    });
    await _applySession(response);
    return _session!;
  }

  Future<void> signOut() async {
    try {
      await _post('logout', const {}, authenticated: true);
    } catch (_) {
      // Local credentials are still cleared if the device is offline.
    } finally {
      await _clearSession();
    }
  }

  Future<void> signOutEverywhere() async {
    try {
      await _post('logout-all', const {}, authenticated: true);
    } finally {
      await _clearSession();
    }
  }

  Future<void> startPasswordRecovery(String niptoId) async {
    final response = await _post('recovery/start', {
      'nipto_id': niptoId.trim().replaceFirst(RegExp(r'^@'), ''),
    });
    final challengeId = response['challenge_id'] as String?;
    final challengeSecret = response['challenge_secret'] as String?;
    if (challengeId == null || challengeSecret == null) {
      throw const NiptoAuthException('Could not start account recovery.');
    }
    await _storage.write(key: _recoveryIdKey, value: challengeId);
    await _storage.write(key: _recoverySecretKey, value: challengeSecret);
  }

  Future<String?> checkPasswordRecoveryApproval() async {
    final challengeId = await _storage.read(key: _recoveryIdKey);
    final challengeSecret = await _storage.read(key: _recoverySecretKey);
    if (challengeId == null || challengeSecret == null) {
      throw const NiptoAuthException('Start a new recovery request.');
    }
    final response = await _post('recovery/claim', {
      'challenge_id': challengeId,
      'challenge_secret': challengeSecret,
    });
    final grant = response['reset_grant'] as String?;
    if (response['status'] == 'approved' && grant != null) {
      await _storage.write(key: _resetGrantKey, value: grant);
      return grant;
    }
    return null;
  }

  Future<void> resetPassword({
    required String resetGrant,
    required String newPassword,
  }) async {
    await _post('recovery/reset', {
      'reset_grant': resetGrant,
      'new_password': newPassword,
    });
    await _storage.delete(key: _recoveryIdKey);
    await _storage.delete(key: _recoverySecretKey);
    await _storage.delete(key: _resetGrantKey);
  }

  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    await _post('change-password', {
      'current_password': currentPassword,
      'new_password': newPassword,
    }, authenticated: true);
    await _clearSession();
  }

  Future<List<Map<String, dynamic>>> listRecoveryContacts() async {
    final response = await _get('recovery/contacts');
    return _asMapList(response['contacts']);
  }

  Future<List<Map<String, dynamic>>> listPasswordRecoveryRequests() async {
    final response = await _get('recovery/requests');
    return _asMapList(response['requests']);
  }

  Future<void> requestRecoveryContact(String niptoId) async {
    await _post('recovery/link', {'recovery_nipto_id': niptoId}, authenticated: true);
  }

  Future<void> respondRecoveryContact({
    required String requestId,
    required bool accept,
  }) async {
    await _post('recovery/contact-response', {
      'request_id': requestId,
      'accept': accept,
    }, authenticated: true);
  }

  Future<void> respondPasswordRecovery({
    required String challengeId,
    required bool approve,
  }) async {
    await _post('recovery/respond', {
      'challenge_id': challengeId,
      'approve': approve,
    }, authenticated: true);
  }

  Future<void> _refreshSession() {
    final existing = _refreshInFlight;
    if (existing != null) return existing;
    final operation = _performRefresh();
    _refreshInFlight = operation;
    return operation.whenComplete(() => _refreshInFlight = null);
  }

  Future<void> _performRefresh() async {
    final refreshToken = _refreshToken;
    if (refreshToken == null) throw const NiptoAuthException('Session expired.');
    final response = await _post('refresh', {'refresh_token': refreshToken});
    await _applySession(response);
  }

  Future<void> _applySession(Map<String, dynamic> response) async {
    final accessToken = response['access_token'] as String?;
    final refreshToken = response['refresh_token'] as String?;
    final expiresIn = response['expires_in'] as int?;
    final user = response['user'];
    if (accessToken == null ||
        refreshToken == null ||
        expiresIn == null ||
        user is! Map) {
      throw const NiptoAuthException('The identity service returned an invalid session.');
    }

    final nextSession = NiptoSession.fromJson(
      Map<String, dynamic>.from(user),
    );
    await _storage.write(key: _refreshTokenKey, value: refreshToken);
    _accessToken = accessToken;
    _refreshToken = refreshToken;
    _accessExpiresAt = DateTime.now().add(Duration(seconds: expiresIn));
    _session = nextSession;
    _changes.add(nextSession);
  }

  Future<void> _clearSession() async {
    _accessToken = null;
    _refreshToken = null;
    _accessExpiresAt = null;
    _session = null;
    await _storage.delete(key: _refreshTokenKey);
    _changes.add(null);
  }

  Future<Map<String, dynamic>> _get(String path) async {
    return _send('GET', path, null, authenticated: true);
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> payload, {
    bool authenticated = false,
  }) async {
    return _send('POST', path, payload, authenticated: authenticated);
  }

  Future<Map<String, dynamic>> _send(
    String method,
    String path,
    Map<String, dynamic>? payload, {
    required bool authenticated,
  }) async {
    final baseUrl = _baseUrl;
    if (baseUrl == null) {
      throw const NiptoAuthException('Nipto is not initialized.');
    }
    final request = await (method == 'GET'
        ? _http.getUrl(Uri.parse('$baseUrl/$path'))
        : _http.postUrl(Uri.parse('$baseUrl/$path')));
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (payload != null) {
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(payload));
    }
    if (authenticated) {
      final token = await accessToken();
      if (token == null) {
        throw const NiptoAuthException('Sign in to continue.');
      }
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }

    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    Map<String, dynamic> decoded = {};
    if (text.isNotEmpty) {
      final value = jsonDecode(text);
      if (value is Map) decoded = Map<String, dynamic>.from(value);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw NiptoAuthException(
        decoded['error'] as String? ?? 'Nipto could not complete that request.',
        statusCode: response.statusCode,
      );
    }
    return decoded;
  }

  List<Map<String, dynamic>> _asMapList(dynamic value) {
    if (value is! List) return const [];
    return value.whereType<Map>().map(Map<String, dynamic>.from).toList();
  }
}
