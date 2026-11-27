import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'nipto_push_service.dart';
import 'nipto_recovery_challenge_guard.dart';
import 'nipto_reset_grant_cache_guard.dart';

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

/// Nipto owns credentials through its custom OIDC provider. Supabase Auth
/// brokers sessions only; registration does not require email or phone.
class NiptoSessionManager {
  NiptoSessionManager._();
  static final NiptoSessionManager instance = NiptoSessionManager._();

  static const _recoveryIdKey = 'nipto.recovery.challenge_id.v1';
  static const _recoverySecretKey = 'nipto.recovery.challenge_secret.v1';
  static const _recoveryStartedAtKey = 'nipto.recovery.started_at.v1';
  static const _recoveryNiptoIdKey = 'nipto.recovery.nipto_id.v1';
  static const _resetGrantKey = 'nipto.recovery.reset_grant.v1';
  static const _resetGrantIssuedAtKey =
      'nipto.recovery.reset_grant_issued_at.v1';
  static const _pendingLinkNiptoIdKey = 'nipto.auth.pending_link_id.v1';

  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  String? _publishableKey;
  String? _baseUrl;
  StreamSubscription<AuthState>? _authSubscription;
  bool _linkCompletionInFlight = false;
  User? _queuedLinkUser;
  String? _linkedUserId;

  SupabaseClient get _client => Supabase.instance.client;
  Stream<NiptoSession?> get changes =>
      _client.auth.onAuthStateChange.map((event) {
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
    final hasNiptoIdentity = identities.any(
      (identity) => identity.provider == 'custom:nipto',
    );
    return user.email != null || !hasNiptoIdentity;
  }

  NiptoSession _fromSession(Session session) {
    final user = session.user;
    final claims = _jwtPayload(session.accessToken);
    return NiptoSession(
      userId: user.id,
      niptoId: _niptoMetadataValue(
        user.userMetadata,
        'nipto_id',
        'preferred_username',
      ),
      displayName: _niptoMetadataValue(
        user.userMetadata,
        'display_name',
        'name',
      ),
      sessionId: (claims['session_id'] ?? '').toString(),
    );
  }

  /// Supabase stores allowlisted custom OIDC claims under `custom_claims`.
  /// Older sessions and standard profile claims remain supported as fallbacks.
  static String _niptoMetadataValue(
    Map<String, dynamic>? metadata,
    String customKey,
    String standardKey,
  ) {
    if (metadata == null) return '';
    final customClaims = metadata['custom_claims'];
    final custom = customClaims is Map
        ? customClaims
        : const <dynamic, dynamic>{};
    return (metadata[customKey] ??
            custom[customKey] ??
            metadata[standardKey] ??
            custom[standardKey] ??
            '')
        .toString();
  }

  Map<String, dynamic> _jwtPayload(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return const {};
      final decoded = utf8.decode(
        base64Url.decode(base64Url.normalize(parts[1])),
      );
      final value = jsonDecode(decoded);
      return value is Map ? Map<String, dynamic>.from(value) : const {};
    } catch (_) {
      return const {};
    }
  }

