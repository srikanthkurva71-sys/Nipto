import 'package:flutter/material.dart';

import '../services/nipto_session_manager.dart';
import '../theme/nipto_theme.dart';
import '../widgets/nipto_logo_mark.dart';

class AccountMigrationScreen extends StatefulWidget {
  const AccountMigrationScreen({super.key});

  @override
  State<AccountMigrationScreen> createState() => _AccountMigrationScreenState();
}

class _AccountMigrationScreenState extends State<AccountMigrationScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _linkNiptoIdentity() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await NiptoSessionManager.instance.linkLegacyAccount();
    } on NiptoAuthException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not link your Nipto identity. Keep this device signed in and try again.';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Center(child: NiptoLogoMark(size: 82)),
                  const SizedBox(height: 24),
                  Text(
                    'Move to your Nipto identity',
                    style: Theme.of(context).textTheme.headlineSmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'This device has an existing signed-in account. Link it to Nipto ID and password to keep your profile, messages, followers and media on the same account.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: NiptoColors.muted, height: 1.5),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'You will choose your Nipto password in Nipto’s secure sign-in page. The migration does not ask for an email address, and the legacy email sign-in is removed after the Nipto identity is linked.',
                    textAlign: TextAlign.center,
                    style: TextStyle(height: 1.5),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 18),
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: NiptoColors.danger),
                    ),
                  ],
                  const SizedBox(height: 26),
                  FilledButton(
                    onPressed: _busy ? null : _linkNiptoIdentity,
                    child: _busy
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Link my Nipto identity'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
