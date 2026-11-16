import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../theme/nipto_theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool? _isPrivate;
  bool _savingPrivacy = false;

  SupabaseClient get _client => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _loadPrivacy();
  }

  Future<void> _loadPrivacy() async {
    try {
      final id = _client.auth.currentUser!.id;
      final result = await _client.from('profiles').select('is_private').eq('id', id).single();
      if (mounted) setState(() => _isPrivate = result['is_private'] as bool);
    } catch (_) {
      if (mounted) setState(() => _isPrivate = false);
    }
  }

  Future<void> _setPrivate(bool value) async {
    setState(() => _savingPrivacy = true);
    try {
      await _client.from('profiles').update({'is_private': value}).eq('id', _client.auth.currentUser!.id);
      if (mounted) setState(() => _isPrivate = value);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Privacy setting could not be saved.')),
      );
    } finally {
      if (mounted) setState(() => _savingPrivacy = false);
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
    await _client.auth.signOut();
    if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(18),
        children: [
          const _SectionLabel('PRIVACY'),
          Card(
            child: SwitchListTile(
              value: _isPrivate ?? false,
              onChanged: _isPrivate == null || _savingPrivacy ? null : _setPrivate,
              title: const Text('Private account'),
              subtitle: const Text('Approve follow requests before people can see follower-only updates.'),
              activeThumbColor: NiptoColors.violet,
            ),
          ),
          const SizedBox(height: 20),
          const _SectionLabel('SECURITY'),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.lock_reset_rounded),
                  title: const Text('Password and recovery'),
                  subtitle: const Text('Manage access through your verified recovery email.'),
                  onTap: () => ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Use Forgot password on the sign-in screen to reset your password.')),
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.devices_rounded),
                  title: const Text('Active sessions'),
                  subtitle: const Text('Session controls are being added.'),
                  onTap: () {},
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.block_rounded),
                  title: const Text('Blocked accounts'),
                  subtitle: const Text('Manage blocked people.'),
                  onTap: () => ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Blocked-account management is in the next settings update.')),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          const _SectionLabel('NOTIFICATIONS'),
          Card(
            child: ListTile(
              leading: const Icon(Icons.notifications_outlined),
              title: const Text('Notification preferences'),
              subtitle: const Text('Choose which updates Nipto can send.'),
              onTap: () => ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Push notification preferences are being added.')),
              ),
            ),
          ),
          const SizedBox(height: 20),
          const _SectionLabel('ACCOUNT'),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.help_outline_rounded),
                  title: const Text('Help and safety'),
                  subtitle: const Text('Community rules, reporting and support.'),
                  onTap: () {},
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.info_outline_rounded),
                  title: const Text('About Nipto'),
                  subtitle: const Text('Nipto Social · Android'),
                  onTap: () {},
                ),
              ],
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
            'Nipto is built to help people connect respectfully. Blocking, reporting and safe defaults are part of the product, not optional extras.',
            textAlign: TextAlign.center,
            style: TextStyle(color: NiptoColors.muted, fontSize: 12, height: 1.5),
          ),
        ],
      ),
    );
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
