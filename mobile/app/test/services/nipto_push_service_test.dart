import 'dart:async';

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nipto/services/nipto_push_service.dart';

const _completeConfig = NiptoFirebaseConfig(
  apiKey: 'client-api-key',
  projectId: 'nipto-test',
  appId: '1:1234567890:android:abcdef',
  messagingSenderId: '1234567890',
);

class FakeMessaging implements NiptoMessagingPort {
  FakeMessaging({
    this.token = 'fcm-token-abcdefghijklmnop',
    this.permissionGranted = true,
  });

  final StreamController<String> _tokens = StreamController<String>.broadcast();
  final StreamController<Map<String, dynamic>> _messages =
      StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<Map<String, dynamic>> _taps =
      StreamController<Map<String, dynamic>>.broadcast();

  String? token;
  bool permissionGranted;
  Map<String, dynamic>? initialMessage;
  int permissionRequests = 0;

  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    return permissionGranted;
  }

  @override
  Future<String?> getToken() async => token;

  @override
  Stream<String> get tokenRefresh => _tokens.stream;

  @override
  Stream<Map<String, dynamic>> get messages => _messages.stream;

  @override
  Stream<Map<String, dynamic>> get taps => _taps.stream;

  @override
  Future<Map<String, dynamic>?> getInitialMessage() async => initialMessage;

  void emitTap(Map<String, dynamic> data) => _taps.add(data);

  void emitMessage(Map<String, dynamic> data) => _messages.add(data);

  void emitToken(String value) => _tokens.add(value);

  Future<void> dispose() async {
    await _tokens.close();
    await _messages.close();
    await _taps.close();
  }
}

class FakeNotifier implements NiptoForegroundNotifier {
  final StreamController<Map<String, dynamic>> _taps =
      StreamController<Map<String, dynamic>>.broadcast();

  Map<String, dynamic>? initialTap;
  final List<NiptoPushEvent> shown = <NiptoPushEvent>[];

  @override
  Future<void> initialize() async {}

  @override
  Future<Map<String, dynamic>?> getInitialTap() async => initialTap;

  @override
  Stream<Map<String, dynamic>> get taps => _taps.stream;

  @override
  Future<void> show(NiptoPushEvent event) async => shown.add(event);

  Future<void> dispose() async => _taps.close();
}

class RecordingRpc implements NiptoPushRpcClient {
  final List<Map<String, dynamic>> calls = <Map<String, dynamic>>[];

  @override
  Future<void> call(String function, Map<String, dynamic> params) async {
    calls.add(<String, dynamic>{'function': function, 'params': params});
  }
}

NiptoPushService buildService({
  NiptoFirebaseConfig config = _completeConfig,
  FakeMessaging? messaging,
  RecordingRpc? rpc,
  FakeNotifier? notifier,
  bool signedIn = true,
  bool permissionGranted = true,
  String? token = 'fcm-token-abcdefghijklmnop',
  Future<bool> Function(FirebaseOptions options)? firebaseInitializer,
}) {
  return NiptoPushService(
    config: config,
    firebaseInitializer: firebaseInitializer ?? ((_) async => true),
    messaging:
        messaging ??
        FakeMessaging(token: token, permissionGranted: permissionGranted),
    rpc: rpc ?? RecordingRpc(),
    notifier: notifier ?? FakeNotifier(),
    platformOverride: 'android',
    signedInProvider: () => signedIn,
    authChangesProvider: () => const Stream<bool>.empty(),
  );
}

