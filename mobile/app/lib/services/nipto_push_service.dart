import 'dart:async';
import 'dart:convert';

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Channel id shared with the generated Android manifest metadata.
const String niptoPushChannelId = 'nipto_default';

/// Client-safe Firebase project values. Nothing here is a credential secret;
/// Firebase mobile config is public by design, but it is still supplied at
/// build time so an unconfigured checkout never starts Firebase or FCM.
class NiptoFirebaseConfig {
  const NiptoFirebaseConfig({
    required this.apiKey,
    required this.projectId,
    required this.appId,
    required this.messagingSenderId,
    this.storageBucket = '',
    this.iosBundleId = '',
    this.androidPackageName = '',
  });

  factory NiptoFirebaseConfig.fromEnvironment() {
    return NiptoFirebaseConfig(
      apiKey: const String.fromEnvironment(apiKeyDefine),
      projectId: const String.fromEnvironment(projectIdDefine),
      appId: const String.fromEnvironment(appIdDefine),
      messagingSenderId: const String.fromEnvironment(messagingSenderIdDefine),
      storageBucket: const String.fromEnvironment(storageBucketDefine),
      iosBundleId: const String.fromEnvironment(iosBundleIdDefine),
      androidPackageName: const String.fromEnvironment(
        androidPackageNameDefine,
      ),
    );
  }

  static const String apiKeyDefine = 'NIPTO_FIREBASE_API_KEY';
  static const String projectIdDefine = 'NIPTO_FIREBASE_PROJECT_ID';
  static const String appIdDefine = 'NIPTO_FIREBASE_APP_ID';
  static const String messagingSenderIdDefine =
      'NIPTO_FIREBASE_MESSAGING_SENDER_ID';
  static const String storageBucketDefine = 'NIPTO_FIREBASE_STORAGE_BUCKET';
  static const String iosBundleIdDefine = 'NIPTO_FIREBASE_IOS_BUNDLE_ID';
  static const String androidPackageNameDefine =
      'NIPTO_FIREBASE_ANDROID_PACKAGE_NAME';

  final String apiKey;
  final String projectId;
  final String appId;
  final String messagingSenderId;
  final String storageBucket;
  final String iosBundleId;
  final String androidPackageName;

  bool get isComplete =>
      apiKey.trim().isNotEmpty &&
      projectId.trim().isNotEmpty &&
      appId.trim().isNotEmpty &&
      messagingSenderId.trim().isNotEmpty;

  FirebaseOptions? buildOptions() {
    if (!isComplete) return null;
    String? optional(String value) {
      final trimmed = value.trim();
      return trimmed.isEmpty ? null : trimmed;
    }

    return FirebaseOptions(
      apiKey: apiKey.trim(),
      projectId: projectId.trim(),
      appId: appId.trim(),
      messagingSenderId: messagingSenderId.trim(),
      storageBucket: optional(storageBucket),
      iosBundleId: optional(iosBundleId),
    );
  }
}

typedef NiptoFirebaseInitializer =
    Future<bool> Function(FirebaseOptions options);
typedef NiptoSignedInProvider = bool Function();
typedef NiptoAuthChangesProvider = Stream<bool> Function();

/// Small seam around FirebaseMessaging so unit tests never touch a plugin.
abstract class NiptoMessagingPort {
  Future<bool> requestPermission();
  Future<String?> getToken();
  Stream<String> get tokenRefresh;
  Stream<Map<String, dynamic>> get messages;
  Stream<Map<String, dynamic>> get taps;
  Future<Map<String, dynamic>?> getInitialMessage();
}

class _FirebaseMessagingPort implements NiptoMessagingPort {
  const _FirebaseMessagingPort();

