import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../theme/nipto_theme.dart';

class CloseFriendsScreen extends StatefulWidget {
  const CloseFriendsScreen({super.key});

  @override
  State<CloseFriendsScreen> createState() => _CloseFriendsScreenState();
}

class _CloseFriendsScreenState extends State<CloseFriendsScreen> {
  late Future<List<Map<String, dynamic>>> _people;
  final Set<String> _busy = {};

  SupabaseClient get _client => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _people = _load();
  }

  Future<List<Map<String, dynamic>>> _load() async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) return [];
    final results = await Future.wait([
      _client.rpc('list_my_connections', params: {'p_direction': 'following'}),
      _client.from('close_friends').select('friend_id').eq('owner_id', userId),
    ]);
    final selected = (results[1] as List)
        .map((row) => (row as Map<String, dynamic>)['friend_id'] as String)
        .toSet();
    return (results[0] as List).map((raw) {
      final person = Map<String, dynamic>.from(raw as Map);
      person['is_close_friend'] = selected.contains(person['user_id']);
      return person;
    }).toList();
  }

  Future<void> _toggle(Map<String, dynamic> person) async {
    final userId = _client.auth.currentUser?.id;
    final friendId = person['user_id'] as String;
    if (userId == null || !_busy.add(friendId)) return;
    setState(() {});
    final wasSelected = person['is_close_friend'] == true;
    try {
      if (wasSelected) {
        await _client.from('close_friends').delete().match({
          'owner_id': userId,
          'friend_id': friendId,
        });
      } else {
        await _client.from('close_friends').insert({
          'owner_id': userId,
          'friend_id': friendId,
        });
      }
      if (!mounted) return;
      setState(() => person['is_close_friend'] = !wasSelected);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not update your Close Friends list. Please try again.')),
      );
    } finally {
      _busy.remove(friendId);
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Close Friends')),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _people,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Your following list could not be loaded.'),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: () => setState(() => _people = _load()),
                      child: const Text('Try again'),
                    ),
                  ],
                ),
              ),
            );
          }
          final people = snapshot.data ?? [];
          final selectedCount = people.where((person) => person['is_close_friend'] == true).length;
          if (people.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(28),
                child: Text('Follow people to add them to your Close Friends list.'),
              ),
            );
          }
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
                child: Text(
                  '${selectedCount} close ${selectedCount == 1 ? 'friend' : 'friends'} · Only you can see this list',
                  style: const TextStyle(color: NiptoColors.muted),
                ),
              ),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: () async {
                    final next = _load();
                    setState(() => _people = next);
                    await next;
                  },
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                    itemCount: people.length,
                    separatorBuilder: (_, __) => const Divider(height: 1, indent: 64),
                    itemBuilder: (context, index) {
                      final person = people[index];
                      final name = person['display_name'] as String? ?? 'Nipto member';
                      final handle = person['nipto_id'] as String? ?? '';
                      final id = person['user_id'] as String;
                      final selected = person['is_close_friend'] == true;
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: NiptoColors.violetSoft,
                          child: Text(
                            name.isEmpty ? 'N' : name.substring(0, 1).toUpperCase(),
                            style: const TextStyle(color: NiptoColors.violet, fontWeight: FontWeight.w800),
                          ),
                        ),
                        title: Text(name),
                        subtitle: Text('@$handle'),
                        trailing: _busy.contains(id)
                            ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                            : IconButton(
                                tooltip: selected ? 'Remove from Close Friends' : 'Add to Close Friends',
                                onPressed: () => _toggle(person),
                                icon: Icon(
                                  selected ? Icons.check_circle_rounded : Icons.add_circle_outline_rounded,
                                  color: selected ? NiptoColors.violet : NiptoColors.muted,
                                ),
                              ),
                      );
                    },
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
