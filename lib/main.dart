import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'nipto_app.dart';

/// Client-safe development defaults for the public Nipto Supabase project.
///
/// Production builds should supply their own values with Dart defines or a
/// release-specific --dart-define-from-file. Never place service-role keys here.
const _defaultSupabaseUrl = 'https://advmjribduqzyuwktkod.supabase.co';
const _defaultSupabasePublishableKey =
    'sb_publishable_zxqki-GLfT6zi-BXT1h6zw_nWq9Nhye';

const _supabaseUrl = String.fromEnvironment(
  'SUPABASE_URL',
  defaultValue: _defaultSupabaseUrl,
);
const _supabasePublishableKey = String.fromEnvironment(
  'SUPABASE_PUBLISHABLE_KEY',
  defaultValue: _defaultSupabasePublishableKey,
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final url = Uri.tryParse(_supabaseUrl);
  final validUrl = url != null &&
      url.isAbsolute &&
      url.scheme == 'https' &&
      url.host.isNotEmpty;
  final validKey = _supabasePublishableKey.startsWith('sb_publishable_') ||
      _supabasePublishableKey.isNotEmpty;

  if (!validUrl || !validKey) {
    runApp(const _MissingConfigurationApp());
    return;
  }

  try {
    await Supabase.initialize(
      url: _supabaseUrl,
      publishableKey: _supabasePublishableKey,
      debug: false,
    );
  } catch (error, stackTrace) {
    debugPrint('Nipto Supabase initialization failed: $error');
    debugPrintStack(stackTrace: stackTrace);
    runApp(const _ConfigurationFailureApp());
    return;
  }

  runApp(const NiptoApp());
}

class _MissingConfigurationApp extends StatelessWidget {
  const _MissingConfigurationApp();

  @override
  Widget build(BuildContext context) => const _ConfigurationMessage(
        title: 'Supabase configuration is invalid.',
        message:
            'Check SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY. '
            'For production, provide them through secure build configuration.',
      );
}

class _ConfigurationFailureApp extends StatelessWidget {
  const _ConfigurationFailureApp();

  @override
  Widget build(BuildContext context) => const _ConfigurationMessage(
        title: 'Could not connect to Nipto services.',
        message:
            'Check your network connection and Supabase project availability, '
            'then restart the app.',
      );
}

class _ConfigurationMessage extends StatelessWidget {
  const _ConfigurationMessage({
    required this.title,
    required this.message,
  });

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: const Color(0xFFF7F7FB),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'NIPTO',
                  style: TextStyle(
                    color: Color(0xFF6657E8),
                    fontSize: 30,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 3,
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Color(0xFF777A8C)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
