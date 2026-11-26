import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'nipto_app.dart';
import 'services/nipto_push_service.dart';
import 'services/nipto_secure_auth_storage.dart';
import 'services/nipto_session_manager.dart';

/// Public client configuration for the Nipto Supabase project.
/// Dart defines can override these values for staging/production builds.
/// A publishable key is designed to be embedded in client apps; never put a
/// service-role/secret key here.
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

  final parsedUrl = Uri.tryParse(_supabaseUrl);
  final validUrl =
      parsedUrl != null &&
      parsedUrl.isAbsolute &&
      parsedUrl.scheme == 'https' &&
      parsedUrl.host.isNotEmpty;
  final validKey = _supabasePublishableKey.trim().isNotEmpty;

  if (!validUrl || !validKey) {
    runApp(
      const _ConfigurationMessage(
        title: 'Supabase configuration is invalid.',
        message:
            'Check SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY in your build configuration.',
      ),
    );
    return;
  }

  try {
    await Supabase.initialize(
      url: _supabaseUrl,
      publishableKey: _supabasePublishableKey,
      authOptions: FlutterAuthClientOptions(
        localStorage: NiptoSecureSessionStorage(),
        pkceAsyncStorage: NiptoSecurePkceStorage(),
      ),
      debug: false,
    );

    await NiptoSessionManager.instance.initialize(
      _supabaseUrl,
      _supabasePublishableKey,
    );
    // Firebase/FCM stays disabled unless all NIPTO_FIREBASE_* defines are
    // supplied. A missing push configuration never blocks normal app startup.
    await NiptoPushService.instance.initialize();
  } catch (error, stackTrace) {
    // Do not print response bodies, credentials, or tokens to application logs.
    debugPrint('Nipto startup failed (${error.runtimeType}).');
    debugPrintStack(stackTrace: stackTrace);
    runApp(
      const _ConfigurationMessage(
        title: 'Could not start Nipto.',
        message:
            'Check your internet connection and try again. If the problem continues, contact Nipto support.',
      ),
    );
    return;
  }

  runApp(const NiptoApp());
}

class _ConfigurationMessage extends StatelessWidget {
  const _ConfigurationMessage({required this.title, required this.message});

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