  @override
  Future<bool> requestPermission() async {
    if (kIsWeb ||
        (defaultTargetPlatform != TargetPlatform.android &&
            defaultTargetPlatform != TargetPlatform.iOS)) {
      return false;
    }
    final settings = await FirebaseMessaging.instance.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    return settings.authorizationStatus == AuthorizationStatus.authorized ||
        settings.authorizationStatus == AuthorizationStatus.provisional;
  }

  @override
  Future<String?> getToken() => FirebaseMessaging.instance.getToken();

  @override
  Stream<String> get tokenRefresh => FirebaseMessaging.instance.onTokenRefresh;

  @override
  Stream<Map<String, dynamic>> get messages =>
      FirebaseMessaging.onMessage.map(_dataOf);

  @override
  Stream<Map<String, dynamic>> get taps =>
      FirebaseMessaging.onMessageOpenedApp.map(_dataOf);

  @override
  Future<Map<String, dynamic>?> getInitialMessage() async {
    final message = await FirebaseMessaging.instance.getInitialMessage();
    return message == null ? null : _dataOf(message);
  }

  static Map<String, dynamic> _dataOf(RemoteMessage message) =>
      Map<String, dynamic>.from(message.data);
}

/// RPC shape used by `public.register_device_push_token` and
/// `public.unregister_device_push_token`. The token itself never goes to logs.
class NiptoPushRpc {
  static const String registerFunction = 'register_device_push_token';
  static const String unregisterFunction = 'unregister_device_push_token';
  static const String tokenParam = 'p_token';
  static const String platformParam = 'p_platform';

  static Map<String, dynamic> registerParams({
    required String token,
    required String platform,
  }) {
    return <String, dynamic>{tokenParam: token, platformParam: platform};
  }

  static Map<String, dynamic> unregisterParams({required String token}) {
    return <String, dynamic>{tokenParam: token};
  }
}

abstract class NiptoPushRpcClient {
  Future<void> call(String function, Map<String, dynamic> params);
}

class NiptoPushSupabaseRpcClient implements NiptoPushRpcClient {
  const NiptoPushSupabaseRpcClient();

  @override
  Future<void> call(String function, Map<String, dynamic> params) async {
    await Supabase.instance.client.rpc(function, params: params);
  }
}

enum NiptoPushEventOrigin { foregroundMessage, notificationTap }

/// Only identifiers and allowlisted routing types leave FCM data. Names,
/// message text and any other payload fields are deliberately discarded.
class NiptoPushEvent {
  const NiptoPushEvent({
    required this.origin,
    required this.deliveryType,
    this.notificationId,
    this.entityId,
    this.callId,
    this.conversationId,
    this.notificationType,
    this.mediaType,
  });

  final NiptoPushEventOrigin origin;
  final String deliveryType;
  final String? notificationId;
  final String? entityId;
  final String? callId;
  final String? conversationId;
  final String? notificationType;
  final String? mediaType;

  bool get isTap => origin == NiptoPushEventOrigin.notificationTap;

  bool get hasContent =>
      notificationId != null ||
      entityId != null ||
      callId != null ||
      conversationId != null ||
      notificationType != null ||
      mediaType != null;

  /// Message notifications carry the conversation as `entity_id` in the push
  /// outbox; direct conversation fields from other senders are also accepted.
  String? get targetConversationId {
    if (notificationType == 'message') return conversationId ?? entityId;
    return conversationId;
  }

  String get foregroundTitle => deliveryType == 'incoming_call'
      ? 'Incoming Nipto call'
      : 'New Nipto activity';

  String get foregroundBody {
    if (deliveryType == 'incoming_call') {
      return mediaType == 'video' ? 'Video call' : 'Audio call';
    }
    if (notificationType == 'message') return 'You have a new message.';
    return 'Open Nipto to review your activity.';
  }

  Map<String, dynamic> get payload => <String, dynamic>{
    'delivery_type': deliveryType,
    if (notificationId != null) 'notification_id': notificationId!,
    if (entityId != null) 'entity_id': entityId!,
    if (callId != null) 'call_id': callId!,
    if (conversationId != null) 'conversation_id': conversationId!,
    if (notificationType != null) 'notification_type': notificationType!,
    if (mediaType != null) 'media_type': mediaType!,
  };

