import 'dart:math';

import 'package:flutter/material.dart';

import '../services/nipto_password_policy.dart';

/// Password and confirmation fields for native Nipto account forms.
/// This widget validates locally for UX; server-side password policy is authoritative.
class NiptoPasswordFields extends StatefulWidget {
  const NiptoPasswordFields({
    super.key,
    required this.passwordController,
    required this.confirmationController,
    this.onPasswordChanged,
  });

  final TextEditingController passwordController;
  final TextEditingController confirmationController;
  final ValueChanged<String>? onPasswordChanged;

  @override
  State<NiptoPasswordFields> createState() => _NiptoPasswordFieldsState();
}

class _NiptoPasswordFieldsState extends State<NiptoPasswordFields> {
  bool _showPassword = false;
  bool _showConfirmation = false;

  static const _passwordAlphabet =
      'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!@#\$%^&*()-_=+[]{};:,.?';

  String _generateSuggestedPassword() {
    final random = Random.secure();
    final chars = List.generate(
      18,
      (_) => _passwordAlphabet[random.nextInt(_passwordAlphabet.length)],
    );
    // Ensure the suggestion satisfies each local password rule.
    chars[0] = 'A';
    chars[1] = 'a';
    chars[2] = '7';
    chars[3] = '!';
    for (var i = chars.length - 1; i > 0; i--) {
      final j = random.nextInt(i + 1);
      final temporary = chars[i];
      chars[i] = chars[j];
      chars[j] = temporary;
    }
    return chars.join();
  }

  void _suggestPassword() {
    final suggestion = _generateSuggestedPassword();
    widget.passwordController.text = suggestion;
    widget.confirmationController.text = suggestion;
  }

  bool get _longEnough =>
      NiptoPasswordPolicy.hasMinimumLength(widget.passwordController.text);
  bool get _hasLower =>
      NiptoPasswordPolicy.hasLowercase(widget.passwordController.text);
  bool get _hasUpper =>
      NiptoPasswordPolicy.hasUppercase(widget.passwordController.text);
  bool get _hasNumber =>
      NiptoPasswordPolicy.hasNumber(widget.passwordController.text);
  bool get _hasSymbol =>
      NiptoPasswordPolicy.hasSymbol(widget.passwordController.text);

  @override
  void initState() {
    super.initState();
    widget.passwordController.addListener(_onPasswordChanged);
    widget.confirmationController.addListener(_onConfirmationChanged);
  }

  @override
  void didUpdateWidget(covariant NiptoPasswordFields oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.passwordController != widget.passwordController) {
      oldWidget.passwordController.removeListener(_onPasswordChanged);
      widget.passwordController.addListener(_onPasswordChanged);
    }
    if (oldWidget.confirmationController != widget.confirmationController) {
      oldWidget.confirmationController.removeListener(_onConfirmationChanged);
      widget.confirmationController.addListener(_onConfirmationChanged);
    }
  }

  void _onPasswordChanged() {
    if (mounted) setState(() {});
    widget.onPasswordChanged?.call(widget.passwordController.text);
  }

  void _onConfirmationChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.passwordController.removeListener(_onPasswordChanged);
    widget.confirmationController.removeListener(_onConfirmationChanged);
    super.dispose();
  }

  Widget _rule(String label, bool passed) => Padding(
    padding: const EdgeInsets.only(top: 4),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          passed ? Icons.check_circle : Icons.circle_outlined,
          size: 14,
          color: passed ? Colors.green : Colors.grey,
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            color: passed ? Colors.green : Colors.grey,
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final matching = NiptoPasswordPolicy.matches(
      widget.passwordController.text,
      widget.confirmationController.text,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextFormField(
          controller: widget.passwordController,
          obscureText: !_showPassword,
          autocorrect: false,
          enableSuggestions: false,
          autofillHints: const [AutofillHints.newPassword],
          maxLength: 128,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(
            labelText: 'Password',
            prefixIcon: const Icon(Icons.lock_outline_rounded),
            suffixIcon: IconButton(
              tooltip: _showPassword ? 'Hide password' : 'Show password',
              onPressed: () => setState(() => _showPassword = !_showPassword),
              icon: Icon(
                _showPassword ? Icons.visibility_off : Icons.visibility,
              ),
            ),
          ),
          validator: (value) {
            if (value == null || !NiptoPasswordPolicy.isValid(value)) {
              return 'Use at least 12 characters, including uppercase, lowercase, number and symbol.';
            }
            return null;
          },
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _suggestPassword,
            icon: const Icon(Icons.auto_awesome),
            label: const Text('Suggest a strong password'),
          ),
        ),
        Wrap(
          spacing: 12,
          runSpacing: 4,
          children: [
            _rule('12+ characters', _longEnough),
            _rule('Lowercase', _hasLower),
            _rule('Uppercase', _hasUpper),
            _rule('Number', _hasNumber),
            _rule('Symbol', _hasSymbol),
          ],
        ),
        const SizedBox(height: 18),
        TextFormField(
          controller: widget.confirmationController,
          obscureText: !_showConfirmation,
          autocorrect: false,
          enableSuggestions: false,
          autofillHints: const [AutofillHints.newPassword],
          maxLength: 128,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            labelText: 'Confirm password',
            prefixIcon: const Icon(Icons.lock_outline_rounded),
            suffixIcon: IconButton(
              tooltip: _showConfirmation ? 'Hide password' : 'Show password',
              onPressed: () =>
                  setState(() => _showConfirmation = !_showConfirmation),
              icon: Icon(
                _showConfirmation ? Icons.visibility_off : Icons.visibility,
              ),
            ),
          ),
          validator: (value) {
            if (value == null || value.isEmpty) return 'Confirm your password.';
            if (value != widget.passwordController.text)
              return 'Passwords do not match.';
            return null;
          },
        ),
        if (widget.confirmationController.text.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            matching ? 'Passwords match.' : 'Passwords do not match.',
            style: TextStyle(
              fontSize: 12,
              color: matching ? Colors.green : Colors.red,
            ),
          ),
        ],
      ],
    );
  }
}
