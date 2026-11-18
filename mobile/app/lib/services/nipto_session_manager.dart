import 'dart:async';
import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

class NiptoSession {
  const NiptoSession({
    required this.userId,
    required this.niptoId,
    required this.displayName,
    required this.sessionId,
  });

  final String userId;
  final String niptoId;
  final String displayName;
  final String sessionId;
}

class NiptoAuthException implements Exception {
  const NiptoAuthException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => message;
}

/// Nipto owns the credentials through its custom OIDC provider. Supabase Auth
/// brokers sessions only; the provider is configured with email_optional=true.
class NiptoSessionManager {
  NiptoSessionManager._();
  static final NiptoSessionManager instance = NiptoSessionManager._();

  static const _recoveryIdKey = 'nipto.recovery.challenge_id.v1';
  static const _recoverySecretKey = 'nipto.recovery.challenge_secret.v1';
  static const _recoveryStartedAtKey = 'nipto.recovery.started_at.v1';
  static const _recoveryNiptoIdKey = 'nipto.recovery.nipto_id.v1';
  static const _resetGrantKey = 'nipto.recovery.reset_grant.v1';
  static const _pendingLinkNiptoIdKey = 'nipto.auth.pending_link_id.v1';

  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  String? _supabaseUrl;
  String? _publishableKey;
  String? _baseUrl;
  StreamSubscription<AuthState>? _authSubscription;
  bool _linkCompletionInFlight = false;
  String? _linkedUserId;

  SupabaseClient get _client => Supabase.instance.client;
  Stream<NiptoSession?> get changes => _client.auth.onAuthStateChange.map((event) {
        final session = event.session;
        return session == null ? null : _fromSession(session);
      });

  NiptoSession? get currentSession {
    final session = _client.auth.currentSession;
    return session == null ? null : _fromSession(session);
  }

  String? get userId => _client.auth.currentUser?.id;
  bool get isSignedIn => _client.auth.currentSession != null;

  bool get hasLegacySession {
    final user = _client.auth.currentUser;
    if (user == null) return false;
    final identities = user.identities ?? [];
    final hasNiptoIdentity = identities.any((identity) => identity.provider == 'custom:nipto');
    return user.email != null || !hasNiptoIdentity;
  }

  NiptoSession _fromSession(Session session) {
    final user = session.user;
    final metadata = user.userMetadata ?? const <String, dynamic>{};
    final claims = _jwtPayload(session.accessToken);
    return NiptoSession(
      userId: user.id,
      niptoId: (metadata['nipto_id'] ?? metadata['preferred_username'] ?? '').toString(),
      displayName: (metadata['display_name'] ?? metadata['name'] ?? '').toString(),
      sessionId: (claims['session_id'] ?? '').toString(),
    );
  }

