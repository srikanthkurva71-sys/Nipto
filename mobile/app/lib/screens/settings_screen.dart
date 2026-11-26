import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
// ignore: depend_on_referenced_packages
import 'package:url_launcher/url_launcher.dart';

import '../services/nipto_privacy_service.dart';
import '../services/nipto_session_manager.dart';

import '../theme/nipto_theme.dart';
import 'feedback_screen.dart';
import 'close_friends_screen.dart';
import 'staff_console_screen.dart';
import 'recovery_contacts_screen.dart';
import 'session_management_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool? _isPrivate;
  bool _saving = false;
  String _messageAccess = 'mutuals';
  bool _messageNotifications = true;
  bool _followNotifications = true;
  bool _statusNotifications = true;
  bool _shortNotifications = true;
  late Future<List<Map<String, dynamic>>> _blocked;
  late Future<bool> _staffAccess;
  late Future<List<NiptoPrivacyRequest>> _privacyRequests;
  bool _privacyBusy = false;

  final NiptoPrivacyService _privacyService = NiptoPrivacyService();

  SupabaseClient get _client => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _blocked = _loadBlocked();
    _staffAccess = _loadStaffAccess();
    _privacyRequests = _privacyService.status();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final userId = NiptoSessionManager.instance.userId;
    if (userId == null) return;
    try {
      await _client
          .from('user_preferences')
          .upsert(
            {'user_id': userId},
            onConflict: 'user_id',
            ignoreDuplicates: true,
          );
      final results = await Future.wait([
        _client.from('profiles').select('is_private').eq('id', userId).single(),
        _client
            .from('user_preferences')
            .select(
              'message_access, message_notifications, follow_notifications, status_notifications, short_notifications',
            )
            .eq('user_id', userId)
            .single(),
      ]);
      if (!mounted) return;
      final profile = results[0];
      final preferences = results[1];
      setState(() {
        _isPrivate = profile['is_private'] as bool? ?? false;
        _messageAccess = preferences['message_access'] as String? ?? 'mutuals';
        _messageNotifications =
            preferences['message_notifications'] as bool? ?? true;
        _followNotifications =
            preferences['follow_notifications'] as bool? ?? true;
        _statusNotifications =
            preferences['status_notifications'] as bool? ?? true;
        _shortNotifications =
            preferences['short_notifications'] as bool? ?? true;
      });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Some settings could not be loaded. Pull down to retry.',
            ),
          ),
        );
      }
    }
    if (mounted) {
      setState(() => _privacyRequests = _privacyService.status());
    }
  }

  Future<void> _setPrivate(bool value) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _isPrivate = value;
    });
    try {
      await _client
          .from('profiles')
          .update({'is_private': value})
          .eq('id', NiptoSessionManager.instance.userId!);
    } catch (_) {
      if (!mounted) return;
      setState(() => _isPrivate = !value);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Privacy setting could not be saved.')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _updatePreference(String key, Object value) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await _client
          .from('user_preferences')
          .update({key: value})
          .eq('user_id', NiptoSessionManager.instance.userId!);
      if (!mounted) return;
      setState(() {
        switch (key) {
          case 'message_access':
            _messageAccess = value as String;
            break;
          case 'message_notifications':
            _messageNotifications = value as bool;
            break;
          case 'follow_notifications':
            _followNotifications = value as bool;
            break;
          case 'status_notifications':
            _statusNotifications = value as bool;
            break;
          case 'short_notifications':
            _shortNotifications = value as bool;
            break;
        }
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Setting could not be saved.')),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<bool> _loadStaffAccess() async {
    try {
      return await _client.rpc('staff_can_access') == true;
    } catch (_) {
      return false;
    }
  }

  Future<List<Map<String, dynamic>>> _loadBlocked() async {
    final rows = await _client.rpc('list_blocked_profiles');
    return (rows as List).map((row) => Map<String, dynamic>.from(row)).toList();
  }

  Future<void> _unblock(Map<String, dynamic> profile) async {
    final handle = profile['nipto_id'] as String? ?? 'this account';
    final shouldUnblock = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Unblock this account?'),
        content: Text(
          '@' +
              handle +
              ' will be able to find your account again, subject to your privacy settings.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Unblock'),
          ),
        ],
      ),
    );
    if (shouldUnblock != true) return;
    try {
      await _client.from('blocked_users').delete().match({
        'blocker_id': NiptoSessionManager.instance.userId!,
        'blocked_id': profile['user_id'],
      });
      if (mounted) setState(() => _blocked = _loadBlocked());
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not unblock this account.')),
      );
    }
  }

  Future<void> _changePassword() async {
    final current = TextEditingController();
    final next = TextEditingController();
    final confirm = TextEditingController();
    String? error;
    var saving = false;
    final changed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Change Nipto password'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: current,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Current password',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: next,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'New password (12+ characters)',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: confirm,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Confirm new password',
                  ),
                ),
                if (error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    error!,
                    style: const TextStyle(color: NiptoColors.danger),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: saving
                  ? null
                  : () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: saving
                  ? null
                  : () async {
                      if (next.text.length < 12) {
                        setDialogState(
                          () => error = 'Use at least 12 characters.',
                        );
                        return;
                      }
                      if (next.text != confirm.text) {
                        setDialogState(
                          () => error = 'The new passwords do not match.',
                        );
                        return;
                      }
                      setDialogState(() {
                        saving = true;
                        error = null;
                      });
                      try {
                        await NiptoSessionManager.instance.changePassword(
                          currentPassword: current.text,
                          newPassword: next.text,
                        );
                        if (dialogContext.mounted)
                          Navigator.pop(dialogContext, true);
                      } on NiptoAuthException catch (exception) {
                        setDialogState(() => error = exception.message);
                      } catch (_) {
                        setDialogState(
                          () => error =
                              'Could not change your password. Try again.',
                        );
                      } finally {
                        if (dialogContext.mounted)
                          setDialogState(() => saving = false);
                      }
                    },
              child: saving
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Update password'),
            ),
          ],
        ),
      ),
    );
    current.dispose();
    next.dispose();
    confirm.dispose();
    if (changed == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Password changed. Sign in again on this device.'),
        ),
      );
    }
  }

  Future<void> _signOut() async {
    final shouldSignOut = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign out of Nipto?'),
        content: const Text(
          'You can sign back in with your Nipto ID and password.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (shouldSignOut != true) return;
    await NiptoSessionManager.instance.signOut();
    if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
  }

  Future<void> _signOutEverywhere() async {
    final shouldSignOut = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Sign out on all devices?'),
        content: const Text(
          'Nipto will revoke this account’s refresh sessions. Devices may remain signed in briefly until their current access tokens expire.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Sign out everywhere'),
          ),
        ],
      ),
    );
    if (shouldSignOut != true) return;
    try {
      await NiptoSessionManager.instance.signOutEverywhere();
      if (mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not revoke other sessions. Please try again.'),
        ),
      );
    }
  }

  Future<void> _requestPrivacyExport() async {
    if (_privacyBusy) return;
    setState(() => _privacyBusy = true);
    try {
      await _privacyService.request(NiptoPrivacyKind.export);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Export requested. A private download link will appear here when it is ready.',
          ),
        ),
      );
      _refreshPrivacyRequests();
    } catch (error) {
      _showPrivacyError(error);
    } finally {
      if (mounted) setState(() => _privacyBusy = false);
    }
  }

  Future<void> _confirmAccountDeletion() async {
    final confirmation = TextEditingController();
    const phrase = 'DELETE MY NIPTO ACCOUNT'; // keep in sync with dialog text
    String? error;
    var submitting = false;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (_, setDialogState) => AlertDialog(
          title: const Text('Delete your Nipto account?'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Deletion is scheduled 14 days from now. You can cancel any time before that deadline by returning to Settings.',
                ),
                const SizedBox(height: 12),
                const Text(
                  'After the deadline your account, sessions, profile and uploaded media are permanently removed. Messages and moderation records other people need may remain, but your attribution is removed. This cannot be undone after the deadline.',
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: confirmation,
                  decoration: const InputDecoration(
                    labelText: 'Type DELETE MY NIPTO ACCOUNT to confirm',
                    hintText: 'DELETE MY NIPTO ACCOUNT',
                  ),
                ),
                if (error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    error!,
                    style: const TextStyle(color: NiptoColors.danger),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: submitting
                  ? null
                  : () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: NiptoColors.danger,
              ),
              onPressed: submitting
                  ? null
                  : () async {
                      if (confirmation.text.trim() != phrase) {
                        setDialogState(
                          () => error = 'Type $phrase exactly to continue.',
                        );
                        return;
                      }
                      setDialogState(() {
                        submitting = true;
                        error = null;
                      });
                      try {
                        await _privacyService.request(
                          NiptoPrivacyKind.deletion,
                        );
                        if (dialogContext.mounted) {
                          Navigator.pop(dialogContext, true);
                        }
                      } on NiptoPrivacyException catch (exception) {
                        if (dialogContext.mounted) {
                          setDialogState(() => error = exception.message);
                        }
                      } catch (_) {
                        if (dialogContext.mounted) {
                          setDialogState(
                            () => error =
                                'Could not schedule deletion. Please try again.',
                          );
                        }
                      } finally {
                        if (dialogContext.mounted) {
                          setDialogState(() => submitting = false);
                        }
                      }
                    },
              child: submitting
                  ? const SizedBox(
                      height: 18,
                      width: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('Schedule deletion'),
            ),
          ],
        ),
      ),
    );
    confirmation.dispose();
    if (confirmed == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Account deletion scheduled. You can cancel any time before the 14-day deadline.',
          ),
        ),
      );
      _refreshPrivacyRequests();
    }
  }

  Future<void> _cancelAccountDeletion() async {
    if (_privacyBusy) return;
    setState(() => _privacyBusy = true);
    try {
      final canceled = await _privacyService.cancelDeletion();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            canceled
                ? 'Account deletion canceled. Your account is unchanged.'
                : 'There was no pending deletion to cancel.',
          ),
        ),
      );
      _refreshPrivacyRequests();
    } catch (error) {
      _showPrivacyError(error);
    } finally {
      if (mounted) setState(() => _privacyBusy = false);
    }
  }

  Future<void> _downloadExport(NiptoPrivacyRequest request) async {
    if (_privacyBusy) return;
    setState(() => _privacyBusy = true);
    try {
      final link = await _privacyService.exportUrl(request.id);
      final uri = Uri.tryParse(link.signedUrl);
      var opened = false;
      if (uri != null) {
        try {
          opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
        } catch (_) {
          opened = false;
        }
      }
      if (!opened) {
        await Clipboard.setData(ClipboardData(text: link.signedUrl));
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Could not open a browser. The export link was copied instead and expires at ${_formatDateTime(context, link.expiresAt)}.',
            ),
          ),
        );
      }
    } catch (error) {
      _showPrivacyError(error);
    } finally {
      if (mounted) setState(() => _privacyBusy = false);
    }
  }

  void _refreshPrivacyRequests() {
    if (!mounted) return;
    setState(() => _privacyRequests = _privacyService.status());
  }

  void _showPrivacyError(Object error) {
    if (!mounted) return;
    final message = error is NiptoPrivacyException
        ? error.message
        : 'Privacy request could not be completed. Please try again.';
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  bool _hasPendingDeletion(List<NiptoPrivacyRequest> requests) {
    return requests.any(
      (request) =>
          request.kind == NiptoPrivacyKind.deletion &&
          (request.status == NiptoPrivacyStatus.pending ||
              request.status == NiptoPrivacyStatus.processing),
    );
  }

  bool _canDownloadExport(NiptoPrivacyRequest request) {
    final completedAt = request.completedAt;
    return request.isCompletedExport &&
        completedAt != null &&
        completedAt.isAfter(DateTime.now().subtract(const Duration(days: 7)));
  }

  String _privacyStatusLabel(NiptoPrivacyRequest request) {
    if (request.kind == NiptoPrivacyKind.deletion) {
      return switch (request.status) {
        NiptoPrivacyStatus.pending => 'Deletion scheduled',
        NiptoPrivacyStatus.processing => 'Deletion in progress',
        NiptoPrivacyStatus.completed => 'Account deleted',
        NiptoPrivacyStatus.failed => 'Deletion failed',
        NiptoPrivacyStatus.canceled => 'Deletion canceled',
      };
    }
    return switch (request.status) {
      NiptoPrivacyStatus.pending => 'Export scheduled',
      NiptoPrivacyStatus.processing => 'Export in progress',
      NiptoPrivacyStatus.completed => 'Export ready to download',
      NiptoPrivacyStatus.failed => 'Export failed',
      NiptoPrivacyStatus.canceled => 'Export canceled',
    };
  }

  String _privacySubtitle(BuildContext context, NiptoPrivacyRequest request) {
    if (request.kind == NiptoPrivacyKind.deletion &&
        request.status == NiptoPrivacyStatus.pending) {
      return 'Cancel before ${_formatDateTime(context, request.executeAfter)}. After that your account and uploaded media are permanently removed.';
    }
    if (request.status == NiptoPrivacyStatus.completed &&
        request.kind == NiptoPrivacyKind.export) {
      final completedAt = request.completedAt;
      if (completedAt != null) {
        return 'Download link expires ${_formatDateTime(context, completedAt.add(const Duration(days: 7)))}.';
      }
    }
    if (request.status == NiptoPrivacyStatus.failed) {
      return 'The worker could not finish this request. You can submit a new one.';
    }
    return 'Requested ${_formatDateTime(context, request.requestedAt)}.';
  }

  String _formatDateTime(BuildContext context, DateTime value) {
    final local = value.toLocal();
    final localizations = MaterialLocalizations.of(context);
    return '${localizations.formatFullDate(local)} at '
        '${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(local))}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: RefreshIndicator(
        onRefresh: _loadSettings,
        child: ListView(
          padding: const EdgeInsets.all(18),
          children: [
            const _SectionLabel('PRIVACY'),
            Card(
              child: Column(
                children: [
                  SwitchListTile(
                    value: _isPrivate ?? false,
                    onChanged: _isPrivate == null || _saving
                        ? null
                        : _setPrivate,
                    title: const Text('Private account'),
                    subtitle: const Text(
                      'Approve follow requests before people can see follower-only updates.',
                    ),
                    activeThumbColor: NiptoColors.violet,
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(
                      Icons.people_alt_outlined,
                      color: NiptoColors.violet,
                    ),
                    title: const Text('Close Friends'),
                    subtitle: const Text(
                      'Choose who can see Close Friends-only statuses.',
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const CloseFriendsScreen(),
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.mark_chat_unread_outlined),
                    title: const Text('Who can message you'),
                    subtitle: Text(_messageAccessLabel(_messageAccess)),
                    trailing: DropdownButton<String>(
                      value: _messageAccess,
                      underline: const SizedBox.shrink(),
                      items: const [
                        DropdownMenuItem(
                          value: 'mutuals',
                          child: Text('Mutuals'),
                        ),
                        DropdownMenuItem(
                          value: 'followers',
                          child: Text('Followers'),
                        ),
                        DropdownMenuItem(
                          value: 'nobody',
                          child: Text('Nobody'),
                        ),
                      ],
                      onChanged: _saving
                          ? null
                          : (value) {
                              if (value != null)
                                _updatePreference('message_access', value);
                            },
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            const _SectionLabel('BLOCKED ACCOUNTS'),
            Card(
              child: FutureBuilder<List<Map<String, dynamic>>>(
                future: _blocked,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Padding(
                      padding: EdgeInsets.all(18),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  if (snapshot.hasError) {
                    return ListTile(
                      title: const Text('Blocked accounts could not load'),
                      trailing: TextButton(
                        onPressed: () =>
                            setState(() => _blocked = _loadBlocked()),
                        child: const Text('Retry'),
                      ),
                    );
                  }
                  final users = snapshot.data ?? [];
                  if (users.isEmpty) {
                    return const ListTile(
                      leading: Icon(Icons.shield_outlined),
                      title: Text('No blocked accounts'),
                      subtitle: Text('Accounts you block will appear here.'),
                    );
                  }
                  return Column(
                    children: users.map((profile) {
                      final name =
                          profile['display_name'] as String? ?? 'Nipto member';
                      final handle = profile['nipto_id'] as String? ?? '';
                      return ListTile(
                        leading: const CircleAvatar(
                          backgroundColor: NiptoColors.violetSoft,
                          child: Icon(
                            Icons.person_outline_rounded,
                            color: NiptoColors.violet,
                          ),
                        ),
                        title: Text(name),
                        subtitle: Text('@' + handle),
                        trailing: TextButton(
                          onPressed: () => _unblock(profile),
                          child: const Text('Unblock'),
                        ),
                      );
                    }).toList(),
                  );
                },
              ),
            ),
            const SizedBox(height: 20),
            const _SectionLabel('NOTIFICATIONS'),
            Card(
              child: Column(
                children: [
                  SwitchListTile(
                    value: _messageNotifications,
                    onChanged: _saving
                        ? null
                        : (value) =>
                              _updatePreference('message_notifications', value),
                    title: const Text('Messages'),
                    activeThumbColor: NiptoColors.violet,
                  ),
                  const Divider(height: 1),
                  SwitchListTile(
                    value: _followNotifications,
                    onChanged: _saving
                        ? null
                        : (value) =>
                              _updatePreference('follow_notifications', value),
                    title: const Text('Follows and requests'),
                    activeThumbColor: NiptoColors.violet,
                  ),
                  const Divider(height: 1),
                  SwitchListTile(
                    value: _statusNotifications,
                    onChanged: _saving
                        ? null
                        : (value) =>
                              _updatePreference('status_notifications', value),
                    title: const Text('Status updates'),
                    activeThumbColor: NiptoColors.violet,
                  ),
                  const Divider(height: 1),
                  SwitchListTile(
                    value: _shortNotifications,
                    onChanged: _saving
                        ? null
                        : (value) =>
                              _updatePreference('short_notifications', value),
                    title: const Text('Shorts activity'),
                    activeThumbColor: NiptoColors.violet,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            const _SectionLabel('SECURITY'),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(
                      Icons.shield_outlined,
                      color: NiptoColors.violet,
                    ),
                    title: const Text('Recovery Nipto account'),
                    subtitle: const Text(
                      'Add and manage a trusted Nipto account for recovery assistance.',
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const RecoveryContactsScreen(),
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.lock_reset_rounded),
                    title: const Text('Password and recovery'),
                    subtitle: const Text(
                      'Change your Nipto password or recover it through your trusted Nipto account.',
                    ),
                    onTap: _changePassword,
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.devices_outlined),
                    title: const Text('Devices and sessions'),
                    subtitle: const Text(
                      'Review signed-in devices and revoke sessions you do not recognize.',
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const SessionManagementScreen(),
                      ),
                    ),
                  ),
                  const Divider(height: 1),
                  const ListTile(
                    leading: Icon(Icons.verified_user_outlined),
                    title: Text('Secure sign-in'),
                    subtitle: Text(
                      'Nipto ID and password are verified by Nipto. Sessions use signed, short-lived tokens.',
                    ),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.devices_outlined),
                    title: const Text('Sign out on all devices'),
                    subtitle: const Text(
                      'Revoke refresh sessions on other devices.',
                    ),
                    onTap: _signOutEverywhere,
                  ),
                ],
              ),
            ),
            FutureBuilder<bool>(
              future: _staffAccess,
              builder: (context, snapshot) {
                if (snapshot.data != true) return const SizedBox.shrink();
                return Column(
                  children: [
                    const SizedBox(height: 20),
                    const _SectionLabel('OPERATIONS'),
                    Card(
                      child: ListTile(
                        leading: const Icon(
                          Icons.admin_panel_settings_outlined,
                          color: NiptoColors.violet,
                        ),
                        title: const Text('Staff review'),
                        subtitle: const Text(
                          'Review feedback, reports and pending content.',
                        ),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const StaffConsoleScreen(),
                          ),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 20),
            const _SectionLabel('HELP & FEEDBACK'),
            Card(
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(
                      Icons.feedback_outlined,
                      color: NiptoColors.violet,
                    ),
                    title: const Text('Feedback & support'),
                    subtitle: const Text(
                      'Report a problem, suggest a feature or rate your experience.',
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => const FeedbackScreen(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            const _SectionLabel('PRIVACY & DATA'),
            Card(
              child: FutureBuilder<List<NiptoPrivacyRequest>>(
                future: _privacyRequests,
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Padding(
                      padding: EdgeInsets.all(18),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  if (snapshot.hasError) {
                    return ListTile(
                      leading: const Icon(Icons.privacy_tip_outlined),
                      title: const Text('Privacy requests could not load'),
                      subtitle: const Text(
                        'Export and deletion status is unavailable right now.',
                      ),
                      trailing: TextButton(
                        onPressed: _refreshPrivacyRequests,
                        child: const Text('Retry'),
                      ),
                    );
                  }
                  final requests =
                      snapshot.data ?? const <NiptoPrivacyRequest>[];
                  final deletionPending = _hasPendingDeletion(requests);
                  return Column(
                    children: [
                      if (requests.isEmpty)
                        const ListTile(
                          leading: Icon(Icons.privacy_tip_outlined),
                          title: Text('No privacy requests'),
                          subtitle: Text(
                            'Export your data or schedule account deletion below.',
                          ),
                        ),
                      for (final request in requests) ...[
                        ListTile(
                          leading: Icon(
                            request.kind == NiptoPrivacyKind.export
                                ? Icons.download_outlined
                                : Icons.delete_outline,
                            color: NiptoColors.violet,
                          ),
                          title: Text(_privacyStatusLabel(request)),
                          subtitle: Text(_privacySubtitle(context, request)),
                          trailing: request.isPendingDeletion
                              ? TextButton(
                                  onPressed: _privacyBusy
                                      ? null
                                      : _cancelAccountDeletion,
                                  child: const Text('Cancel deletion'),
                                )
                              : null,
                        ),
                        if (_canDownloadExport(request))
                          Padding(
                            padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: OutlinedButton.icon(
                                onPressed: _privacyBusy
                                    ? null
                                    : () => _downloadExport(request),
                                icon: const Icon(Icons.open_in_new_rounded),
                                label: const Text('Download export'),
                              ),
                            ),
                          ),
                        const Divider(height: 1),
                      ],
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(
                          Icons.download_outlined,
                          color: NiptoColors.violet,
                        ),
                        title: const Text('Export my data'),
                        subtitle: const Text(
                          'Create a private copy of your profile and activity. The download link expires after 7 days.',
                        ),
                        onTap: _privacyBusy ? null : _requestPrivacyExport,
                      ),
                      const Divider(height: 1),
                      ListTile(
                        leading: const Icon(
                          Icons.delete_forever_outlined,
                          color: NiptoColors.danger,
                        ),
                        title: const Text('Delete my Nipto account'),
                        subtitle: Text(
                          deletionPending
                              ? 'Deletion is already scheduled. Cancel it before scheduling again.'
                              : 'Schedule permanent deletion after a 14-day cancellation window.',
                        ),
                        onTap: _privacyBusy || deletionPending
                            ? null
                            : _confirmAccountDeletion,
                      ),
                    ],
                  );
                },
              ),
            ),
            const SizedBox(height: 20),
            const _SectionLabel('ACCOUNT'),
            const Card(
              child: ListTile(
                leading: Icon(Icons.info_outline_rounded),
                title: Text('About Nipto'),
                subtitle: Text('Nipto Social · Android'),
              ),
            ),
            const SizedBox(height: 22),
            OutlinedButton.icon(
              onPressed: _signOut,
              icon: const Icon(Icons.logout_rounded),
              label: const Text('Sign out'),
              style: OutlinedButton.styleFrom(
                foregroundColor: NiptoColors.danger,
                minimumSize: const Size.fromHeight(50),
                side: const BorderSide(color: Color(0xFFF0C9CE)),
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'Nipto is built to help people connect respectfully. Privacy, blocking and reporting are part of the product.',
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
    );
  }

  String _messageAccessLabel(String value) {
    switch (value) {
      case 'followers':
        return 'People who follow you can start a chat.';
      case 'nobody':
        return 'Only existing conversations can continue.';
      default:
        return 'Only people you follow who follow you back can start a chat.';
    }
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Text(
        label,
        style: const TextStyle(
          color: NiptoColors.muted,
          fontSize: 11,
          fontWeight: FontWeight.w900,
          letterSpacing: 1.4,
        ),
      ),
    );
  }
}
