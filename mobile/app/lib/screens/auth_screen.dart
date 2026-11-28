import 'package:flutter/material.dart';

import '../services/nipto_session_manager.dart';
import '../theme/nipto_theme.dart';
import '../widgets/nipto_logo_mark.dart';
import 'native_nipto_login_screen.dart';
import 'native_nipto_registration_screen.dart';
import 'password_recovery_screen.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  bool _busy = false;
  String? _notice;
  bool _noticeIsError = false;

  Future<void> _startAuthentication({required bool register}) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      if (register) {
        await NiptoSessionManager.instance.register();
      } else {
        await NiptoSessionManager.instance.signIn();
      }
    } on NiptoAuthException catch (error) {
      if (!mounted) return;
      setState(() {
        _notice = error.message;
        _noticeIsError = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _notice =
            'Nipto could not open secure sign-in. Check your connection and try again.';
        _noticeIsError = true;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openSignIn() async {
    final navigator = Navigator.of(context);
    await navigator.push<bool>(
      MaterialPageRoute(
        builder: (_) => NativeNiptoLoginScreen(
          onSubmit: ({required niptoId, required password}) async {
            await NiptoSessionManager.instance.signInWithNiptoId(
              niptoId: niptoId,
              password: password,
            );
            // AuthGate swaps the home widget on the signed-in auth event, but
            // the credential route stays on top of the navigator unless it is
            // explicitly closed.
            if (navigator.canPop()) {
              navigator.pop(true);
            }
          },
          onForgotPassword: () {
            navigator.pop();
            _openRecovery();
          },
        ),
      ),
    );
  }

  Future<void> _openRegistration() async {
    final navigator = Navigator.of(context);
    await navigator.push<bool>(
      MaterialPageRoute(
        builder: (_) => NativeNiptoRegistrationScreen(
          onSubmit:
              ({
                required displayName,
                required niptoId,
                required password,
                required passwordConfirmation,
              }) async {
                await NiptoSessionManager.instance.registerNiptoAccount(
                  displayName: displayName,
                  niptoId: niptoId,
                  password: password,
                  passwordConfirmation: passwordConfirmation,
                );
                if (navigator.canPop()) {
                  navigator.pop(true);
                }
              },
        ),
      ),
    );
  }

  Future<void> _openRecovery() async {
    final completed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const PasswordRecoveryRequestScreen()),
    );
    if (!mounted || completed != true) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Your password was updated. Sign in with your new password.',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
              padding: const EdgeInsets.fromLTRB(22, 30, 22, 30),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(26, 32, 26, 26),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(30),
                    border: Border.all(color: NiptoColors.border),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x160F1C50),
                        blurRadius: 34,
                        offset: Offset(0, 16),
                      ),
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Center(child: NiptoLogoMark(size: 84)),
                      const SizedBox(height: 22),
                      const Text(
                        'Your Nipto account. Your identity.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: NiptoColors.ink,
                          fontSize: 25,
                          height: 1.15,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -0.8,
                        ),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Connect with one Nipto ID. Sign in or create your account securely—no email address or phone number required.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: NiptoColors.muted,
                          height: 1.55,
                        ),
                      ),
                      const SizedBox(height: 30),
                      FilledButton.icon(
                        onPressed: _busy ? null : _openSignIn,
                        icon: const Icon(Icons.login_rounded),
                        label: const Text('Sign in with Nipto ID'),
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _openRegistration,
                        icon: const Icon(Icons.person_add_alt_1_rounded),
                        label: const Text('Create Nipto account'),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(52),
                          foregroundColor: NiptoColors.violet,
                          side: const BorderSide(color: NiptoColors.violet),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                      ),
                      if (_busy) ...[
                        const SizedBox(height: 20),
                        const Center(
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(height: 9),
                        const Text(
                          'Opening browser sign-in fallback…',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: NiptoColors.muted,
                            fontSize: 12,
                          ),
                        ),
                      ],
                      if (_notice != null) ...[
                        const SizedBox(height: 18),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: _noticeIsError
                                ? const Color(0xFFFFF1F2)
                                : const Color(0xFFEAF8F2),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            _notice!,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: _noticeIsError
                                  ? NiptoColors.danger
                                  : NiptoColors.success,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      TextButton.icon(
                        onPressed: _busy ? null : _openRecovery,
                        icon: const Icon(Icons.lock_reset_rounded),
                        label: const Text('Forgot password?'),
                      ),
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => _startAuthentication(register: false),
                        child: const Text(
                          'Use browser sign-in instead',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                      const SizedBox(height: 14),
                      const Divider(),
                      const SizedBox(height: 12),
                      const Text(
                        'A recovery Nipto account is optional. You can add or change one later in Settings.',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: NiptoColors.muted,
                          fontSize: 12,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 10),
                      const Text(
                        'SECURE IDENTITY · NIPTO',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: NiptoColors.muted,
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.5,
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
    );
  }
}

