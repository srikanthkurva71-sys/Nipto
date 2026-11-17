import 'package:flutter/material.dart';

import '../services/nipto_session_manager.dart';
import '../theme/nipto_theme.dart';

class SessionManagementScreen extends StatefulWidget {
  const SessionManagementScreen({super.key});

  @override
  State<SessionManagementScreen> createState() => _SessionManagementScreenState();
}

class _SessionManagementScreenState extends State<SessionManagementScreen> {
  late Future<List<Map<String, dynamic>>> _sessions;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _sessions = NiptoSessionManager.instance.listSessions();
  }

  Future<void> _refresh() async {
    setState(() => _sessions = NiptoSessionManager.instance.listSessions());
    await _sessions;
  }

  Future<void> _revoke(Map<String, dynamic> session) async {
    final id = session['session_id'] as String?;
    if (id == null || _busy) return;
    final isCurrent = id == NiptoSessionManager.instance.currentSession?.sessionId;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(isCurrent ? 'Sign out this device?' : 'Sign out this device remotely?'),
        content: Text(
          isCurrent
              ? 'You will need your Nipto ID and password to sign in again.'
              : 'This device will lose access when its current short-lived access token expires.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _busy = true);
    try {
      await NiptoSessionManager.instance.revokeSession(id);
      if (!mounted) return;
      if (isCurrent) {
        Navigator.of(context).popUntil((route) => route.isFirst);
        return;
      }
      setState(() => _sessions = NiptoSessionManager.instance.listSessions());
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Session revoked.')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not revoke that session.')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _dateLabel(dynamic value) {
    if (value is! String) return 'Unknown';
    final parsed = DateTime.tryParse(value)?.toLocal();
    if (parsed == null) return 'Unknown';
    final local = parsed.toString();
    return local.length >= 16 ? local.substring(0, 16) : local;
  }

  @override
  Widget build(BuildContext context) {
    final currentId = NiptoSessionManager.instance.currentSession?.sessionId;
    return Scaffold(
      appBar: AppBar(title: const Text('Devices and sessions')),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: FutureBuilder<List<Map<String, dynamic>>>(
          future: _sessions,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return ListView(
                children: [
                  const SizedBox(height: 100),
                  const Center(child: Text('Sessions could not be loaded.')),
                  Center(
                    child: TextButton(
                      onPressed: _refresh,
                      child: const Text('Retry'),
                    ),
                  ),
                ],
              );
            }
            final sessions = snapshot.data ?? [];
            if (sessions.isEmpty) {
              return ListView(
                children: const [
                  SizedBox(height: 100),
                  Icon(Icons.devices_outlined, size: 48, color: NiptoColors.muted),
                  SizedBox(height: 12),
                  Center(child: Text('No active sessions found.')),
                ],
              );
            }
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  'These are the devices currently signed in to your Nipto account. Revoke any session you do not recognize.',
                  style: TextStyle(color: NiptoColors.muted, height: 1.45),
                ),
                const SizedBox(height: 14),
                ...sessions.map((session) {
                  final id = session['session_id'] as String?;
                  final isCurrent = id != null && id == currentId;
                  final label = session['device_label'] as String? ?? 'Nipto device';
                  return Card(
                    child: ListTile(
                      leading: Icon(
                        isCurrent ? Icons.phone_android_rounded : Icons.devices_other_rounded,
                        color: isCurrent ? NiptoColors.violet : NiptoColors.muted,
                      ),
                      title: Text(isCurrent ? '$label · This device' : label),
                      subtitle: Text(
                        'Last active: ${_dateLabel(session['last_used_at'])}\n'
                        'Signed in: ${_dateLabel(session['created_at'])}',
                      ),
                      isThreeLine: true,
                      trailing: TextButton(
                        onPressed: _busy ? null : () => _revoke(session),
                        child: const Text('Revoke'),
                      ),
                    ),
                  );
                }),
              ],
            );
          },
        ),
      ),
    );
  }
}
