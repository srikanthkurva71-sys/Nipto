import 'package:flutter/material.dart';

import '../widgets/nipto_id_availability_field.dart';
import '../widgets/nipto_password_fields.dart';

/// Native registration UI scaffold.
///
/// This screen intentionally accepts a submit callback instead of directly creating
/// accounts. The callback must be wired only to the reviewed OIDC/session bridge;
/// a password-check API alone must never create an authenticated app session.
class NativeNiptoRegistrationScreen extends StatefulWidget {
  const NativeNiptoRegistrationScreen({
    super.key,
    required this.onSubmit,
  });

  final Future<void> Function({
    required String displayName,
    required String niptoId,
    required String password,
    String? recoveryNiptoId,
  }) onSubmit;

  @override
  State<NativeNiptoRegistrationScreen> createState() =>
      _NativeNiptoRegistrationScreenState();
}

class _NativeNiptoRegistrationScreenState
    extends State<NativeNiptoRegistrationScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _idController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmationController = TextEditingController();
  bool _busy = false;
  bool? _idAvailable;
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    _idController.dispose();
    _passwordController.dispose();
    _confirmationController.dispose();
    super.dispose();
  }

  String _normalizedId(String value) =>
      value.trim().replaceFirst(RegExp(r'^@'), '').toLowerCase();

  Future<void> _submit() async {
    if (_busy || !_formKey.currentState!.validate()) return;
    if (_idAvailable != true) {
      setState(() => _error = 'Wait for Nipto ID availability to be confirmed.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onSubmit(
        displayName: _nameController.text.trim(),
        niptoId: _normalizedId(_idController.text),
        password: _passwordController.text,
        recoveryNiptoId: null,
      );
    } catch (_) {
      if (mounted) setState(() => _error = 'Registration could not be completed. Please try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Create your Nipto account')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('Create your identity', style: Theme.of(context).textTheme.headlineMedium),
                    const SizedBox(height: 8),
                    const Text('Choose a display name and unique Nipto ID. You can add a recovery account later in Settings.'),
                    const SizedBox(height: 22),
                    TextFormField(
                      controller: _nameController,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                        labelText: 'Display name',
                        prefixIcon: Icon(Icons.person_outline),
                      ),
                      validator: (value) {
                        final name = (value ?? '').trim();
                        if (name.length < 2 || name.length > 50) {
                          return 'Display name must be 2–50 characters.';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 16),
                    NiptoIdAvailabilityField(
                      controller: _idController,
                      onAvailabilityChanged: (available) {
                        if (mounted) {
                          setState(() {
                            _idAvailable = available;
                            if (available == null || available == true) _error = null;
                          });
                        }
                      },
                      autofocus: false,
                    ),
                    const SizedBox(height: 18),
                    NiptoPasswordFields(
                      passwordController: _passwordController,
                      confirmationController: _confirmationController,
                    ),
                    const SizedBox(height: 18),
                    if (_error != null) ...[
                      const SizedBox(height: 16),
                      Text(_error!, style: const TextStyle(color: Colors.red)),
                    ],
                    const SizedBox(height: 24),
                    FilledButton(
                      onPressed: _busy ? null : _submit,
                      child: _busy
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Create Nipto account'),
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
