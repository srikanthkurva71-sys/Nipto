import 'package:flutter_test/flutter_test.dart';
import 'package:nipto/services/nipto_push_route.dart';
import 'package:nipto/services/nipto_push_service.dart';

NiptoPushEvent tap({
  String deliveryType = 'notification',
  String? notificationType,
  String? callId,
  String? conversationId,
  String? entityId,
  String? mediaType,
}) {
  return NiptoPushEvent(
    origin: NiptoPushEventOrigin.notificationTap,
    deliveryType: deliveryType,
    notificationType: notificationType,
    callId: callId,
    conversationId: conversationId,
    entityId: entityId,
    mediaType: mediaType,
  );
}

void main() {
  const resolver = NiptoPushRouteResolver();

  group('NiptoPushRouteResolver', () {
    test('foreground messages never navigate', () {
      final result = resolver.resolveTap(
        const NiptoPushEvent(
          origin: NiptoPushEventOrigin.foregroundMessage,
          deliveryType: 'notification',
          notificationType: 'message',
          entityId: 'conversation-1',
        ),
      );
      expect(result.kind, NiptoPushDestinationKind.notifications);
    });

    test('message tap with conversation id opens the conversation', () {
      final result = resolver.resolveTap(
        tap(notificationType: 'message', conversationId: 'conversation-1'),
      );
      expect(result.kind, NiptoPushDestinationKind.conversation);
      expect(result.conversationId, 'conversation-1');
    });

    test('message tap with entity-only id also opens the conversation', () {
      final result = resolver.resolveTap(
        tap(notificationType: 'message', entityId: 'conversation-2'),
      );
      expect(result.kind, NiptoPushDestinationKind.conversation);
      expect(result.conversationId, 'conversation-2');
    });

    test('incoming call tap opens the call screen', () {
      final result = resolver.resolveTap(
        tap(
          deliveryType: 'incoming_call',
          callId: 'call-1',
          mediaType: 'video',
          conversationId: 'conversation-3',
        ),
      );
      expect(result.kind, NiptoPushDestinationKind.call);
      expect(result.callId, 'call-1');
      expect(result.mediaType, 'video');
    });

    test('incoming call without a call id falls back to the inbox', () {
      final result = resolver.resolveTap(
        tap(deliveryType: 'incoming_call', conversationId: 'conversation-4'),
      );
      expect(result.kind, NiptoPushDestinationKind.notifications);
      expect(result.callId, isNull);
    });

    test(
      'non-message notification with a conversation id stays in the inbox',
      () {
        final result = resolver.resolveTap(
          tap(notificationType: 'like', conversationId: 'conversation-5'),
        );
        expect(result.kind, NiptoPushDestinationKind.notifications);
      },
    );

    test('unknown notification types fall back to the inbox', () {
      final result = resolver.resolveTap(tap());
      expect(result.kind, NiptoPushDestinationKind.notifications);
    });
  });

  group('NiptoPushTapCoordinator', () {
    test('a tap received before sign-in is routed once after sign-in', () {
      var signedIn = false;
      final routed = <NiptoPushDestination>[];
      final coordinator = NiptoPushTapCoordinator(
        isSignedIn: () => signedIn,
        onDestination: routed.add,
      );

      coordinator.handleEvent(
        tap(notificationType: 'message', conversationId: 'conversation-1'),
      );
      expect(routed, isEmpty);

      coordinator.onAuthChanged(true);
      expect(routed, hasLength(1));
      expect(routed.single.kind, NiptoPushDestinationKind.conversation);
      expect(routed.single.conversationId, 'conversation-1');

      coordinator.onAuthChanged(true);
      expect(routed, hasLength(1));
    });

    test('a signed-in tap routes immediately', () {
      final routed = <NiptoPushDestination>[];
      final coordinator = NiptoPushTapCoordinator(
        isSignedIn: () => true,
        onDestination: routed.add,
      );

      coordinator.handleEvent(
        tap(
          deliveryType: 'incoming_call',
          callId: 'call-1',
          mediaType: 'audio',
        ),
      );

      expect(routed, hasLength(1));
      expect(routed.single.kind, NiptoPushDestinationKind.call);
      expect(routed.single.callId, 'call-1');
    });

    test('foreground messages never become pending routes', () {
      final routed = <NiptoPushDestination>[];
      final coordinator = NiptoPushTapCoordinator(
        isSignedIn: () => true,
        onDestination: routed.add,
      );

      coordinator.handleEvent(
        const NiptoPushEvent(
          origin: NiptoPushEventOrigin.foregroundMessage,
          deliveryType: 'notification',
          notificationType: 'message',
          entityId: 'conversation-1',
        ),
      );
      coordinator.onAuthChanged(true);

      expect(routed, isEmpty);
    });
  });
}
