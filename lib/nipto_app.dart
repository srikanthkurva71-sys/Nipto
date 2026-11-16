import 'package:flutter/material.dart';

import 'screens/auth_screen.dart';
import 'screens/main_shell.dart';
import 'services/nipto_session_manager.dart';
import 'theme/nipto_theme.dart';

class NiptoApp extends StatelessWidget {
  const NiptoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nipto',
      debugShowCheckedModeBanner: false,
      theme: NiptoTheme.light,
      home: const AuthGate(),
    );
  }
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
        return snapshot.data == null
            ? const AuthScreen()
            : const MainShell();
      },
    );
  }
}
