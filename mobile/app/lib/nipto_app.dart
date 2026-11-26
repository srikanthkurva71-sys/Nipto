import 'dart:async';

import 'package:flutter/material.dart';

import 'screens/account_migration_screen.dart';
import 'screens/auth_screen.dart';
import 'screens/conversation_screen.dart';
import 'screens/main_shell.dart';
import 'screens/notifications_screen.dart';
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
  StreamSubscription<NiptoPushEvent>? _subscription;

  @override
  void initState() {
    super.initState();
    _subscription = NiptoPushService.instance.events.listen(_handleEvent);
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  void _handleEvent(NiptoPushEvent event) {
    if (!event.isTap) return;
    final navigator = NiptoApp.navigatorKey.currentState;
    // A tapped notification must not open protected screens in a signed-out
    // session; the private inbox loads only after AuthGate issues a session.
    if (navigator == null || !NiptoSessionManager.instance.isSignedIn) return;

    final conversationId = event.targetConversationId;
    if (event.notificationType == 'message' && conversationId != null) {
      navigator.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => ConversationScreen(
            conversationId: conversationId,
            title: 'Nipto member',
            subtitle: 'Nipto member',
          ),
        ),
      );
      return;
    }
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
