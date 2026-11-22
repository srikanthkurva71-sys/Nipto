import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/auth/nipto_id_policy.dart';
import '../core/auth/nipto_id_availability.dart';
import '../core/auth/nipto_id_suggestions.dart';
import '../theme/nipto_theme.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _formKey = GlobalKey<FormState>();
  final _niptoId = TextEditingController();
  final _displayName = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirmPassword = TextEditingController();
  final _recoveryNiptoId = TextEditingController();

  bool _creatingAccount = false;
  bool _busy = false;
  bool _hidePassword = true;
  String? _notice;
  bool _noticeIsError = false;
  bool? _idAvailable;
  bool _checkingId = false;
  int _idCheckGeneration = 0;
  List<String> _idSuggestions = const [];

  SupabaseClient get _client => Supabase.instance.client;

  @override
  void dispose() {
    _niptoId.dispose();
    _displayName.dispose();
    _email.dispose();
    _password.dispose();
    _confirmPassword.dispose();
    _recoveryNiptoId.dispose();
    super.dispose();
  }

  String? _validateNiptoId(String? value) => NiptoIdPolicy.validate(value);

  Future<void> _checkNiptoIdAvailability(String value) async {
    final normalized = value.trim().toLowerCase().replaceFirst(RegExp(r'^@'), '');
    final generation = ++_idCheckGeneration;
    if (NiptoIdPolicy.validate(normalized) != null) {
      if (mounted) setState(() { _idAvailable = null; _checkingId = false; _idSuggestions = const []; });
      return;
    }
    if (mounted) setState(() { _checkingId = true; _idAvailable = null; _idSuggestions = const []; });
    try {
      final available = await NiptoIdAvailability(client: _client).isAvailable(normalized);
      if (!mounted || generation != _idCheckGeneration) return;
      setState(() {
        _checkingId = false;
        _idAvailable = available;
        _idSuggestions = available ? const [] : NiptoIdSuggestions.generate(normalized);
      });
    } catch (_) {
      if (!mounted || generation != _idCheckGeneration) return;
      setState(() { _checkingId = false; _idAvailable = null; _idSuggestions = const []; });
    }
  }

  void _onNiptoIdChanged(String value) {
    _idAvailable = null;
    _idSuggestions = const [];
    if (_creatingAccount) _checkNiptoIdAvailability(value);
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _notice = null;
    });

    try {
      final handle = _niptoId.text.trim().toLowerCase();
      if (_creatingAccount) {
        if (_idAvailable != true) {
          throw const FormatException('Please choose a Nipto ID that is confirmed available.');
        }
        final response = await _client.auth.signUp(
          email: _email.text.trim(),
          password: _password.text,
          data: {
            'nipto_id': handle,
            'display_name': _displayName.text.trim(),
          },
        );

        final recoveryId = _recoveryNiptoId.text.trim().toLowerCase().replaceFirst(RegExp(r'^@'), '');
        var recoveryRequestFailed = false;
        if (response.session != null && recoveryId.isNotEmpty) {
          try {
            await _client.rpc(
              'request_recovery_contact',
              params: {'p_nipto_id': recoveryId},
            );
          } catch (_) {
            recoveryRequestFailed = true;
          }
        }

        if (!mounted) return;
        if (response.session == null) {
          setState(() {
            _notice = 'Account created. Verify your email, then open Settings → Security → Recovery Nipto account to add your trusted contact.';
            _noticeIsError = false;
          });
        } else if (recoveryRequestFailed) {
          setState(() {
            _notice = 'Account created, but the recovery request could not be sent. You can retry it in Settings → Security → Recovery Nipto account.';
            _noticeIsError = true;
          });
        } else if (recoveryId.isNotEmpty) {
          setState(() {
            _notice = 'Account created. Your recovery-contact request has been sent for approval.';
            _noticeIsError = false;
          });
        }
      } else {
        final response = await _client.functions.invoke(
          'nipto-login',
          body: {
            'nipto_id': handle,
            'password': _password.text,
          },
        );

        final data = response.data;
        if (data is! Map || data['refresh_token'] is! String) {
          throw const FormatException('The sign-in service returned an invalid response.');
        }
        await _client.auth.setSession(data['refresh_token'] as String);
      }
    } on AuthException catch (error) {
      if (!mounted) return;
      setState(() {
        _notice = error.message;
        _noticeIsError = true;
      });
    } on FunctionException catch (error) {
      if (!mounted) return;
      final details = error.details;
      final message = details is Map && details['error'] is String
          ? details['error'] as String
          : 'Could not sign in. Check your connection and try again.';
      setState(() {
        _notice = message;
        _noticeIsError = true;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _notice = error is FormatException
            ? error.message
            : 'Something went wrong. Please try again.';
        _noticeIsError = true;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _recoverPassword() async {
    final emailController = TextEditingController(text: _email.text.trim());
    final email = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset your password'),
        content: TextField(
          controller: emailController,
          keyboardType: TextInputType.emailAddress,
          decoration: const InputDecoration(
            labelText: 'Verified recovery email',
            hintText: 'you@example.com',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, emailController.text.trim()),
            child: const Text('Send link'),
          ),
        ],
      ),
    );
    emailController.dispose();
    if (email == null || email.isEmpty || !mounted) return;

    try {
      await _client.auth.resetPasswordForEmail(
        email,
        redirectTo: 'nipto://auth-callback',
      );
      if (!mounted) return;
      setState(() {
        _notice = 'If that address belongs to a Nipto account, a reset link will arrive shortly.';
        _noticeIsError = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _notice = 'Could not send the reset link. Please try again.';
        _noticeIsError = true;
      });
    }
  }

  void _toggleMode() {
    setState(() {
      _creatingAccount = !_creatingAccount;
      _notice = null;
      _idAvailable = null;
      _idSuggestions = const [];
      _checkingId = false;
      _idCheckGeneration++;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 12),
                    const Center(child: NiptoLogoMark(size: 92)),
                    const SizedBox(height: 18),
                    const Text(
                      'NIPTO',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: NiptoColors.ink,
                        fontSize: 30,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 4,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _creatingAccount ? 'Your people. Your space.' : 'Good to see you again.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: NiptoColors.muted,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 34),
                    Text(
                      _creatingAccount ? 'Create your account' : 'Sign in to Nipto',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    const SizedBox(height: 20),
                    if (_creatingAccount) ...[
                      TextFormField(
                        controller: _displayName,
                        textCapitalization: TextCapitalization.words,
                        decoration: const InputDecoration(
                          labelText: 'Your name',
                          prefixIcon: Icon(Icons.person_outline_rounded),
                        ),
                        validator: (value) {
                          if ((value ?? '').trim().isEmpty) return 'Enter your name.';
                          if ((value ?? '').trim().length > 50) return 'Name is too long.';
                          return null;
                        },
                      ),
                      const SizedBox(height: 13),
                      TextFormField(
                        controller: _recoveryNiptoId,
                        autocorrect: false,
                        textCapitalization: TextCapitalization.none,
                        decoration: const InputDecoration(
                          labelText: 'Recovery Nipto ID (optional)',
                          prefixIcon: Icon(Icons.shield_outlined),
                          prefixText: '@',
                          hintText: 'trusted_person',
                        ),
                        validator: (value) {
                          final input = (value ?? '').trim().toLowerCase().replaceFirst(RegExp(r'^@'), '');
                          if (input.isEmpty) return null;
                          if (!RegExp(r'^[a-z0-9_]{3,24}$').hasMatch(input)) {
                            return 'Enter a valid Nipto ID or leave this blank.';
                          }
                          if (input == _niptoId.text.trim().toLowerCase()) {
                            return 'Choose a different Nipto account.';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 13),
                      TextFormField(
                        controller: _email,
                        keyboardType: TextInputType.emailAddress,
                        autocorrect: false,
                        decoration: const InputDecoration(
                          labelText: 'Recovery email',
                          prefixIcon: Icon(Icons.alternate_email_rounded),
                        ),
                        validator: (value) {
                          final input = (value ?? '').trim();
                          if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(input)) {
                            return 'Enter a valid email address.';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 13),
                    ],
                    TextFormField(
                      controller: _niptoId,
                      autocorrect: false,
                      textCapitalization: TextCapitalization.none,
                      decoration: const InputDecoration(
                        labelText: 'Nipto ID',
                        prefixIcon: Icon(Icons.alternate_email_rounded),
                        hintText: 'yourname',
                      ),
                      validator: _validateNiptoId,
                      onChanged: _onNiptoIdChanged,
                    ),
                    if (_creatingAccount) ...[
                      const SizedBox(height: 6),
                      Row(children: [
                        if (_checkingId) const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                        if (_checkingId) const SizedBox(width: 8),
                        if (!_checkingId && _idAvailable == true) const Icon(Icons.check_circle_outline, color: Colors.green, size: 18),
                        if (!_checkingId && _idAvailable == false) const Icon(Icons.error_outline, color: NiptoColors.danger, size: 18),
                        Expanded(child: Text(_checkingId ? 'Checking Nipto ID…' : _idAvailable == true ? 'Nipto ID is available' : _idAvailable == false ? 'This Nipto ID is already taken' : 'Enter an ID to check availability', style: const TextStyle(fontSize: 12, color: NiptoColors.muted))),
                      ]),
                      if (_idSuggestions.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Wrap(spacing: 8, runSpacing: 6, children: _idSuggestions.map((suggestion) => ActionChip(label: Text(suggestion), onPressed: () { _niptoId.text = suggestion; _onNiptoIdChanged(suggestion); })).toList()),
                      ],
                    ],
                    const SizedBox(height: 13),
                    TextFormField(
                      controller: _password,
                      obscureText: _hidePassword,
                      decoration: InputDecoration(
                        labelText: 'Password',
                        prefixIcon: const Icon(Icons.lock_outline_rounded),
                        suffixIcon: IconButton(
                          tooltip: _hidePassword ? 'Show password' : 'Hide password',
                          onPressed: () => setState(() => _hidePassword = !_hidePassword),
                          icon: Icon(_hidePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                        ),
                      ),
                      validator: (value) {
                        if ((value ?? '').length < 8) return 'Use at least 8 characters.';
                        return null;
                      },
                    ),
                    if (_creatingAccount) ...[
                      const SizedBox(height: 13),
                      TextFormField(
                        controller: _confirmPassword,
                        obscureText: _hidePassword,
                        decoration: const InputDecoration(
                          labelText: 'Confirm password',
                          prefixIcon: Icon(Icons.verified_user_outlined),
                        ),
                        validator: (value) {
                          if (value != _password.text) return 'Passwords do not match.';
                          return null;
                        },
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Your recovery email is used for verification and password recovery. The optional recovery Nipto account must accept your request. You can also add or change it later in Settings → Security.',
                        style: TextStyle(color: NiptoColors.muted, fontSize: 12, height: 1.4),
                      ),

                    ],
                    if (!_creatingAccount)
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: _busy ? null : _recoverPassword,
                          child: const Text('Forgot password?'),
                        ),
                      ),
                    if (_notice != null) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(13),
                        decoration: BoxDecoration(
                          color: _noticeIsError ? const Color(0xFFFFEEEE) : NiptoColors.violetSoft,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: Text(
                          _notice!,
                          style: TextStyle(
                            color: _noticeIsError ? NiptoColors.danger : NiptoColors.ink,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 22),
                    FilledButton(
                      onPressed: _busy ? null : _submit,
                      child: _busy
                          ? const SizedBox(
                              height: 21,
                              width: 21,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : Text(_creatingAccount ? 'Create Nipto account' : 'Sign in'),
                    ),
                    const SizedBox(height: 12),
                    TextButton(
                      onPressed: _busy ? null : _toggleMode,
                      child: Text(
                        _creatingAccount
                            ? 'Already have a Nipto ID? Sign in'
                            : 'New to Nipto? Create an account',
                      ),
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


class NiptoLogoMark extends StatelessWidget {
  const NiptoLogoMark({super.key, this.size = 72});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            decoration: BoxDecoration(
              gradient: NiptoBrand.markGradient,
              borderRadius: BorderRadius.circular(size * 0.27),
              boxShadow: [
                BoxShadow(
                  color: NiptoColors.violet.withValues(alpha: 0.18),
                  blurRadius: size * 0.28,
                  offset: Offset(0, size * 0.12),
                ),
              ],
            ),
          ),
          Center(
            child: Text(
              'N',
              style: TextStyle(
                color: Colors.white,
                fontSize: size * 0.73,
                height: 1,
                fontWeight: FontWeight.w900,
                fontStyle: FontStyle.italic,
                letterSpacing: -size * 0.09,
              ),
            ),
          ),
          Positioned(
            right: -size * 0.12,
            top: -size * 0.10,
            child: Container(
              width: size * 0.43,
              height: size * 0.36,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFFFF648D), NiptoColors.brandMagenta],
                ),
                borderRadius: BorderRadius.circular(size * 0.15),
                border: Border.all(color: Colors.white, width: size * 0.025),
              ),
              child: Icon(
                Icons.groups_rounded,
                color: Colors.white,
                size: size * 0.25,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
