import 'package:flutter/material.dart';

import '../services/nipto_session_manager.dart';
import '../theme/nipto_theme.dart';
import '../widgets/nipto_logo_mark.dart';

class PasswordRecoveryScreen extends StatefulWidget {
  const PasswordRecoveryScreen({
    super.key,
    required this.resetGrant,
    required this.onComplete,
  });

  final String resetGrant;
  final VoidCallback onComplete;

  @override
  State<PasswordRecoveryScreen> createState() => _PasswordRecoveryScreenState();
}

class _PasswordRecoveryScreenState extends State<PasswordRecoveryScreen> {
  final _formKey = GlobalKey<FormState>();
  final _password = TextEditingController();
  final _confirmPassword = TextEditingController();
  bool _hidePassword = true;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    _confirmPassword.dispose();
    super.dispose();
  }

  Future<void> _savePassword() async {
    if (!_formKey.currentState!.validate() || _saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await NiptoSessionManager.instance.resetPassword(
        resetGrant: widget.resetGrant,
        newPassword: _password.text,
      );
      if (!mounted) return;
      widget.onComplete();
    } on NiptoAuthException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = 'Your password could not be updated. Please try again.');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Set a new password')),
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
                    const Center(child: NiptoLogoMark(size: 76)),
                    const SizedBox(height: 24),
                    Text('Create a new password', style: Theme.of(context).textTheme.headlineSmall),
                    const SizedBox(height: 8),
                    const Text(
                      'Your trusted Nipto account approved this request. Choose a new password to secure your account.',
                      style: TextStyle(color: NiptoColors.muted),
                    ),
                    const SizedBox(height: 24),
                    TextFormField(
                      controller: _password,
                      obscureText: _hidePassword,
                      decoration: InputDecoration(
                        labelText: 'New password',
                        prefixIcon: const Icon(Icons.lock_outline_rounded),
                        suffixIcon: IconButton(
                          tooltip: _hidePassword ? 'Show password' : 'Hide password',
                          onPressed: () => setState(() => _hidePassword = !_hidePassword),
                          icon: Icon(_hidePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                        ),
                      ),
                      validator: (value) {
                        if ((value ?? '').length < 12) return 'Use at least 12 characters.';
                        return null;
                      },
                    ),
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _confirmPassword,
                      obscureText: _hidePassword,
                      decoration: const InputDecoration(
                        labelText: 'Confirm new password',
                        prefixIcon: Icon(Icons.verified_user_outlined),
                      ),
                      validator: (value) {
                        if (value != _password.text) return 'Passwords do not match.';
                        return null;
                      },
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 14),
                      Text(_error!, style: const TextStyle(color: NiptoColors.danger)),
                    ],
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: _saving ? null : _savePassword,
                      child: _saving
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : const Text('Update password'),
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
