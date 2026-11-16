import 'package:flutter/material.dart';

import '../services/nipto_session_manager.dart';
import '../theme/nipto_theme.dart';
import '../widgets/nipto_logo_mark.dart';
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

  Future<void> _startSignIn({required bool register}) async {
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
        _notice = 'Nipto could not open secure sign-in. Check your connection and try again.';
        _noticeIsError = true;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _recoverPassword() async {
    final controller = TextEditingController();
    final niptoId = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Recover your Nipto account'),
        content: TextField(
          controller: controller,
          autocorrect: false,
          textCapitalization: TextCapitalization.none,
          decoration: const InputDecoration(
            labelText: 'Your Nipto ID',
            prefixText: '@',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (niptoId == null || niptoId.trim().isEmpty || !mounted) return;

    try {
      await NiptoSessionManager.instance.startPasswordRecovery(niptoId);
      if (!mounted) return;
      final grant = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          var checking = false;
          var message =
              'If this account has an accepted recovery Nipto account, it will receive an in-app request. After approval, check here to continue.';
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
                            final approved = await NiptoSessionManager.instance
                                .checkPasswordRecoveryApproval();
                            if (approved != null && dialogContext.mounted) {
                              Navigator.pop(dialogContext, approved);
                            } else {
                              setDialogState(() {
                                message =
                                    'No approval has arrived yet. Ask your trusted Nipto contact to review the request, then check again.';
                              });
                            }
                          } on NiptoAuthException catch (error) {
                            setDialogState(() => message = error.message);
                          } catch (_) {
                            setDialogState(() {
                              message =
                                  'Could not check the request. Try again when your connection is available.';
                            });
                          } finally {
                            if (dialogContext.mounted) {
                              setDialogState(() => checking = false);
                            }
                          }
                        },
                  child: checking
                      ? const SizedBox(
                          height: 18,
                          width: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
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
                  _notice =
                      'Your password has been updated. Sign in with your new Nipto password.';
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: 20),
                  const Center(child: NiptoLogoMark(size: 92)),
                  const SizedBox(height: 24),
                  const Text(
                    'Your Nipto account. Your identity.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: NiptoColors.ink,
                      fontSize: 25,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Sign in or create an account with your Nipto ID and password. No email address or phone number is required.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: NiptoColors.muted,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 30),
                  FilledButton.icon(
                    onPressed: _busy ? null : () => _startSignIn(register: false),
                    icon: const Icon(Icons.login_rounded),
                    label: const Text('Sign in with Nipto'),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : () => _startSignIn(register: true),
                    icon: const Icon(Icons.person_add_alt_1_rounded),
                    label: const Text('Create Nipto account'),
                  ),
                  if (_busy) ...[
                    const SizedBox(height: 20),
                    const Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Opening secure Nipto sign-in…',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: NiptoColors.muted, fontSize: 12),
                    ),
                  ],
                  if (_notice != null) ...[
                    const SizedBox(height: 18),
                    Text(
                      _notice!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: _noticeIsError
                            ? NiptoColors.danger
                            : NiptoColors.success,
                      ),
                    ),
                  ],
                  const SizedBox(height: 18),
                  TextButton(
                    onPressed: _busy ? null : _recoverPassword,
                    child: const Text('Forgot password?'),
                  ),
                  const SizedBox(height: 18),
                  const Text(
                    'A recovery Nipto account is optional. You can add or change one later in Settings.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: NiptoColors.muted,
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