  Future<void> initialize(String supabaseUrl, String publishableKey) async {
    final normalizedUrl = supabaseUrl.trim().replaceFirst(RegExp(r'/$'), '');
    _publishableKey = publishableKey.trim();
    _baseUrl = '$normalizedUrl/functions/v1/nipto-identity';
    _authSubscription ??= _client.auth.onAuthStateChange.listen((event) {
      final user = event.session?.user ?? _client.auth.currentUser;
      if (user != null && _hasNiptoIdentity(user))
        unawaited(_completeIdentityLink(user));
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
    if (_linkedUserId == user.id) return;
    if (_linkCompletionInFlight) {
      _queuedLinkUser = user;
      return;
    }
    _linkCompletionInFlight = true;
    try {
      if (_client.auth.currentUser?.id != user.id) return;
      final pendingId = await _storage.read(key: _pendingLinkNiptoIdKey);
      if (_client.auth.currentUser?.id != user.id) return;
      final niptoId =
          (pendingId ??
                  _niptoMetadataValue(
                    user.userMetadata,
                    'nipto_id',
                    'preferred_username',
                  ))
              .trim()
              .replaceFirst(RegExp(r'^@'), '')
              .toLowerCase();
      if (niptoId.isEmpty) return;
      await _post('account/link', {'nipto_id': niptoId}, authenticated: true);
      if (_client.auth.currentUser?.id != user.id) return;
      await _client.auth.refreshSession();
      final refreshedUser = _client.auth.currentUser;
      if (refreshedUser != null &&
          refreshedUser.id == user.id &&
          refreshedUser.email == null &&
          _hasNiptoIdentity(refreshedUser)) {
        _linkedUserId = refreshedUser.id;
        await _storage.delete(key: _pendingLinkNiptoIdKey);
      }
    } catch (_) {
      // Auth events/app restarts retry this idempotent operation.
    } finally {
      _linkCompletionInFlight = false;
      final queuedUser = _queuedLinkUser;
      _queuedLinkUser = null;
      if (queuedUser != null && queuedUser.id != _linkedUserId)
        unawaited(_completeIdentityLink(queuedUser));
    }
  }

  /// Validates syntax locally, then asks the server whether the ID is available.
  /// The server remains authoritative and registration must handle races.
  Future<Map<String, dynamic>> checkNiptoId(String niptoId) async {
    final normalized = niptoId
        .trim()
        .replaceFirst(RegExp(r'^@'), '')
        .toLowerCase();
    if (normalized.length < 3 ||
        normalized.length > 24 ||
        !RegExp(r'^[a-z0-9]+(?:_[a-z0-9]+)*$').hasMatch(normalized)) {
      throw const NiptoAuthException(
        'Use 3–24 lowercase letters or numbers, with single underscores between parts.',
        statusCode: 400,
      );
    }
    return _post('id/check', {'nipto_id': normalized});
  }

  Future<void> signIn() => _startOidc(screen: 'login');
  Future<void> register() => _startOidc(screen: 'register');

  /// Native credential sign-in. This starts a real Supabase OIDC authorization
  /// request, submits the credentials to Nipto's native bridge, and finishes
  /// the authorization-code/PKCE exchange through Supabase Auth.
  Future<void> signInWithNiptoId({
    required String niptoId,
    required String password,
  }) => _nativeAuthenticate(
    action: 'login',
    niptoId: niptoId,
    password: password,
  );

  /// Native registration with the same OIDC/PKCE session bridge used by sign-in.
  Future<void> registerNiptoAccount({
    required String displayName,
    required String niptoId,
    required String password,
    required String passwordConfirmation,
  }) => _nativeAuthenticate(
    action: 'register',
    displayName: displayName,
    niptoId: niptoId,
    password: password,
    passwordConfirmation: passwordConfirmation,
  );

  Future<void> _nativeAuthenticate({
    required String action,
    required String niptoId,
    required String password,
    String? displayName,
    String? passwordConfirmation,
  }) async {
    final key = _publishableKey;
    if (key == null)
      throw const NiptoAuthException('Nipto is not initialized.');
    final redirectTo = kIsWeb ? Uri.base.origin : 'nipto://auth-callback';

    final preflightClient = http.Client();
    try {
      // Generate and securely persist the client PKCE verifier through the
      // Supabase SDK, then let Supabase create the provider state and the
      // provider-facing PKCE challenge.
      final oauth = await _client.auth.getOAuthSignInUrl(
        provider: OAuthProvider('custom:nipto'),
        redirectTo: redirectTo,
        queryParams: {'screen': action},
      );
      final preflightRequest = http.Request('GET', Uri.parse(oauth.url))
        ..headers.addAll({'apikey': key, 'Accept': 'application/json'})
        ..followRedirects = false;
      final preflight = await preflightClient
          .send(preflightRequest)
          .timeout(const Duration(seconds: 15));
      await preflight.stream.drain<void>();
      final location = preflight.headers['location'];
      final isRedirect =
          preflight.statusCode >= 300 && preflight.statusCode < 400;
      if (!isRedirect || location == null || location.isEmpty) {
        throw const NiptoAuthException(
          'Nipto could not start secure sign-in. Please try again.',
        );
      }
      final providerRequest = Uri.parse(location);
      final params = providerRequest.queryParameters;
      final state = params['state'] ?? '';
      final challenge = params['code_challenge'] ?? '';
      final method = params['code_challenge_method'] ?? '';
      if (state.isEmpty ||
          state.length > 512 ||
          challenge.isEmpty ||
          method.toUpperCase() != 'S256' ||
          params['response_type'] != 'code') {
        throw const NiptoAuthException(
          'Nipto received an invalid sign-in request. Please try again.',
        );
      }

      final result = await _post('authorize/native', <String, dynamic>{
        'action': action,
        'screen': params['screen'] ?? action,
        'client_id': params['client_id'] ?? '',
        'redirect_uri': params['redirect_uri'] ?? '',
        'response_type': params['response_type'] ?? '',
        'scope': params['scope'] ?? '',
        'state': state,
        if (params['nonce'] != null) 'nonce': params['nonce']!,
        'code_challenge': challenge,
        'code_challenge_method': 'S256',
        'nipto_id': niptoId,
        'password': password,
        if (displayName != null) 'display_name': displayName,
        if (passwordConfirmation != null)
          'password_confirmation': passwordConfirmation,
      });
      final code = result['code'] as String?;
      final returnedState = result['state'] as String?;
      if (code == null || code.isEmpty || returnedState != state) {
        throw const NiptoAuthException(
          'Nipto could not complete secure sign-in. Please try again.',
        );
      }

      final callback = Uri.parse(
        '$redirectTo?code=${Uri.encodeQueryComponent(code)}'
        '&state=${Uri.encodeQueryComponent(state)}',
      );
      await _client.auth.getSessionFromUrl(callback);
    } on AuthException catch (error) {
      throw NiptoAuthException(
        error.message,
        statusCode: error.statusCode == null
            ? null
            : int.tryParse(error.statusCode!),
      );
    } on TimeoutException {
      throw const NiptoAuthException(
        'The Nipto service took too long to respond. Please try again.',
      );
    } on http.ClientException {
      throw const NiptoAuthException(
        'Could not connect to Nipto. Check your internet connection.',
      );
    } finally {
      preflightClient.close();
    }
  }

  Future<void> _startOidc({required String screen}) async {
    try {
      final launched = await _client.auth.signInWithOAuth(
        OAuthProvider('custom:nipto'),
        redirectTo: kIsWeb ? Uri.base.origin : 'nipto://auth-callback',
        queryParams: {'screen': screen},
      );
      if (!launched)
        throw const NiptoAuthException(
          'Nipto sign-in could not be opened. Please try again.',
        );
    } on AuthException catch (error) {
      throw NiptoAuthException(
        error.message,
        statusCode: error.statusCode == null
            ? null
            : int.tryParse(error.statusCode!),
      );
    }
  }

  Future<void> linkLegacyAccount() async {
    try {
      final migration = await _post(
        'migration/prepare',
        const {},
        authenticated: true,
      );
      final ticket = migration['migration_ticket'] as String?;
      final niptoId = migration['nipto_id'] as String?;
      if (ticket == null || niptoId == null)
        throw const NiptoAuthException(
          'Could not prepare your Nipto account migration.',
        );
      await _storage.write(key: _pendingLinkNiptoIdKey, value: niptoId);
      await _client.auth.linkIdentity(
        OAuthProvider('custom:nipto'),
        redirectTo: kIsWeb ? Uri.base.origin : 'nipto://auth-callback',
        queryParams: {'screen': 'link', 'migration_ticket': ticket},
      );
    } on AuthException catch (error) {
      await _storage.delete(key: _pendingLinkNiptoIdKey);
      throw NiptoAuthException(error.message);
    }
  }

  Future<void> signOut() async {
    await NiptoPushService.instance.unregisterToken();
    try {
      await _client.auth.signOut(scope: SignOutScope.local);
    } on AuthException catch (error) {
      throw NiptoAuthException(error.message);
    }
  }

  Future<void> signOutEverywhere() async {
    await NiptoPushService.instance.unregisterToken();
    try {
      await _client.auth.signOut(scope: SignOutScope.global);
    } on AuthException catch (error) {
      throw NiptoAuthException(error.message);
    }
  }

  Future<void> startPasswordRecovery(String niptoId) async {
    final normalized = niptoId
        .trim()
        .replaceFirst(RegExp(r'^@'), '')
        .toLowerCase();
    if (normalized.isEmpty)
      throw const NiptoAuthException('Enter your Nipto ID.');
    final savedId = await _storage.read(key: _recoveryNiptoIdKey);
    final cachedGrant = await _storage.read(key: _resetGrantKey);
    if (savedId == normalized) {
      final grantTime = await _storage.read(key: _resetGrantIssuedAtKey);
      if (NiptoResetGrantCacheGuard.isUsable(
        grant: cachedGrant,
        issuedAtEpochMs: grantTime,
        nowEpochMs: DateTime.now().millisecondsSinceEpoch,
      ))
        return;
      if (cachedGrant != null) await _clearResetGrant();
      final challengeId = await _storage.read(key: _recoveryIdKey);
      final challengeSecret = await _storage.read(key: _recoverySecretKey);
      final startedAt = await _storage.read(key: _recoveryStartedAtKey);
      if (NiptoRecoveryChallengeGuard.isUsableCache(
        challengeId: challengeId,
        challengeSecret: challengeSecret,
        startedAtEpochMs: startedAt,
        nowEpochMs: DateTime.now().millisecondsSinceEpoch,
      ))
        return;
    }
    await _clearRecoveryChallenge();
    await _clearResetGrant();
    final response = await _post('recovery/start', {'nipto_id': normalized});
    final challengeId = response['challenge_id'] as String?;
    final challengeSecret = response['challenge_secret'] as String?;
    if (challengeId == null ||
        challengeId.trim().isEmpty ||
        challengeSecret == null ||
        challengeSecret.trim().isEmpty) {
      throw const NiptoAuthException('Could not start account recovery.');
    }
    await _storage.write(key: _recoveryIdKey, value: challengeId);
    await _storage.write(key: _recoverySecretKey, value: challengeSecret);
    await _storage.write(key: _recoveryNiptoIdKey, value: normalized);
    await _storage.write(
      key: _recoveryStartedAtKey,
      value: DateTime.now().millisecondsSinceEpoch.toString(),
    );
  }

  Future<String?> checkPasswordRecoveryApproval() async {
    final cachedGrant = await _storage.read(key: _resetGrantKey);
    final grantTime = await _storage.read(key: _resetGrantIssuedAtKey);
    if (NiptoResetGrantCacheGuard.isUsable(
      grant: cachedGrant,
      issuedAtEpochMs: grantTime,
      nowEpochMs: DateTime.now().millisecondsSinceEpoch,
    ))
      return cachedGrant;
    if (cachedGrant != null) await _clearResetGrant();
    final challengeId = await _storage.read(key: _recoveryIdKey);
    final challengeSecret = await _storage.read(key: _recoverySecretKey);
    final startedAt = await _storage.read(key: _recoveryStartedAtKey);
    if (!NiptoRecoveryChallengeGuard.isUsableCache(
      challengeId: challengeId,
      challengeSecret: challengeSecret,
      startedAtEpochMs: startedAt,
      nowEpochMs: DateTime.now().millisecondsSinceEpoch,
    )) {
      await _clearRecoveryChallenge();
      throw const NiptoAuthException(
        'Your recovery request expired. Start a new request.',
      );
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
      throw const NiptoAuthException(
        'This recovery request expired. Start a new request.',
      );
    }
    if (status == 'consumed') {
      await _clearRecoveryChallenge();
      throw const NiptoAuthException(
        'This recovery approval has already been used. Start a new request if you still need to reset your password.',
      );
    }
    final grant = response['reset_grant'] as String?;
    if (status == 'approved' && grant != null && grant.trim().isNotEmpty) {
      await _storage.write(key: _resetGrantKey, value: grant);
      await _storage.write(
        key: _resetGrantIssuedAtKey,
        value: DateTime.now().millisecondsSinceEpoch.toString(),
      );
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
        await _clearResetGrant();
      }
      rethrow;
    }
    await _clearRecoveryChallenge();
    await _clearResetGrant();
  }

  Future<void> _clearRecoveryChallenge() async {
    await _storage.delete(key: _recoveryIdKey);
    await _storage.delete(key: _recoverySecretKey);
    await _storage.delete(key: _recoveryStartedAtKey);
    await _storage.delete(key: _recoveryNiptoIdKey);
  }

  Future<void> _clearResetGrant() async {
    await _storage.delete(key: _resetGrantKey);
    await _storage.delete(key: _resetGrantIssuedAtKey);
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
    await _post('recovery/link', {
      'recovery_nipto_id': niptoId,
    }, authenticated: true);
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
    await _post('recovery/contact-remove', {
      'request_id': requestId,
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

  Future<List<Map<String, dynamic>>> listSessions() async {
    final response = await _get('sessions');
    return _asMapList(response['sessions']);
  }

  Future<void> revokeSession(String sessionId) async {
    await _post('sessions/revoke', {
      'session_id': sessionId,
    }, authenticated: true);
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
    final base = _baseUrl;
    final key = _publishableKey;
    if (base == null || key == null)
      throw const NiptoAuthException('Nipto is not initialized.');
    final uri = Uri.parse('$base/$path');
    final headers = <String, String>{
      'Accept': 'application/json',
      'apikey': key,
    };
    if (payload != null) headers['Content-Type'] = 'application/json';
    if (authenticated) {
      final token = _client.auth.currentSession?.accessToken;
      if (token == null)
        throw const NiptoAuthException('Sign in to continue.', statusCode: 401);
      headers['Authorization'] = 'Bearer $token';
    }
    late final http.Response response;
    try {
      response =
          await (method == 'GET'
                  ? http.get(uri, headers: headers)
                  : http.post(uri, headers: headers, body: jsonEncode(payload)))
              .timeout(const Duration(seconds: 15));
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
    if (response.body.trim().isNotEmpty) {
      try {
        final parsed = jsonDecode(response.body);
        if (parsed is Map)
          data = Map<String, dynamic>.from(parsed);
        else
          throw const FormatException('Expected JSON object.');
      } on FormatException {
        if (response.statusCode >= 200 && response.statusCode < 300) {
          throw const NiptoAuthException(
            'Nipto returned an unexpected response. Please try again.',
          );
        }
      }
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final message = data['error'] ?? data['message'];
      throw NiptoAuthException(
        message is String && message.trim().isNotEmpty
            ? message
            : 'Nipto could not complete that request.',
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