  Map<String, dynamic> _jwtPayload(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return const {};
      final decoded = utf8.decode(base64Url.decode(base64Url.normalize(parts[1])));
      final value = jsonDecode(decoded);
      return value is Map ? Map<String, dynamic>.from(value) : const {};
    } catch (_) {
      return const {};
    }
  }

  Future<void> initialize(String supabaseUrl, String publishableKey) async {
    _supabaseUrl = supabaseUrl.replaceFirst(RegExp(r'/$'), '');
    _publishableKey = publishableKey;
    _baseUrl = '$_supabaseUrl/functions/v1/nipto-identity';
    _authSubscription ??= _client.auth.onAuthStateChange.listen((event) {
      final user = event.session?.user ?? _client.auth.currentUser;
      if (user != null && _hasNiptoIdentity(user)) {
        unawaited(_completeIdentityLink(user));
      }
    });
    final currentUser = _client.auth.currentUser;
    if (currentUser != null && _hasNiptoIdentity(currentUser)) {
      unawaited(_completeIdentityLink(currentUser));
    }
  }

  bool _hasNiptoIdentity(User user) {
    final identities = user.identities ?? [];
    return identities.any((identity) => identity.provider == 'custom:nipto');
  }

  Future<void> _completeIdentityLink(User user) async {
    if (_linkCompletionInFlight || _linkedUserId == user.id) return;
    _linkCompletionInFlight = true;
    try {
      final pendingId = await _storage.read(key: _pendingLinkNiptoIdKey);
      final metadata = user.userMetadata ?? const <String, dynamic>{};
      final niptoId = (pendingId ?? metadata['nipto_id'] ??
              metadata['preferred_username'] ?? '')
          .toString();
      if (niptoId.isEmpty) return;
      await _post('account/link', {'nipto_id': niptoId}, authenticated: true);
      await _client.auth.refreshSession();
      final refreshedUser = _client.auth.currentUser;
      if (refreshedUser != null &&
          refreshedUser.email == null &&
          _hasNiptoIdentity(refreshedUser)) {
        _linkedUserId = refreshedUser.id;
        await _storage.delete(key: _pendingLinkNiptoIdKey);
      }
    } catch (_) {
      // A later auth event or app restart retries the idempotent linking step.
    } finally {
      _linkCompletionInFlight = false;
    }
  }

  Future<void> signIn() => _startOidc(screen: 'login');
  Future<void> register() => _startOidc(screen: 'register');

  Future<void> _startOidc({required String screen}) async {
    try {
      final launched = await _client.auth.signInWithOAuth(
        OAuthProvider('custom:nipto'),
        redirectTo: 'nipto://auth-callback',
        queryParams: {'screen': screen},
      );
      if (!launched) {
        throw const NiptoAuthException('Nipto sign-in could not be opened. Please try again.');
      }
    } on AuthException catch (error) {
      throw NiptoAuthException(error.message, statusCode: error.statusCode == null
          ? null
          : int.tryParse(error.statusCode!));
    }
  }

  Future<void> linkLegacyAccount() async {
    try {
      final migration = await _post('migration/prepare', const {}, authenticated: true);
      final ticket = migration['migration_ticket'] as String?;
      final niptoId = migration['nipto_id'] as String?;
      if (ticket == null || niptoId == null) {
        throw const NiptoAuthException('Could not prepare your Nipto account migration.');
      }
      await _storage.write(key: _pendingLinkNiptoIdKey, value: niptoId);
      await _client.auth.linkIdentity(
        OAuthProvider('custom:nipto'),
        redirectTo: 'nipto://auth-callback',
        queryParams: {'screen': 'link', 'migration_ticket': ticket},
      );
    } on AuthException catch (error) {
      await _storage.delete(key: _pendingLinkNiptoIdKey);
      throw NiptoAuthException(error.message);
    }
  }

  Future<void> signOut() async {
    try {
      await _client.auth.signOut(scope: SignOutScope.local);
    } on AuthException catch (error) {
      throw NiptoAuthException(error.message);
    }
  }

  Future<void> signOutEverywhere() async {
    try {
      await _client.auth.signOut(scope: SignOutScope.global);
    } on AuthException catch (error) {
      throw NiptoAuthException(error.message);
    }
  }

  Future<void> startPasswordRecovery(String niptoId) async {
    final normalizedNiptoId =
        niptoId.trim().replaceFirst(RegExp(r'^@'), '').toLowerCase();
    final existingNiptoId = await _storage.read(key: _recoveryNiptoIdKey);
    final existingGrant = await _storage.read(key: _resetGrantKey);
    if (existingNiptoId == normalizedNiptoId) {
      if (existingGrant != null) return;
      final existingId = await _storage.read(key: _recoveryIdKey);
      final existingSecret = await _storage.read(key: _recoverySecretKey);
      final startedRaw = await _storage.read(key: _recoveryStartedAtKey);
      final startedAt = int.tryParse(startedRaw ?? '');
      if (existingId != null && existingSecret != null && startedAt != null &&
          DateTime.now().millisecondsSinceEpoch - startedAt <
              const Duration(minutes: 15).inMilliseconds) {
        return;
      }
    }
    await _clearRecoveryChallenge();
    await _storage.delete(key: _resetGrantKey);
    final response = await _post('recovery/start', {
      'nipto_id': normalizedNiptoId,
    });
    final challengeId = response['challenge_id'] as String?;
    final challengeSecret = response['challenge_secret'] as String?;
    if (challengeId == null || challengeSecret == null) {
      throw const NiptoAuthException('Could not start account recovery.');
    }
    await _storage.write(key: _recoveryIdKey, value: challengeId);
    await _storage.write(key: _recoverySecretKey, value: challengeSecret);
    await _storage.write(key: _recoveryNiptoIdKey, value: normalizedNiptoId);
    await _storage.write(
      key: _recoveryStartedAtKey,
      value: DateTime.now().millisecondsSinceEpoch.toString(),
    );
  }

  Future<String?> checkPasswordRecoveryApproval() async {
    final existingGrant = await _storage.read(key: _resetGrantKey);
    if (existingGrant != null) return existingGrant;
    final challengeId = await _storage.read(key: _recoveryIdKey);
    final challengeSecret = await _storage.read(key: _recoverySecretKey);
    if (challengeId == null || challengeSecret == null) {
      throw const NiptoAuthException('Start a new recovery request.');
    }
    final response = await _post('recovery/claim', {
      'challenge_id': challengeId,
      'challenge_secret': challengeSecret,
    });
    final status = response['status'];
    if (status == 'rejected') {
      await _clearRecoveryChallenge();
      throw const NiptoAuthException(
        'Your trusted Nipto account declined the request. Contact them or choose another recovery account.',
      );
    }
    if (status == 'expired') {
      await _clearRecoveryChallenge();
      throw const NiptoAuthException('This recovery request expired. Start a new request.');
    }
    if (status == 'consumed') {
      await _clearRecoveryChallenge();
      throw const NiptoAuthException(
        'This recovery approval has already been used. Start a new request if you still need to reset your password.',
      );
    }
    final grant = response['reset_grant'] as String?;
    if (status == 'approved' && grant != null) {
      await _storage.write(key: _resetGrantKey, value: grant);
      return grant;
    }
    return null;
  }

  Future<void> resetPassword({
    required String resetGrant,
    required String newPassword,
  }) async {
    try {
      await _post('recovery/reset', {
        'reset_grant': resetGrant,
        'new_password': newPassword,
      });
    } on NiptoAuthException catch (error) {
      if (error.statusCode == 400) {
        await _clearRecoveryChallenge();
        await _storage.delete(key: _resetGrantKey);
      }
      rethrow;
    }
    await _clearRecoveryChallenge();
    await _storage.delete(key: _resetGrantKey);
  }

  Future<void> _clearRecoveryChallenge() async {
    await _storage.delete(key: _recoveryIdKey);
    await _storage.delete(key: _recoverySecretKey);
    await _storage.delete(key: _recoveryStartedAtKey);
    await _storage.delete(key: _recoveryNiptoIdKey);
  }

  Future<void> changePassword({
    required String currentPassword,
    required String newPassword,
  }) async {
    await _post('change-password', {
      'current_password': currentPassword,
      'new_password': newPassword,
    }, authenticated: true);
    await signOut();
  }

  Future<List<Map<String, dynamic>>> getIceServers() async {
    final response = await _get('turn-credentials');
    return _asMapList(response['ice_servers']);
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

  Future<void> removeRecoveryContact(String requestId) async {
    await _post('recovery/contact-remove', {'request_id': requestId}, authenticated: true);
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

  Future<List<Map<String, dynamic>>> listSessions() async {
    final response = await _get('sessions');
    return _asMapList(response['sessions']);
  }

  Future<void> revokeSession(String sessionId) async {
    await _post('sessions/revoke', {'session_id': sessionId}, authenticated: true);
    if (sessionId == currentSession?.sessionId) await signOut();
  }

  Future<Map<String, dynamic>> _get(String path) =>
      _send('GET', path, null, authenticated: true);

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> payload, {
    bool authenticated = false,
  }) => _send('POST', path, payload, authenticated: authenticated);

  Future<Map<String, dynamic>> _send(
    String method,
    String path,
    Map<String, dynamic>? payload, {
    required bool authenticated,
  }) async {
    final baseUrl = _baseUrl;
    final publishableKey = _publishableKey;
    if (baseUrl == null || publishableKey == null) {
      throw const NiptoAuthException('Nipto is not initialized.');
    }
    final uri = Uri.parse('$baseUrl/$path');
    final headers = <String, String>{
      'Accept': 'application/json',
      'apikey': publishableKey,
    };
    if (payload != null) headers['Content-Type'] = 'application/json';
    if (authenticated) {
      final token = _client.auth.currentSession?.accessToken;
      if (token == null) {
        throw const NiptoAuthException(
          'Sign in to continue.',
          statusCode: 401,
        );
      }
      headers['Authorization'] = 'Bearer $token';
    }

    late final http.Response response;
    try {
      response = (method == 'GET'
              ? http.get(uri, headers: headers)
              : http.post(uri, headers: headers, body: jsonEncode(payload)))
          .timeout(const Duration(seconds: 15))
          .then((value) => value);
    } on TimeoutException {
      throw const NiptoAuthException(
        'The Nipto service took too long to respond. Please try again.',
      );
    } on http.ClientException {
      throw const NiptoAuthException(
        'Could not connect to Nipto. Check your internet connection.',
      );
    }

    Map<String, dynamic> data = {};
    if (response.body.isNotEmpty) {
      final value = jsonDecode(response.body);
      if (value is Map) data = Map<String, dynamic>.from(value);
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw NiptoAuthException(
        data['error'] as String? ?? 'Nipto could not complete that request.',
        statusCode: response.statusCode,
      );
    }
    return data;
  }

  List<Map<String, dynamic>> _asMapList(dynamic value) {
    if (value is! List) return const [];
    return value.whereType<Map>().map(Map<String, dynamic>.from).toList();
  }
}