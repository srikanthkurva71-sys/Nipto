import 'package:flutter/material.dart';

import '../services/nipto_session_manager.dart';
import '../theme/nipto_theme.dart';

class AccountMigrationScreen extends StatefulWidget {
  const AccountMigrationScreen({super.key});

  @override
  State<AccountMigrationScreen> createState() => _AccountMigrationScreenState();
}

class _AccountMigrationScreenState extends State<AccountMigrationScreen> {
  final _formKey = GlobalKey<FormState>();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _hidePassword = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _migrate() async {
    if (!_formKey.currentState!.validate() || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await NiptoSessionManager.instance.migrateLegacyAccount(_password.text);
      // AuthGate observes the new Nipto session and opens the app shell.
    } on NiptoAuthException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Your account could not be migrated. Keep this device signed in and try again.';
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
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Center(child: Icon(Icons.verified_user_outlined, size: 68, color: NiptoColors.violet)),
                    const SizedBox(height: 24),
                    Text('Upgrade your Nipto account', style: Theme.of(context).textTheme.headlineSmall),
                    const SizedBox(height: 10),
                    const Text(
                      'Nipto is moving to its own account system. This device has an existing signed-in session, so you can securely move your account to Nipto ID and password without changing your profile or social data.',
                      style: TextStyle(color: NiptoColors.muted, height: 1.5),
                    ),
                    const SizedBox(height: 18),
                    const Text(
                      'Choose a new Nipto password. Your existing profile, messages, followers and media remain linked to the same Nipto account.',
                      style: TextStyle(height: 1.45),
                    ),
                    const SizedBox(height: 20),
                    TextFormField(
                      controller: _password,
                      obscureText: _hidePassword,
                      decoration: InputDecoration(
                        labelText: 'New Nipto password',
                        prefixIcon: const Icon(Icons.lock_outline_rounded),
                        suffixIcon: IconButton(
                          onPressed: () => setState(() => _hidePassword = !_hidePassword),
                          icon: Icon(_hidePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                        ),
                      ),
                      validator: (value) {
                        if ((value ?? '').length < 12) return 'Use at least 12 characters.';
                        return null;
                      },
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _confirm,
                      obscureText: _hidePassword,
                      decoration: const InputDecoration(
                        labelText: 'Confirm new password',
                        prefixIcon: Icon(Icons.verified_user_outlined),
                      ),
                      validator: (value) => value == _password.text ? null : 'Passwords do not match.',
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 14),
                      Text(_error!, style: const TextStyle(color: NiptoColors.danger)),
                    ],
                    const SizedBox(height: 22),
                    FilledButton(
                      onPressed: _busy ? null : _migrate,
                      child: _busy
                          ? const SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Text('Secure my Nipto account'),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'This migration uses your existing signed-in session to verify account ownership. It does not ask for an email address.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: NiptoColors.muted, fontSize: 12, height: 1.4),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
