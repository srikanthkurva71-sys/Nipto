import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/nipto_session_manager.dart';

import '../theme/nipto_theme.dart';
import 'feedback_screen.dart';
import 'close_friends_screen.dart';
import 'staff_console_screen.dart';
import 'recovery_contacts_screen.dart';

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

  SupabaseClient get _client => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _blocked = _loadBlocked();
    _staffAccess = _loadStaffAccess();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final userId = NiptoSessionManager.instance.userId;
    if (userId == null) return;
    try {
      await _client.from('user_preferences').upsert(
        {'user_id': userId},
        onConflict: 'user_id',
        ignoreDuplicates: true,
      );
      final results = await Future.wait([
        _client.from('profiles').select('is_private').eq('id', userId).single(),
        _client.from('user_preferences')
            .select('message_access, message_notifications, follow_notifications, status_notifications, short_notifications')
            .eq('user_id', userId)
            .single(),
      ]);
      if (!mounted) return;
      final profile = results[0];
      final preferences = results[1];
      setState(() {
        _isPrivate = profile['is_private'] as bool? ?? false;
        _messageAccess = preferences['message_access'] as String? ?? 'mutuals';
        _messageNotifications = preferences['message_notifications'] as bool? ?? true;
        _followNotifications = preferences['follow_notifications'] as bool? ?? true;
        _statusNotifications = preferences['status_notifications'] as bool? ?? true;
        _shortNotifications = preferences['short_notifications'] as bool? ?? true;
      });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Some settings could not be loaded. Pull down to retry.')),
        );
      }
    }
  }

  Future<void> _setPrivate(bool value) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _isPrivate = value;
    });
    try {
      await _client.from('profiles').update({'is_private': value}).eq('id', NiptoSessionManager.instance.userId!);
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
      await _client.from('user_preferences').update({key: value}).eq(
        'user_id',
        NiptoSessionManager.instance.userId!,
      );
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
          '@' + handle + ' will be able to find your account again, subject to your privacy settings.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Unblock')),
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

  Future<void> _signOut() async {
    final shouldSignOut = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign out of Nipto?'),
        content: const Text('You can sign back in with your Nipto ID and password.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Sign out')),
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
        const SnackBar(content: Text('Could not revoke other sessions. Please try again.')),
      );
    }
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
                    onChanged: _isPrivate == null || _saving ? null : _setPrivate,
                    title: const Text('Private account'),
                    subtitle: const Text('Approve follow requests before people can see follower-only updates.'),
                    activeThumbColor: NiptoColors.violet,
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.people_alt_outlined, color: NiptoColors.violet),
                    title: const Text('Close Friends'),
                    subtitle: const Text('Choose who can see Close Friends-only statuses.'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(builder: (_) => const CloseFriendsScreen()),
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
                        DropdownMenuItem(value: 'mutuals', child: Text('Mutuals')),
                        DropdownMenuItem(value: 'followers', child: Text('Followers')),
                        DropdownMenuItem(value: 'nobody', child: Text('Nobody')),
                      ],
                      onChanged: _saving ? null : (value) {
                        if (value != null) _updatePreference('message_access', value);
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
                        onPressed: () => setState(() => _blocked = _loadBlocked()),
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
                      final name = profile['display_name'] as String? ?? 'Nipto member';
                      final handle = profile['nipto_id'] as String? ?? '';
                      return ListTile(
                        leading: const CircleAvatar(
                          backgroundColor: NiptoColors.violetSoft,
                          child: Icon(Icons.person_outline_rounded, color: NiptoColors.violet),
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
                    onChanged: _saving ? null : (value) => _updatePreference('message_notifications', value),
                    title: const Text('Messages'),
                    activeThumbColor: NiptoColors.violet,
                  ),
                  const Divider(height: 1),
                  SwitchListTile(
                    value: _followNotifications,
                    onChanged: _saving ? null : (value) => _updatePreference('follow_notifications', value),
                    title: const Text('Follows and requests'),
                    activeThumbColor: NiptoColors.violet,
                  ),
                  const Divider(height: 1),
                  SwitchListTile(
                    value: _statusNotifications,
                    onChanged: _saving ? null : (value) => _updatePreference('status_notifications', value),
                    title: const Text('Status updates'),
                    activeThumbColor: NiptoColors.violet,
                  ),
                  const Divider(height: 1),
                  SwitchListTile(
                    value: _shortNotifications,
                    onChanged: _saving ? null : (value) => _updatePreference('short_notifications', value),
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
                    leading: const Icon(Icons.shield_outlined, color: NiptoColors.violet),
                    title: const Text('Recovery Nipto account'),
                    subtitle: const Text('Add and manage a trusted Nipto account for recovery assistance.'),
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
                    subtitle: const Text('Use the private account email registered with Supabase Auth to reset your password.'),
                    onTap: () => ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Use Forgot password on the sign-in screen to reset your password.')),
                    ),
                  ),
                  const Divider(height: 1),
                  const ListTile(
                    leading: Icon(Icons.verified_user_outlined),
                    title: Text('Secure sign-in'),
                    subtitle: Text('Nipto uses Supabase Auth sessions and server-verified passwords.'),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.devices_outlined),
                    title: const Text('Sign out on all devices'),
                    subtitle: const Text('Revoke refresh sessions on other devices.'),
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
                        leading: const Icon(Icons.admin_panel_settings_outlined, color: NiptoColors.violet),
                        title: const Text('Staff review'),
                        subtitle: const Text('Review feedback, reports and pending content.'),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(builder: (_) => const StaffConsoleScreen()),
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
                    leading: const Icon(Icons.feedback_outlined, color: NiptoColors.violet),
                    title: const Text('Feedback & support'),
                    subtitle: const Text('Report a problem, suggest a feature or rate your experience.'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(builder: (_) => const FeedbackScreen()),
                    ),
                  ),
                ],
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
              style: TextStyle(color: NiptoColors.muted, fontSize: 12, height: 1.5),
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
