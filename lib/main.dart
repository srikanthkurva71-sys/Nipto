import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';


import 'nipto_app.dart';

const _supabaseUrl = String.fromEnvironment(
  'SUPABASE_URL',
  defaultValue: 'https://advmjribduqzyuwktkod.supabase.co',
);
const _supabasePublishableKey = String.fromEnvironment(
  'SUPABASE_PUBLISHABLE_KEY',
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (_supabasePublishableKey.isEmpty) {
    runApp(const _MissingConfigurationApp());
    return;
  }

  await Supabase.initialize(
    url: _supabaseUrl,
    publishableKey: _supabasePublishableKey,
    debug: false,
  );

  runApp(const NiptoApp());
}

class _MissingConfigurationApp extends StatelessWidget {
  const _MissingConfigurationApp();

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
              children: const [
                Text(
                  'NIPTO',
                  style: TextStyle(
                    color: Color(0xFF6657E8),
                    fontSize: 30,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 3,
                  ),
                ),
                SizedBox(height: 18),
                Text(
                  'Supabase configuration is missing.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                ),
                SizedBox(height: 8),
                Text(
                  'Run with --dart-define=SUPABASE_PUBLISHABLE_KEY=YOUR_KEY.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Color(0xFF777A8C)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