  static NiptoPushEvent fromData(
    Map<String, dynamic>? data, {
    required NiptoPushEventOrigin origin,
  }) {
    final source = data ?? const <String, dynamic>{};
    String? allowed(String key) {
      final raw = source[key];
      if (raw == null) return null;
      final value = raw.toString().trim();
      if (value.isEmpty || value.length > 128) return null;
      return value;
    }

    final notificationId = allowed('notification_id');
    final callId = allowed('call_id');
    return NiptoPushEvent(
      origin: origin,
      deliveryType:
          allowed('delivery_type') ??
          (callId != null ? 'incoming_call' : 'notification'),
      notificationId: notificationId,
      entityId: allowed('entity_id'),
      callId: callId,
      conversationId: allowed('conversation_id'),
      notificationType: allowed('notification_type'),
      mediaType: allowed('media_type'),
    );
  }
}

abstract class NiptoForegroundNotifier {
  Future<void> initialize();
  Future<Map<String, dynamic>?> getInitialTap();
  Stream<Map<String, dynamic>> get taps;
  Future<void> show(NiptoPushEvent event);
}

class _LocalForegroundNotifier implements NiptoForegroundNotifier {
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  final StreamController<Map<String, dynamic>> _taps =
      StreamController<Map<String, dynamic>>.broadcast();
  bool _initialized = false;

  @override
  Stream<Map<String, dynamic>> get taps => _taps.stream;

  @override
  Future<void> initialize() async {
    if (_initialized) return;
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const darwin = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: android,
        iOS: darwin,
        macOS: darwin,
      ),
      onDidReceiveNotificationResponse: _handleResponse,
    );
    _initialized = true;
  }

  @override
  Future<Map<String, dynamic>?> getInitialTap() async {
    final details = await _plugin.getNotificationAppLaunchDetails();
    return _decodePayload(details?.notificationResponse?.payload);
  }

  @override
  Future<void> show(NiptoPushEvent event) async {
    if (!_initialized) return;
    final identifier =
        event.notificationId ??
        event.callId ??
        event.conversationId ??
        event.entityId;
    final id =
        ((identifier?.hashCode ?? DateTime.now().millisecondsSinceEpoch) &
        0x7fffffff);
    const androidDetails = AndroidNotificationDetails(
      niptoPushChannelId,
      'Nipto',
      channelDescription: 'Nipto messages and activity',
      importance: Importance.high,
      priority: Priority.high,
    );
    const details = NotificationDetails(
      android: androidDetails,
      iOS: DarwinNotificationDetails(),
    );
    await _plugin.show(
      id: id,
      title: event.foregroundTitle,
      body: event.foregroundBody,
      notificationDetails: details,
      payload: jsonEncode(event.payload),
    );
  }

  void _handleResponse(NotificationResponse response) {
    final decoded = _decodePayload(response.payload);
    if (decoded != null) _taps.add(decoded);
  }

  Map<String, dynamic>? _decodePayload(String? payload) {
    if (payload == null || payload.isEmpty) return null;
    try {
      final decoded = jsonDecode(payload);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }
}

/// Owns FCM registration and exposes ID-only push events to the app shell.
/// Missing configuration is a no-op: Firebase is never initialized and push
/// is never reported as enabled.
class NiptoPushService {
  NiptoPushService({
    NiptoFirebaseConfig? config,
    NiptoFirebaseInitializer? firebaseInitializer,
    NiptoMessagingPort? messaging,
    NiptoPushRpcClient? rpc,
    NiptoForegroundNotifier? notifier,
    String? platformOverride,
    NiptoSignedInProvider? signedInProvider,
    NiptoAuthChangesProvider? authChangesProvider,
  }) : _config = config ?? NiptoFirebaseConfig.fromEnvironment(),
       _firebaseInitializer = firebaseInitializer ?? _initializeDefaultFirebase,
       _messaging = messaging ?? const _FirebaseMessagingPort(),
       _rpc = rpc ?? const NiptoPushSupabaseRpcClient(),
       _notifier = notifier ?? _LocalForegroundNotifier(),
       _platformOverride = platformOverride,
       _signedInProvider = signedInProvider ?? _defaultSignedIn,
       _authChangesProvider = authChangesProvider ?? _defaultAuthChanges;

