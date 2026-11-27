import 'dart:math';

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

  String _generatePassword() {
    const lower = 'abcdefghijkmnopqrstuvwxyz';
    const upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ';
    const digits = '23456789';
    const symbols = r'!@#$%^&*()-_=+';
    const all = lower + upper + digits + symbols;
    final random = Random.secure();
    final chars = <String>[
      lower[random.nextInt(lower.length)],
      upper[random.nextInt(upper.length)],
      digits[random.nextInt(digits.length)],
      symbols[random.nextInt(symbols.length)],
    ];
    while (chars.length < 20) {
      chars.add(all[random.nextInt(all.length)]);
    }
    chars.shuffle(random);
    return chars.join();
  }

  void _suggestPassword() {
    final value = _generatePassword();
    setState(() {
      _password.text = value;
      _confirmPassword.text = value;
      _hidePassword = false;
      _error = null;
    });
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
      setState(
        () => _error = 'Your password could not be updated. Please try again.',
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Set a new password')),
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFFECEBFF), NiptoColors.canvas, Color(0xFFE7F8F8)],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(22),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Container(
                  padding: const EdgeInsets.all(25),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(26),
                    border: Border.all(color: NiptoColors.border),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x140F1C50),
                        blurRadius: 28,
                        offset: Offset(0, 12),
                      ),
                    ],
                  ),
                  child: Form(
                    key: _formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Center(child: NiptoLogoMark(size: 72)),
                        const SizedBox(height: 22),
                        Text(
                          'Create a new password',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                        const SizedBox(height: 10),
                        const Text(
                          'Your trusted Nipto account approved this request. Choose a new password to secure your account.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: NiptoColors.muted,
                            height: 1.5,
                          ),
                        ),
                        const SizedBox(height: 25),
                        TextFormField(
                          controller: _password,
                          obscureText: _hidePassword,
                          autocorrect: false,
                          enableSuggestions: false,
                          decoration: InputDecoration(
                            labelText: 'New password',
                            prefixIcon: const Icon(Icons.lock_outline_rounded),
                            suffixIcon: IconButton(
                              tooltip: _hidePassword
                                  ? 'Show password'
                                  : 'Hide password',
                              onPressed: () => setState(
                                () => _hidePassword = !_hidePassword,
                              ),
                              icon: Icon(
                                _hidePassword
                                    ? Icons.visibility_outlined
                                    : Icons.visibility_off_outlined,
                              ),
                            ),
                          ),
                          onChanged: (_) => setState(() {}),
                          validator: (value) {
                            if ((value ?? '').length < 12)
                              return 'Use at least 12 characters.';
                            if ((value ?? '').length > 128)
                              return 'Use no more than 128 characters.';
                            return null;
                          },
                        ),
                        const SizedBox(height: 10),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: _saving ? null : _suggestPassword,
                            icon: const Icon(
                              Icons.auto_awesome_rounded,
                              size: 18,
                            ),
                            label: const Text('Suggest a strong password'),
                          ),
                        ),
                        if (_password.text.isNotEmpty) ...[
                          const SizedBox(height: 2),
                          _PasswordStrength(value: _password.text),
                        ],
                        const SizedBox(height: 12),
                        TextFormField(
                          controller: _confirmPassword,
                          obscureText: _hidePassword,
                          autocorrect: false,
                          enableSuggestions: false,
                          decoration: const InputDecoration(
                            labelText: 'Confirm new password',
                            prefixIcon: Icon(Icons.verified_user_outlined),
                          ),
                          validator: (value) {
                            if (value != _password.text)
                              return 'Passwords do not match.';
                            return null;
                          },
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: 14),
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFFF1F2),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              _error!,
                              style: const TextStyle(
                                color: NiptoColors.danger,
                                height: 1.4,
                              ),
                            ),
                          ),
                        ],
                        const SizedBox(height: 24),
                        FilledButton(
                          onPressed: _saving ? null : _savePassword,
                          child: _saving
                              ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.white,
                                  ),
                                )
                              : const Text('Update password'),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'Your new password is private. Your recovery contact cannot see it.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: NiptoColors.muted,
                            fontSize: 12,
                            height: 1.4,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PasswordStrength extends StatelessWidget {
  const _PasswordStrength({required this.value});

  final String value;

  @override
  Widget build(BuildContext context) {
    final checks = [
      value.length >= 12,
      RegExp(r'[a-z]').hasMatch(value),
      RegExp(r'[A-Z]').hasMatch(value),
      RegExp(r'[0-9]').hasMatch(value),
      RegExp(r'[^A-Za-z0-9]').hasMatch(value),
    ];
    final score = checks.where((check) => check).length;
    final label = score >= 5
        ? 'Strong password'
        : score >= 3
        ? 'Good progress'
        : 'Add length and variety';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: List.generate(
              5,
              (index) => Expanded(
                child: Container(
                  height: 4,
                  margin: EdgeInsets.only(right: index == 4 ? 0 : 5),
                  decoration: BoxDecoration(
                    color: index < score
                        ? NiptoColors.success
                        : NiptoColors.border,
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: const TextStyle(color: NiptoColors.muted, fontSize: 11),
          ),
        ],
      ),
    );
  }
}
