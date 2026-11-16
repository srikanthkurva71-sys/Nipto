import 'package:flutter/material.dart';
import '../services/nipto_session_manager.dart';
import '../theme/nipto_theme.dart';
import 'password_recovery_screen.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final _formKey = GlobalKey<FormState>();
  final _niptoId = TextEditingController();
  final _displayName = TextEditingController();
  final _password = TextEditingController();
  final _confirmPassword = TextEditingController();
  final _recoveryNiptoId = TextEditingController();

  bool _creatingAccount = false;
  bool _busy = false;
  bool _hidePassword = true;
  String? _notice;
  bool _noticeIsError = false;

  @override
  void dispose() {
    _niptoId.dispose();
    _displayName.dispose();
    _password.dispose();
    _confirmPassword.dispose();
    _recoveryNiptoId.dispose();
    super.dispose();
  }

  String? _validateNiptoId(String? value) {
    final input = (value ?? '').trim().toLowerCase();
    if (!RegExp(r'^[a-z0-9_]{3,24}$').hasMatch(input)) {
      return 'Use 3–24 lowercase letters, numbers or underscores.';
    }
    if (const ['admin', 'administrator', 'support', 'help', 'nipto', 'official', 'security', 'moderator'].contains(input)) {
      return 'This Nipto ID is reserved.';
    }
    return null;
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate() || _busy) return;
    setState(() {
      _busy = true;
      _notice = null;
    });

    try {
      final handle = _niptoId.text.trim().toLowerCase().replaceFirst(RegExp(r'^@'), '');
      final sessions = NiptoSessionManager.instance;
      if (_creatingAccount) {
        await sessions.register(
          niptoId: handle,
          displayName: _displayName.text.trim(),
          password: _password.text,
          recoveryNiptoId: _recoveryNiptoId.text.trim().isEmpty
              ? null
              : _recoveryNiptoId.text.trim().toLowerCase().replaceFirst(RegExp(r'^@'), ''),
        );
      } else {
        await sessions.signIn(niptoId: handle, password: _password.text);
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
        _notice = 'Nipto could not complete your request. Check your connection and try again.';
        _noticeIsError = true;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _recoverPassword() async {
    final niptoIdController = TextEditingController();
    final niptoId = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Recover your Nipto account'),
        content: TextField(
          controller: niptoIdController,
          autocorrect: false,
          textCapitalization: TextCapitalization.none,
          decoration: const InputDecoration(labelText: 'Your Nipto ID', prefixText: '@'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, niptoIdController.text.trim()),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    niptoIdController.dispose();
    if (niptoId == null || niptoId.trim().isEmpty || !mounted) return;

    try {
      await NiptoSessionManager.instance.startPasswordRecovery(niptoId);
      if (!mounted) return;
      final grant = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          var checking = false;
          var message = 'If this account has an accepted recovery Nipto account, it will receive an in-app request. After approval, check here to continue.';
          return StatefulBuilder(
            builder: (context, setDialogState) => AlertDialog(
              title: const Text('Waiting for recovery approval'),
              content: Text(message),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const Text('Close'),
                ),
                FilledButton(
                  onPressed: checking
                      ? null
                      : () async {
                          setDialogState(() => checking = true);
                          try {
                            final approved = await NiptoSessionManager.instance.checkPasswordRecoveryApproval();
                            if (approved != null && dialogContext.mounted) {
                              Navigator.pop(dialogContext, approved);
                            } else {
                              setDialogState(() {
                                message = 'No approval has arrived yet. Ask your trusted Nipto contact to review the request, then check again.';
                              });
                            }
                          } on NiptoAuthException catch (error) {
                            setDialogState(() => message = error.message);
                          } catch (_) {
                            setDialogState(() => message = 'Could not check the request. Try again when your connection is available.');
                          } finally {
                            if (dialogContext.mounted) setDialogState(() => checking = false);
                          }
                        },
                  child: checking
                      ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('Check approval'),
                ),
              ],
            ),
          );
        },
      );
      if (grant == null || !mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PasswordRecoveryScreen(
            resetGrant: grant,
            onComplete: () {
              Navigator.of(context).pop();
              if (mounted) {
                setState(() {
                  _notice = 'Your password has been updated. Sign in with your new password.';
                  _noticeIsError = false;
                });
              }
            },
          ),
        ),
      );
    } on NiptoAuthException catch (error) {
      if (!mounted) return;
      setState(() {
        _notice = error.message;
        _noticeIsError = true;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _notice = 'Could not start account recovery. Please try again.';
        _noticeIsError = true;
      });
    }
  }

  void _toggleMode() {
    setState(() {
      _creatingAccount = !_creatingAccount;
      _notice = null;
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
                    ),
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
                        if ((value ?? '').length < 12) return 'Use at least 12 characters.';
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
                        'Your Nipto ID and password are your account credentials. A recovery Nipto account is optional; you can add one now or later in Settings → Security. The other account must accept your request.',
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
