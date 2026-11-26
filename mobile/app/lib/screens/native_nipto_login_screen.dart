import 'package:flutter/material.dart';

import '../services/nipto_session_manager.dart';

/// Native Nipto sign-in form scaffold. The submit callback must complete the
/// supported OIDC/Supabase session exchange, not merely verify a password.
class NativeNiptoLoginScreen extends StatefulWidget {
  const NativeNiptoLoginScreen({
    super.key,
    required this.onSubmit,
    this.onForgotPassword,
  });

  final Future<void> Function({
    required String niptoId,
    required String password,
  })
  onSubmit;
  final VoidCallback? onForgotPassword;

  @override
  State<NativeNiptoLoginScreen> createState() => _NativeNiptoLoginScreenState();
}

class _NativeNiptoLoginScreenState extends State<NativeNiptoLoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _idController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _showPassword = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _idController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  String _normalizeId(String value) =>
      value.trim().replaceFirst(RegExp(r'^@'), '').toLowerCase();

  Future<void> _submit() async {
    if (_busy || !_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onSubmit(
        niptoId: _normalizeId(_idController.text),
        password: _passwordController.text,
      );
    } on NiptoAuthException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Sign-in could not be completed. Check your connection and try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Sign in to Nipto')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Welcome back',
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 8),
                    const Text('Sign in with your Nipto ID.'),
                    const SizedBox(height: 24),
                    TextFormField(
                      controller: _idController,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: const InputDecoration(
                        labelText: 'Nipto ID',
                        hintText: 'your_nipto_id',
                        prefixText: '@',
                        prefixIcon: Icon(Icons.alternate_email),
                      ),
                      validator: (value) {
                        final id = _normalizeId(value ?? '');
                        if (id.length < 3 ||
                            id.length > 24 ||
                            !RegExp(
                              r'^[a-z0-9]+(?:_[a-z0-9]+)*$',
                            ).hasMatch(id)) {
                          return 'Enter a valid Nipto ID.';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: _passwordController,
                      obscureText: !_showPassword,
                      autocorrect: false,
                      enableSuggestions: false,
                      maxLength: 128,
                      decoration: InputDecoration(
                        labelText: 'Password',
                        prefixIcon: const Icon(Icons.lock_outline),
                        suffixIcon: IconButton(
                          tooltip: _showPassword
                              ? 'Hide password'
                              : 'Show password',
                          onPressed: () =>
                              setState(() => _showPassword = !_showPassword),
                          icon: Icon(
                            _showPassword
                                ? Icons.visibility_off
                                : Icons.visibility,
                          ),
                        ),
                      ),
                      validator: (value) => (value == null || value.isEmpty)
                          ? 'Enter your password.'
                          : null,
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: _busy ? null : widget.onForgotPassword,
                        child: const Text('Forgot password?'),
                      ),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 8),
                      Text(_error!, style: const TextStyle(color: Colors.red)),
                    ],
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: _busy ? null : _submit,
                      child: _busy
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Sign in'),
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
