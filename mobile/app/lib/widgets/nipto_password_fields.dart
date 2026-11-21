import 'package:flutter/material.dart';

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

  bool get _longEnough => widget.passwordController.text.length >= 12;
  bool get _hasLower => RegExp(r'[a-z]').hasMatch(widget.passwordController.text);
  bool get _hasUpper => RegExp(r'[A-Z]').hasMatch(widget.passwordController.text);
  bool get _hasNumber => RegExp(r'[0-9]').hasMatch(widget.passwordController.text);
  bool get _hasSymbol => RegExp(r'[^A-Za-z0-9]').hasMatch(widget.passwordController.text);

  @override
  void initState() {
    super.initState();
    widget.passwordController.addListener(_refresh);
    widget.confirmationController.addListener(_refresh);
  }

  @override
  void didUpdateWidget(covariant NiptoPasswordFields oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.passwordController != widget.passwordController) {
      oldWidget.passwordController.removeListener(_refresh);
      widget.passwordController.addListener(_refresh);
    }
    if (oldWidget.confirmationController != widget.confirmationController) {
      oldWidget.confirmationController.removeListener(_refresh);
      widget.confirmationController.addListener(_refresh);
    }
  }

  void _refresh() {
    if (mounted) setState(() {});
    widget.onPasswordChanged?.call(widget.passwordController.text);
  }

  @override
  void dispose() {
    widget.passwordController.removeListener(_refresh);
    widget.confirmationController.removeListener(_refresh);
    super.dispose();
  }

  Widget _rule(String label, bool passed) => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(passed ? Icons.check_circle : Icons.circle_outlined,
                size: 14, color: passed ? Colors.green : Colors.grey),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(fontSize: 12, color: passed ? Colors.green : Colors.grey)),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final matching = widget.confirmationController.text.isNotEmpty &&
        widget.passwordController.text == widget.confirmationController.text;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextFormField(
          controller: widget.passwordController,
          obscureText: !_showPassword,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            labelText: 'Password',
            prefixIcon: const Icon(Icons.lock_outline_rounded),
            suffixIcon: IconButton(
              tooltip: _showPassword ? 'Hide password' : 'Show password',
              onPressed: () => setState(() => _showPassword = !_showPassword),
              icon: Icon(_showPassword ? Icons.visibility_off : Icons.visibility),
            ),
          ),
          validator: (value) {
            if (value == null || value.length < 12 || !_hasLower || !_hasUpper || !_hasNumber || !_hasSymbol) {
              return 'Use at least 12 characters, including uppercase, lowercase, number and symbol.';
            }
            return null;
          },
        ),
        const SizedBox(height: 8),
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
          decoration: InputDecoration(
            labelText: 'Confirm password',
            prefixIcon: const Icon(Icons.lock_outline_rounded),
            suffixIcon: IconButton(
              tooltip: _showConfirmation ? 'Hide password' : 'Show password',
              onPressed: () => setState(() => _showConfirmation = !_showConfirmation),
              icon: Icon(_showConfirmation ? Icons.visibility_off : Icons.visibility),
            ),
          ),
          validator: (value) {
            if (value == null || value.isEmpty) return 'Confirm your password.';
            if (value != widget.passwordController.text) return 'Passwords do not match.';
            return null;
          },
        ),
        if (widget.confirmationController.text.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            matching ? 'Passwords match.' : 'Passwords do not match.',
            style: TextStyle(fontSize: 12, color: matching ? Colors.green : Colors.red),
          ),
        ],
      ],
    );
  }
}