void main() {
  group('NiptoPushService configuration', () {
    test(
      'incomplete Firebase config never initializes Firebase or registers a token',
      () async {
        final incomplete = NiptoFirebaseConfig(
          apiKey: '',
          projectId: 'nipto-test',
          appId: '1:1234567890:android:abcdef',
          messagingSenderId: '1234567890',
        );
        final messaging = FakeMessaging();
        final rpc = RecordingRpc();
        final service = buildService(
          config: incomplete,
          messaging: messaging,
          rpc: rpc,
          firebaseInitializer: (_) async =>
              throw StateError('Firebase must not initialize'),
        );
        addTearDown(service.dispose);
        addTearDown(messaging.dispose);

        expect(await service.initialize(), isFalse);
        expect(service.isEnabled, isFalse);
        expect(messaging.permissionRequests, 0);
        expect(rpc.calls, isEmpty);
      },
    );

    test('denied notification permission skips token registration', () async {
      final messaging = FakeMessaging(permissionGranted: false);
      final rpc = RecordingRpc();
      final service = buildService(
        messaging: messaging,
        rpc: rpc,
        permissionGranted: false,
      );
      addTearDown(service.dispose);
      addTearDown(messaging.dispose);

      expect(await service.initialize(), isFalse);
      expect(messaging.permissionRequests, 1);
      expect(rpc.calls, isEmpty);
    });
  });

  group('NiptoPushService registration', () {
    test(
      'registers the FCM token with the exact client RPC parameter names',
      () async {
        final rpc = RecordingRpc();
        final service = buildService(rpc: rpc);
        addTearDown(service.dispose);

        expect(await service.initialize(), isTrue);
        expect(service.isEnabled, isTrue);
        expect(service.hasRegisteredToken, isTrue);
        expect(rpc.calls, hasLength(1));
        expect(rpc.calls.single['function'], NiptoPushRpc.registerFunction);
        expect(
          rpc.calls.single['params'],
          equals(<String, dynamic>{
            'p_token': 'fcm-token-abcdefghijklmnop',
            'p_platform': 'android',
          }),
        );
      },
    );

    test('unregister sends only the token before sign-out', () async {
      final rpc = RecordingRpc();
      final service = buildService(rpc: rpc);
      addTearDown(service.dispose);

      await service.initialize();
      await service.unregisterToken();

      expect(rpc.calls.last['function'], NiptoPushRpc.unregisterFunction);
      expect(
        rpc.calls.last['params'],
        equals(<String, dynamic>{'p_token': 'fcm-token-abcdefghijklmnop'}),
      );
      expect(service.hasRegisteredToken, isFalse);
    });
  });

  group('NiptoPushEvent payload parsing', () {
    test(
      'tap payload keeps identifiers and discards names and message text',
      () async {
        final messaging = FakeMessaging();
        final service = buildService(messaging: messaging);
        addTearDown(service.dispose);
        addTearDown(messaging.dispose);
        await service.initialize();

        final nextEvent = service.events.first;
        messaging.emitTap(<String, dynamic>{
          'click_action': 'FLUTTER_NOTIFICATION_CLICK',
          'delivery_type': 'notification',
          'notification_id': '33333333-3333-4333-8333-333333333333',
          'notification_type': 'message',
          'entity_id': '44444444-4444-4444-8444-444444444444',
          'actor_name': 'Secret Actor',
          'body': 'secret message body',
        });
        final event = await nextEvent;

        expect(event.isTap, isTrue);
        expect(event.notificationId, '33333333-3333-4333-8333-333333333333');
        expect(event.notificationType, 'message');
        expect(
          event.targetConversationId,
          '44444444-4444-4444-8444-444444444444',
        );
        expect(event.payload, isNot(contains('actor_name')));
        expect(event.payload, isNot(contains('body')));
        expect(event.payload, isNot(contains('click_action')));
      },
    );

    test(
      'foreground messages are exposed with message origin and shown locally',
      () async {
        final messaging = FakeMessaging();
        final notifier = FakeNotifier();
        final service = buildService(messaging: messaging, notifier: notifier);
        addTearDown(service.dispose);
        addTearDown(messaging.dispose);
        addTearDown(notifier.dispose);
        await service.initialize();

        final nextEvent = service.events.first;
        messaging.emitMessage(<String, dynamic>{
          'delivery_type': 'incoming_call',
          'call_id': '55555555-5555-4555-8555-555555555555',
          'conversation_id': '66666666-6666-4666-8666-666666666666',
          'media_type': 'video',
          'caller_name': 'Secret Caller',
          'sdp': 'secret-offer',
        });
        final event = await nextEvent;

        expect(event.origin, NiptoPushEventOrigin.foregroundMessage);
        expect(event.callId, '55555555-5555-4555-8555-555555555555');
        expect(event.mediaType, 'video');
        expect(event.payload, isNot(contains('caller_name')));
        expect(event.payload, isNot(contains('sdp')));
        expect(notifier.shown, hasLength(1));
        expect(notifier.shown.single.foregroundBody, 'Video call');
      },
    );
  });
}
