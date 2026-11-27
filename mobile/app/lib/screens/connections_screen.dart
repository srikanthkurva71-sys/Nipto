import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/nipto_session_manager.dart';

import '../theme/nipto_theme.dart';

class ConnectionsScreen extends StatefulWidget {
  const ConnectionsScreen({super.key, required this.direction});

  final String direction;

  @override
  State<ConnectionsScreen> createState() => _ConnectionsScreenState();
}

class _ConnectionsScreenState extends State<ConnectionsScreen> {
  late Future<List<Map<String, dynamic>>> _connections;
  bool _busy = false;

  SupabaseClient get _client => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _connections = _load();
  }

  Future<List<Map<String, dynamic>>> _load() async {
    final rows = await _client.rpc(
      'list_my_connections',
      params: {'p_direction': widget.direction},
    );
    return (rows as List).map((row) => Map<String, dynamic>.from(row)).toList();
  }

  Future<void> _refresh() async {
    setState(() => _connections = _load());
    await _connections;
  }

  Future<void> _unfollow(Map<String, dynamic> profile) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _client.from('follows').delete().match({
        'follower_id': NiptoSessionManager.instance.userId!,
        'following_id': profile['user_id'],
      });
      if (mounted) {
        final handle = profile['nipto_id'] as String? ?? 'this account';
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Unfollowed @$handle.')));
        await _refresh();
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not update following list.')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _initials(String value) {
    final parts = value.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return 'N';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1))
        .toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final isFollowers = widget.direction == 'followers';
    return Scaffold(
      appBar: AppBar(title: Text(isFollowers ? 'Followers' : 'Following')),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: FutureBuilder<List<Map<String, dynamic>>>(
          future: _connections,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return ListView(
                children: [
                  const SizedBox(height: 120),
                  const Center(child: Text('This list could not load.')),
                  Center(
                    child: TextButton(
                      onPressed: _refresh,
                      child: const Text('Retry'),
                    ),
                  ),
                ],
              );
            }
            final people = snapshot.data ?? [];
            if (people.isEmpty) {
              return ListView(
                children: [
                  const SizedBox(height: 120),
                  Icon(
                    isFollowers
                        ? Icons.people_outline_rounded
                        : Icons.person_add_alt_1_rounded,
                    size: 44,
                    color: NiptoColors.violet,
                  ),
                  const SizedBox(height: 12),
                  Center(
                    child: Text(
                      isFollowers
                          ? 'No followers yet.'
                          : 'You are not following anyone yet.',
                    ),
                  ),
                ],
              );
            }
            return ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              itemCount: people.length,
              separatorBuilder: (_, __) => const Divider(height: 1, indent: 60),
              itemBuilder: (context, index) {
                final profile = people[index];
                final name =
                    profile['display_name'] as String? ?? 'Nipto member';
                final handle = profile['nipto_id'] as String? ?? '';
                return ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    vertical: 5,
                    horizontal: 2,
                  ),
                  leading: CircleAvatar(
                    backgroundColor: NiptoColors.violetSoft,
                    child: Text(
                      _initials(name),
                      style: const TextStyle(
                        color: NiptoColors.violet,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  title: Text(
                    name,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  subtitle: Text(
                    '@$handle',
                    style: const TextStyle(color: NiptoColors.muted),
                  ),
                  trailing: isFollowers
                      ? const Icon(
                          Icons.person_outline_rounded,
                          color: NiptoColors.muted,
                        )
                      : TextButton(
                          onPressed: _busy ? null : () => _unfollow(profile),
                          child: const Text('Following'),
                        ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