  static final NiptoPushService instance = NiptoPushService();

  late final StreamController<NiptoPushEvent> _events =
      StreamController<NiptoPushEvent>.broadcast(onListen: _flushPendingTap);

  final NiptoFirebaseConfig _config;
  final NiptoFirebaseInitializer _firebaseInitializer;
  final NiptoMessagingPort _messaging;
  final NiptoPushRpcClient _rpc;
  final NiptoForegroundNotifier _notifier;
  final String? _platformOverride;
  final NiptoSignedInProvider _signedInProvider;
  final NiptoAuthChangesProvider _authChangesProvider;

  bool _initialized = false;
  bool _enabled = false;
  bool _isSignedIn = false;
  String? _platform;
  String? _currentToken;
  String? _registeredToken;
  NiptoPushEvent? _pendingTap;
  StreamSubscription<Map<String, dynamic>>? _messageSubscription;
  StreamSubscription<Map<String, dynamic>>? _tapSubscription;
  StreamSubscription<Map<String, dynamic>>? _localTapSubscription;
  StreamSubscription<String>? _refreshSubscription;
  StreamSubscription<bool>? _authSubscription;

  Stream<NiptoPushEvent> get events => _events.stream;
  bool get isEnabled => _initialized && _enabled;
  bool get hasRegisteredToken => _registeredToken != null;

  Future<bool> initialize() async {
    if (_initialized) return _enabled;
    _initialized = true;

    final options = _config.buildOptions();
    final platform = _resolvePlatform();
    if (options == null || platform == null) return false;

    try {
      if (!await _firebaseInitializer(options)) return false;
      if (!await _messaging.requestPermission()) return false;
      await _notifier.initialize();

      final initialPush = await _messaging.getInitialMessage();
      if (initialPush != null) _rememberTap(initialPush);
      final initialLocal = await _notifier.getInitialTap();
      if (initialLocal != null) _rememberTap(initialLocal);

      final token = await _messaging.getToken();
      if (token == null || token.trim().isEmpty) return false;
      _platform = platform;
      _currentToken = token;
      _isSignedIn = _signedInProvider();

      _messageSubscription = _messaging.messages.listen(_onForegroundMessage);
      _tapSubscription = _messaging.taps.listen(_rememberTap);
      _localTapSubscription = _notifier.taps.listen(_rememberTap);
      _refreshSubscription = _messaging.tokenRefresh.listen((token) {
        unawaited(_onTokenRefreshed(token));
      });

      _enabled = true;
      if (_isSignedIn) await _registerToken(token);
      _authSubscription = _authChangesProvider().listen(_onAuthChanged);
      return true;
    } catch (_) {
      await dispose();
      return false;
    }
  }

  /// Removes this device token from the signed-in account. Must be awaited
  /// before Supabase sign-out clears the session used by the RPC.
  Future<void> unregisterToken() async {
    final token = _registeredToken;
    _registeredToken = null;
    if (!_enabled || token == null) return;
    try {
      await _rpc.call(
        NiptoPushRpc.unregisterFunction,
        NiptoPushRpc.unregisterParams(token: token),
      );
    } catch (_) {
      // Sign-out must not be blocked by a transient push unregistration error.
    }
  }

