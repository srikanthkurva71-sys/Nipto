import 'nipto_push_service.dart';

/// The screen a tapped notification should open.
///
/// Keeping this decision pure makes notification routing testable without a
/// running Firebase instance or a navigator. The app shell is responsible for
/// loading any backend metadata the destination needs before pushing a route.
enum NiptoPushDestinationKind { call, conversation, notifications }

class NiptoPushDestination {
  const NiptoPushDestination({
    required this.kind,
    this.callId,
    this.mediaType,
    this.conversationId,
  });

  final NiptoPushDestinationKind kind;
  final String? callId;
  final String? mediaType;
  final String? conversationId;

  static const NiptoPushDestination notifications = NiptoPushDestination(
    kind: NiptoPushDestinationKind.notifications,
  );
}

/// Maps ID-only push taps to an allowlisted destination.
///
/// Call pushes take priority over conversation pushes: a call notification can
/// carry a conversation ID, but the user's intent when tapping it is to answer
/// the call. Unknown or incomplete payloads always fall back to the inbox.
class NiptoPushRouteResolver {
  const NiptoPushRouteResolver();

  NiptoPushDestination resolveTap(NiptoPushEvent event) {
    if (!event.isTap) return NiptoPushDestination.notifications;

    if (event.deliveryType == 'incoming_call' && event.callId != null) {
      return NiptoPushDestination(
        kind: NiptoPushDestinationKind.call,
        callId: event.callId,
        mediaType: event.mediaType == 'video' ? 'video' : 'audio',
      );
    }

    final conversationId = event.targetConversationId;
    if (conversationId != null && event.notificationType == 'message') {
      return NiptoPushDestination(
        kind: NiptoPushDestinationKind.conversation,
        conversationId: conversationId,
      );
    }

    return NiptoPushDestination.notifications;
  }
}

/// Holds a notification tap until the restored session can open it.
///
/// A cold-start tap can be delivered before Supabase exposes the persisted
/// session. Dropping it would make the notification appear to do nothing, so
/// the app shell reuses this coordinator to replay the last pending tap after
/// sign-in. Foreground messages are never buffered as navigation intents.
class NiptoPushTapCoordinator {
  NiptoPushTapCoordinator({
    required this.isSignedIn,
    required this.onDestination,
  });

  final bool Function() isSignedIn;
  final void Function(NiptoPushDestination destination) onDestination;

  NiptoPushEvent? _pendingTap;
  bool _hasSession = false;

  void handleEvent(NiptoPushEvent event) {
    if (!event.isTap) return;
    _pendingTap = event;
    flush();
  }

  void onAuthChanged(bool signedIn) {
    _hasSession = signedIn;
    if (signedIn) flush();
  }

  void flush() {
    final event = _pendingTap;
    if (event == null || !(_hasSession || isSignedIn())) return;
    _pendingTap = null;
    onDestination(const NiptoPushRouteResolver().resolveTap(event));
  }
}
