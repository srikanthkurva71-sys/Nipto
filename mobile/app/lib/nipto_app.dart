import 'dart:async';

import 'package:flutter/material.dart';

import 'screens/account_migration_screen.dart';
import 'screens/auth_screen.dart';
import 'screens/call_screen.dart';
import 'screens/conversation_screen.dart';
import 'screens/main_shell.dart';
import 'screens/notifications_screen.dart';
import 'services/nipto_conversation_header.dart';
import 'services/nipto_push_route.dart';
import 'services/nipto_push_service.dart';
import 'services/nipto_session_manager.dart';
import 'theme/nipto_theme.dart';

class NiptoApp extends StatelessWidget {
  const NiptoApp({super.key});

  /// Root navigator key so an OS notification tap can open a screen even when
  /// the app was terminated and AuthGate has just rebuilt the widget tree.
  static final GlobalKey<NavigatorState> navigatorKey =
      GlobalKey<NavigatorState>();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'Nipto',
      debugShowCheckedModeBanner: false,
      theme: NiptoTheme.light,
      home: const _PushTapRouter(child: AuthGate()),
    );
  }
}

class _PushTapRouter extends StatefulWidget {
  const _PushTapRouter({required this.child});

  final Widget child;

  @override
  State<_PushTapRouter> createState() => _PushTapRouterState();
}

class _PushTapRouterState extends State<_PushTapRouter> {
  StreamSubscription<NiptoPushEvent>? _pushSubscription;
  StreamSubscription<bool>? _sessionSubscription;
  late final NiptoPushTapCoordinator _tapCoordinator;

  @override
  void initState() {
    super.initState();
    _tapCoordinator = NiptoPushTapCoordinator(
      isSignedIn: () => NiptoSessionManager.instance.isSignedIn,
      onDestination: _openDestination,
    );
    _sessionSubscription = NiptoSessionManager.instance.changes
        .map((session) => session != null)
        .listen(_tapCoordinator.onAuthChanged);
    _pushSubscription = NiptoPushService.instance.events.listen(
      _tapCoordinator.handleEvent,
    );
  }

  @override
  void dispose() {
    _pushSubscription?.cancel();
    _sessionSubscription?.cancel();
    super.dispose();
  }

  void _openDestination(NiptoPushDestination destination) {
    final navigator = NiptoApp.navigatorKey.currentState;
    // A tapped notification must not open protected screens in a signed-out
    // session; the private inbox loads only after AuthGate issues a session.
    if (navigator == null || !NiptoSessionManager.instance.isSignedIn) return;

    switch (destination.kind) {
      case NiptoPushDestinationKind.call:
        final callId = destination.callId;
        if (callId == null) {
          _openNotifications();
          return;
        }
        navigator.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => CallScreen(
              callId: callId,
              mediaType: destination.mediaType ?? 'audio',
              isCaller: false,
              peerTitle: 'Nipto member',
            ),
          ),
        );
        return;
      case NiptoPushDestinationKind.conversation:
        final conversationId = destination.conversationId;
        if (conversationId == null) {
          _openNotifications();
          return;
        }
        unawaited(_openConversation(conversationId));
        return;
      case NiptoPushDestinationKind.notifications:
        _openNotifications();
        return;
    }
  }

  Future<void> _openConversation(String conversationId) async {
    final header = await const NiptoConversationHeaderResolver().resolve(
      conversationId,
    );
    // Re-read the navigator after the await: the widget tree may have been
    // rebuilt (for example after a session refresh) while metadata loaded.
    final navigator = NiptoApp.navigatorKey.currentState;
    if (!mounted ||
        navigator == null ||
        !NiptoSessionManager.instance.isSignedIn) {
      return;
    }
    navigator.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ConversationScreen(
          conversationId: conversationId,
          title: header.title,
          subtitle: header.subtitle,
          enableCalls: !header.isGroup,
        ),
      ),
    );
  }

  void _openNotifications() {
    final navigator = NiptoApp.navigatorKey.currentState;
    if (navigator == null) return;
    navigator.push<void>(
      MaterialPageRoute<void>(builder: (_) => const NotificationsScreen()),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    final sessions = NiptoSessionManager.instance;
    return StreamBuilder<NiptoSession?>(
      stream: sessions.changes,
      initialData: sessions.currentSession,
      builder: (context, snapshot) {
        final session = snapshot.data;
        if (session == null) return const AuthScreen();
        if (sessions.hasLegacySession) {
          return const AccountMigrationScreen();
        }
        // Recreate account-scoped subscriptions and screen state when the
        // authenticated identity changes on this device.
        return MainShell(key: ValueKey<String>(session.userId));
      },
    );
  }
}