  Future<void> dispose() async {
    await _messageSubscription?.cancel();
    await _tapSubscription?.cancel();
    await _localTapSubscription?.cancel();
    await _refreshSubscription?.cancel();
    await _authSubscription?.cancel();
    _messageSubscription = null;
    _tapSubscription = null;
    _localTapSubscription = null;
    _refreshSubscription = null;
    _authSubscription = null;
    _enabled = false;
    if (!_events.isClosed) await _events.close();
  }

  void _onAuthChanged(bool signedIn) {
    if (!_enabled) return;
    _isSignedIn = signedIn;
    if (!signedIn) {
      // NiptoSessionManager awaits the RPC unregistration before clearing the
      // session; here the device token is only forgotten for the old account.
      _registeredToken = null;
      return;
    }
    final token = _currentToken;
    if (token != null && _registeredToken == null) {
      unawaited(_registerToken(token));
    }
  }

  Future<void> _registerToken(String token) async {
    try {
      await _rpc.call(
        NiptoPushRpc.registerFunction,
        NiptoPushRpc.registerParams(
          token: token,
          platform: _platform ?? 'android',
        ),
      );
      _registeredToken = token;
    } catch (_) {
      // Retried on the next sign-in, token refresh, or app start.
    }
  }

  String? _resolvePlatform() {
    final override = _platformOverride;
    if (override != null)
      return override.trim().isEmpty ? null : override.trim();
    if (kIsWeb) return null;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'android';
      case TargetPlatform.iOS:
        return 'ios';
      default:
        return null;
    }
  }

  Future<void> _onTokenRefreshed(String token) async {
    if (token.trim().isEmpty) return;
    final previous = _registeredToken;
    _currentToken = token;
    if (previous != null && previous != token && _isSignedIn) {
      try {
        await _rpc.call(
          NiptoPushRpc.unregisterFunction,
          NiptoPushRpc.unregisterParams(token: previous),
        );
      } catch (_) {
        // The refresh registration below remains authoritative.
      }
    }
    _registeredToken = null;
    if (_isSignedIn) await _registerToken(token);
  }

  void _onForegroundMessage(Map<String, dynamic> data) {
    final event = NiptoPushEvent.fromData(
      data,
      origin: NiptoPushEventOrigin.foregroundMessage,
    );
    _emit(event);
    if (event.hasContent) {
      unawaited(_notifier.show(event).catchError((Object _) {}));
    }
  }

  void _rememberTap(Map<String, dynamic> data) {
    _emit(
      NiptoPushEvent.fromData(
        data,
        origin: NiptoPushEventOrigin.notificationTap,
      ),
    );
  }

  void _emit(NiptoPushEvent event) {
    if (!event.hasContent) return;
    if (_events.hasListener) {
      _events.add(event);
    } else if (event.isTap) {
      // Terminated/cold-start taps arrive before the widget tree subscribes.
      _pendingTap = event;
    }
  }

  void _flushPendingTap() {
    final pending = _pendingTap;
    _pendingTap = null;
    if (pending == null) return;
    unawaited(
      Future<void>.value().then((_) {
        if (!_events.isClosed) _events.add(pending);
      }),
    );
  }
}

bool _defaultSignedIn() {
  try {
    return Supabase.instance.client.auth.currentSession != null;
  } catch (_) {
    return false;
  }
}

Stream<bool> _defaultAuthChanges() {
  try {
    return Supabase.instance.client.auth.onAuthStateChange.map(
      (event) => event.session != null,
    );
  } catch (_) {
    return const Stream<bool>.empty();
  }
}

Future<bool> _initializeDefaultFirebase(FirebaseOptions options) async {
  if (Firebase.apps.isEmpty) {
    await Firebase.initializeApp(options: options);
    return true;
  }
  final existing = Firebase.app().options;
  return existing.apiKey == options.apiKey &&
      existing.appId == options.appId &&
      existing.messagingSenderId == options.messagingSenderId &&
      existing.projectId == options.projectId;
}