class PasswordRecoveryRequestScreen extends StatefulWidget {
  const PasswordRecoveryRequestScreen({super.key});

  @override
  State<PasswordRecoveryRequestScreen> createState() =>
      _PasswordRecoveryRequestScreenState();
}

class _PasswordRecoveryRequestScreenState
    extends State<PasswordRecoveryRequestScreen> {
  final _formKey = GlobalKey<FormState>();
  final _niptoId = TextEditingController();
  bool _busy = false;
  bool _waiting = false;
  String? _error;
  String? _statusMessage;

  @override
  void dispose() {
    _niptoId.dispose();
    super.dispose();
  }

  Future<void> _startRecovery() async {
    if (!_formKey.currentState!.validate() || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _statusMessage = null;
    });
    try {
      await NiptoSessionManager.instance.startPasswordRecovery(
        _niptoId.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        _waiting = true;
        _statusMessage =
            'If this account has an accepted recovery Nipto account, that trusted account can review your request. Once approved, return here and check again.';
      });
    } on NiptoAuthException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted)
        setState(
          () => _error =
              'Could not start recovery. Check your connection and try again.',
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _checkApproval() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final grant = await NiptoSessionManager.instance
          .checkPasswordRecoveryApproval();
      if (!mounted) return;
      if (grant == null) {
        setState(
          () => _statusMessage =
              'Approval has not arrived yet. Ask your trusted Nipto contact to review the request, then check again.',
        );
        return;
      }
      final completed = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => PasswordRecoveryScreen(
            resetGrant: grant,
            onComplete: () => Navigator.of(context).pop(true),
          ),
        ),
      );
      if (!mounted) return;
      if (completed == true) Navigator.of(context).pop(true);
    } on NiptoAuthException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted)
        setState(
          () => _error =
              'Could not check the recovery request. Please try again.',
        );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Account recovery')),
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
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Center(child: NiptoLogoMark(size: 72)),
                      const SizedBox(height: 22),
                      Text(
                        _waiting
                            ? 'Waiting for approval'
                            : 'Recover your Nipto account',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        _waiting
                            ? 'Your password can only be reset after an accepted recovery contact approves this request.'
                            : 'Enter the Nipto ID for the account you need to recover. We will check for its trusted recovery contact.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: NiptoColors.muted,
                          height: 1.5,
                        ),
                      ),
                      if (!_waiting) ...[
                        const SizedBox(height: 26),
                        Form(
                          key: _formKey,
                          child: TextFormField(
                            controller: _niptoId,
                            autofocus: true,
                            autocorrect: false,
                            textCapitalization: TextCapitalization.none,
                            decoration: const InputDecoration(
                              labelText: 'Your Nipto ID',
                              hintText: 'your_nipto_id',
                              prefixText: '@',
                              prefixIcon: Icon(Icons.alternate_email_rounded),
                            ),
                            validator: (value) {
                              final id = (value ?? '')
                                  .trim()
                                  .replaceFirst(RegExp(r'^@'), '')
                                  .toLowerCase();
                              if (!RegExp(
                                    r'^[a-z0-9]+(?:_[a-z0-9]+)*$',
                                  ).hasMatch(id) ||
                                  id.length < 3 ||
                                  id.length > 24) {
                                return 'Enter a valid Nipto ID (3–24 characters).';
                              }
                              return null;
                            },
                          ),
                        ),
                      ],
                      if (_waiting && _statusMessage != null) ...[
                        const SizedBox(height: 22),
                        Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: NiptoColors.violetSoft,
                            borderRadius: BorderRadius.circular(14),
                          ),
                          child: Text(
                            _statusMessage!,
                            style: const TextStyle(
                              height: 1.5,
                              color: NiptoColors.ink,
                            ),
                          ),
                        ),
                      ],
                      if (_error != null) ...[
                        const SizedBox(height: 16),
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
                        onPressed: _busy
                            ? null
                            : (_waiting ? _checkApproval : _startRecovery),
                        child: _busy
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              )
                            : Text(_waiting ? 'Check approval' : 'Continue'),
                      ),
                      if (_waiting) ...[
                        const SizedBox(height: 8),
                        OutlinedButton(
                          onPressed: _busy
                              ? null
                              : () => setState(() {
                                  _waiting = false;
                                  _error = null;
                                  _statusMessage = null;
                                }),
                          child: const Text('Use a different Nipto ID'),
                        ),
                      ],
                      const SizedBox(height: 10),
                      TextButton(
                        onPressed: _busy
                            ? null
                            : () => Navigator.of(context).pop(),
                        child: const Text('Back to sign in'),
                      ),
                    ],
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
