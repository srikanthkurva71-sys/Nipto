import 'dart:async';

import 'package:flutter/material.dart';

import '../services/nipto_session_manager.dart';
import '../theme/nipto_theme.dart';

/// A registration field that validates and checks Nipto ID availability.
/// The backend is authoritative; availability can change before registration.
class NiptoIdAvailabilityField extends StatefulWidget {
  const NiptoIdAvailabilityField({
    super.key,
    required this.controller,
    this.onAvailabilityChanged,
    this.label = 'Nipto ID',
    this.hint = 'your_nipto_id',
    this.autofocus = false,
  });

  final TextEditingController controller;
  final ValueChanged<bool?>? onAvailabilityChanged;
  final String label;
  final String hint;
  final bool autofocus;

  @override
  State<NiptoIdAvailabilityField> createState() => _NiptoIdAvailabilityFieldState();
}

class _NiptoIdAvailabilityFieldState extends State<NiptoIdAvailabilityField> {
  Timer? _debounce;
  int _requestVersion = 0;
  bool _checking = false;
  bool? _available;
  String? _message;
  List<String> _suggestions = const [];

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onChanged);
  }

  @override
  void didUpdateWidget(covariant NiptoIdAvailabilityField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onChanged);
      widget.controller.addListener(_onChanged);
      // The replacement controller may already contain text. Revalidate it and
      // invalidate any availability result associated with the previous controller.
      _onChanged();
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    widget.controller.removeListener(_onChanged);
    super.dispose();
  }

  String _normalizedId() =>
      widget.controller.text.trim().replaceFirst(RegExp(r'^@'), '').toLowerCase();

  void _onChanged() {
    _debounce?.cancel();
    final version = ++_requestVersion;
    setState(() {
      _checking = false;
      _available = null;
      _message = null;
      _suggestions = const [];
    });
    widget.onAvailabilityChanged?.call(null);
    final value = _normalizedId();
    if (value.length < 3 || value.length > 24 ||
        !RegExp(r'^[a-z0-9]+(?:_[a-z0-9]+)*$').hasMatch(value)) {
      setState(() => _message = 'Use 3–24 lowercase letters or numbers, with single underscores between parts.');
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 400), () => _check(value, version));
  }

  Future<void> _check(String value, int version) async {
    if (!mounted || version != _requestVersion) return;
    setState(() {
      _checking = true;
      _message = 'Checking availability…';
    });
    try {
      final response = await NiptoSessionManager.instance.checkNiptoId(value);
      if (!mounted || version != _requestVersion || value != _normalizedId()) return;
      final available = response['available'] == true;
      final raw = response['suggestions'];
      final suggestions = raw is List
          ? raw.whereType<String>().take(5).toList()
          : <String>[];
      setState(() {
        _checking = false;
        _available = available;
        _suggestions = suggestions;
        _message = available
            ? 'This Nipto ID is available.'
            : 'This Nipto ID is taken or unavailable. Try a suggestion.';
      });
      widget.onAvailabilityChanged?.call(available);
    } on NiptoAuthException catch (error) {
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _checking = false;
        _available = false;
        _message = error.message;
      });
      widget.onAvailabilityChanged?.call(false);
    } catch (_) {
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _checking = false;
        _available = false;
        _message = 'Could not check availability. Please try again.';
      });
      widget.onAvailabilityChanged?.call(false);
    }
  }

  void _selectSuggestion(String suggestion) {
    widget.controller.value = TextEditingValue(
      text: suggestion,
      selection: TextSelection.collapsed(offset: suggestion.length),
    );
  }

  @override
  Widget build(BuildContext context) {
    final messageColor = _available == true
        ? NiptoColors.success
        : _available == false
            ? NiptoColors.danger
            : NiptoColors.muted;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextFormField(
          controller: widget.controller,
          autofocus: widget.autofocus,
          autocorrect: false,
          enableSuggestions: false,
          textCapitalization: TextCapitalization.none,
          decoration: InputDecoration(
            labelText: widget.label,
            hintText: widget.hint,
            prefixText: '@',
            prefixIcon: const Icon(Icons.alternate_email_rounded),
            suffixIcon: _checking
                ? const Padding(
                    padding: EdgeInsets.all(14),
                    child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                : _available == true
                    ? const Icon(Icons.check_circle_rounded, color: NiptoColors.success)
                    : null,
          ),
          validator: (value) {
            final id = (value ?? '').trim().replaceFirst(RegExp(r'^@'), '').toLowerCase();
            if (!RegExp(r'^[a-z0-9]+(?:_[a-z0-9]+)*$').hasMatch(id) ||
                id.length < 3 || id.length > 24) {
              return 'Enter a valid Nipto ID (3–24 characters).';
            }
            if (_available != true || id != _normalizedId()) {
              return 'Wait for a successful availability check.';
            }
            return null;
          },
        ),
        if (_message != null) ...[
          const SizedBox(height: 6),
          Text(_message!, style: TextStyle(fontSize: 12, color: messageColor)),
        ],
        if (_suggestions.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _suggestions.map((suggestion) => ActionChip(
              label: Text('@$suggestion'),
              onPressed: () => _selectSuggestion(suggestion),
            )).toList(),
          ),
        ],
      ],
    );
  }
}
