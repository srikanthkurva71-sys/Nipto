import 'dart:async';

import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../theme/nipto_theme.dart';
import 'status_screen.dart';
import 'conversation_screen.dart';

class ChatsScreen extends StatefulWidget {
  const ChatsScreen({super.key});

  @override
  State<ChatsScreen> createState() => _ChatsScreenState();
}

class _ChatsScreenState extends State<ChatsScreen> {
  final _searchController = TextEditingController();
  List<Map<String, dynamic>> _searchResults = [];
  bool _searching = false;
  bool _loadingSearch = false;
  String? _searchError;
  Timer? _searchDebounce;
  int _searchVersion = 0;
  late Future<List<_ChatPreview>> _inbox;

  SupabaseClient get _client => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _inbox = _loadInbox();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<List<_ChatPreview>> _loadInbox() async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) return [];

    final memberships = await _client
        .from('conversation_members')
        .select('conversation_id')
        .eq('user_id', userId)
        .eq('membership_state', 'accepted');

    final ids = (memberships as List)
        .map((row) => row['conversation_id'] as String)
        .toList();
    if (ids.isEmpty) return [];

    final conversations = await _client
        .from('conversations')
        .select('id, conversation_type, title, direct_user_a, direct_user_b, updated_at')
        .inFilter('id', ids)
        .order('updated_at', ascending: false)
        .limit(60);

    final partnerIds = <String>{};
    for (final row in conversations as List) {
      if (row['conversation_type'] == 'direct') {
        final a = row['direct_user_a'] as String?;
        final b = row['direct_user_b'] as String?;
        final partner = a == userId ? b : a;
        if (partner != null) partnerIds.add(partner);
      }
    }

    final profilesById = <String, Map<String, dynamic>>{};
    if (partnerIds.isNotEmpty) {
      final profiles = await _client
          .from('profiles')
          .select('id, nipto_id, display_name, avatar_path')
          .inFilter('id', partnerIds.toList());
      for (final profile in profiles as List) {
        profilesById[profile['id'] as String] = Map<String, dynamic>.from(profile);
      }
    }

    final latestMessages = await _client
        .from('messages')
        .select('conversation_id, body, message_type, sender_id, created_at, deleted_at')
        .inFilter('conversation_id', ids)
        .order('created_at', ascending: false)
        .limit(ids.length * 4);

    final lastByConversation = <String, Map<String, dynamic>>{};
    for (final message in latestMessages as List) {
      final conversationId = message['conversation_id'] as String;
      lastByConversation.putIfAbsent(
        conversationId,
        () => Map<String, dynamic>.from(message),
      );
    }

    return (conversations as List).map((raw) {
      final row = Map<String, dynamic>.from(raw);
      final isDirect = row['conversation_type'] == 'direct';
      final a = row['direct_user_a'] as String?;
      final b = row['direct_user_b'] as String?;
      final partnerId = a == userId ? b : a;
      final profile = partnerId == null ? null : profilesById[partnerId];
      return _ChatPreview(
        id: row['id'] as String,
        title: isDirect
            ? (profile?['display_name'] as String? ?? 'Nipto user')
            : (row['title'] as String? ?? 'Group chat'),
        subtitle: isDirect
            ? '@' + (profile?['nipto_id'] as String? ?? 'member')
            : 'Group conversation',
        message: lastByConversation[row['id']]?['deleted_at'] != null
            ? 'Message deleted'
            : (lastByConversation[row['id']]?['body'] as String? ?? 'Start a conversation'),
        initials: _initials(
          isDirect
              ? (profile?['display_name'] as String? ?? 'N')
              : (row['title'] as String? ?? 'Nipto'),
        ),
        updatedAt: DateTime.tryParse(row['updated_at'] as String? ?? ''),
      );
    }).toList();
  }

  String _initials(String value) {
    final parts = value.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return 'N';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.characters.first + parts.last.substring(0, 1)).toUpperCase();
  }

  void _scheduleSearch(String value) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () => _search(value));
  }

  Future<void> _search(String value) async {
    final version = ++_searchVersion;
    final query = value.trim().replaceFirst('@', '').toLowerCase();
    if (query.length < 2) {
      setState(() {
        _searchResults = [];
        _searchError = null;
        _loadingSearch = false;
      });
      return;
    }

    setState(() {
      _loadingSearch = true;
      _searchError = null;
    });
    try {
      final result = await _client.rpc(
        'search_profiles',
        params: {'p_query': query, 'p_limit': 20},
      );
      if (!mounted || version != _searchVersion) return;
      setState(() {
        _searchResults = (result as List)
            .map((row) => Map<String, dynamic>.from(row))
            .toList();
      });
    } catch (_) {
      if (!mounted || version != _searchVersion) return;
      setState(() => _searchError = 'Search is unavailable. Please try again.');
    } finally {
      if (mounted && version == _searchVersion) setState(() => _loadingSearch = false);
    }
  }

  Future<void> _follow(Map<String, dynamic> profile) async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) return;
    try {
      await _client.from('follows').insert({
        'follower_id': userId,
        'following_id': profile['id'],
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            profile['is_private'] == true ? 'Follow request sent.' : 'You are now following @' + (profile['nipto_id'] as String),
          ),
        ),
      );
      await _search(_searchController.text);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not follow this account.')),
      );
    }
  }

  Future<void> _startChat(Map<String, dynamic> profile) async {
    try {
      final conversationId = await _client.rpc(
        'create_or_get_direct_conversation',
        params: {'p_other_user': profile['id']},
      );
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ConversationScreen(
            conversationId: conversationId as String,
            title: profile['display_name'] as String? ?? 'Nipto user',
            subtitle: '@' + (profile['nipto_id'] as String? ?? ''),
          ),
        ),
      );
      if (mounted) setState(() => _inbox = _loadInbox());
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('This conversation cannot be started.')),
      );
    }
  }

  String _timeLabel(DateTime? value) {
    if (value == null) return '';
    final now = DateTime.now();
    if (now.difference(value).inDays == 0) {
      final hour = value.hour % 12 == 0 ? 12 : value.hour % 12;
      final minute = value.minute.toString().padLeft(2, '0');
      return hour.toString() + ':' + minute;
    }
    if (now.difference(value).inDays < 7) {
      const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
      return days[value.weekday - 1];
    }
    return value.day.toString() + '/' + value.month.toString();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: RefreshIndicator(
        onRefresh: () async => setState(() => _inbox = _loadInbox()),
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 17, 20, 8),
              sliver: SliverToBoxAdapter(
                child: Row(
                  children: [
                    const Text(
                      'nipto',
                      style: TextStyle(
                        fontSize: 29,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -1.5,
                        color: NiptoColors.ink,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      tooltip: 'Notifications',
                      onPressed: () {},
                      icon: const Icon(Icons.notifications_none_rounded),
                    ),
                    IconButton(
                      tooltip: 'New chat',
                      onPressed: () => setState(() => _searching = true),
                      icon: const Icon(Icons.edit_square),
                    ),
                  ],
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
              sliver: SliverToBoxAdapter(
                child: TextField(
                  controller: _searchController,
                  onTap: () => setState(() => _searching = true),
                  onChanged: _scheduleSearch,
                  decoration: InputDecoration(
                    hintText: 'Search by Nipto ID',
                    prefixIcon: const Icon(Icons.search_rounded),
                    suffixIcon: _searching
                        ? IconButton(
                            tooltip: 'Clear search',
                            onPressed: () {
                              _searchDebounce?.cancel();
                              _searchVersion++;
                              _searchController.clear();
                              setState(() {
                                _searching = false;
                                _searchResults = [];
                              });
                            },
                            icon: const Icon(Icons.close_rounded),
                          )
                        : null,
                  ),
                ),
              ),
            ),
            if (_searching)
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                sliver: SliverToBoxAdapter(
                  child: _buildSearchResults(),
                ),
              )
            else ...[
              SliverToBoxAdapter(child: _buildStatusTray()),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 7),
                sliver: SliverToBoxAdapter(
                  child: Row(
                    children: [
                      Text('Messages', style: Theme.of(context).textTheme.titleLarge),
                      const Spacer(),
                      TextButton(
                        onPressed: () => setState(() => _searching = true),
                        child: const Text('Find people'),
                      ),
                    ],
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                sliver: FutureBuilder<List<_ChatPreview>>(
                  future: _inbox,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.all(36),
                          child: Center(child: CircularProgressIndicator()),
                        ),
                      );
                    }
                    if (snapshot.hasError) {
                      return SliverToBoxAdapter(
                        child: _EmptyPanel(
                          title: 'Could not load chats',
                          subtitle: 'Check your connection and pull down to retry.',
                          icon: Icons.cloud_off_rounded,
                        ),
                      );
                    }
                    final chats = snapshot.data ?? [];
                    if (chats.isEmpty) {
                      return const SliverToBoxAdapter(
                        child: _EmptyPanel(
                          title: 'Your conversations start here',
                          subtitle: 'Search for a Nipto ID to follow someone or start a chat.',
                          icon: Icons.forum_outlined,
                        ),
                      );
                    }
                    return SliverList.separated(
                      itemCount: chats.length,
                      separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
                      itemBuilder: (context, index) {
                        final chat = chats[index];
                        return ListTile(
                          contentPadding: const EdgeInsets.symmetric(vertical: 7, horizontal: 2),
                          leading: CircleAvatar(
                            radius: 25,
                            backgroundColor: NiptoColors.violetSoft,
                            child: Text(
                              chat.initials,
                              style: const TextStyle(color: NiptoColors.violet, fontWeight: FontWeight.w800),
                            ),
                          ),
                          title: Text(chat.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                            chat.message.isEmpty ? chat.subtitle : chat.message,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          trailing: Text(
                            _timeLabel(chat.updatedAt),
                            style: const TextStyle(color: NiptoColors.muted, fontSize: 11),
                          ),
                          onTap: () async {
                            await Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => ConversationScreen(
                                  conversationId: chat.id,
                                  title: chat.title,
                                  subtitle: chat.subtitle,
                                ),
                              ),
                            );
                            if (mounted) setState(() => _inbox = _loadInbox());
                          },
                        );
                      },
                    );
                  },
                ),
              ),
            ],
            const SliverToBoxAdapter(child: SizedBox(height: 22)),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusTray() => const StatusTray();

  Widget _buildSearchResults() {
    if (_loadingSearch) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_searchError != null) return Text(_searchError!);
    if (_searchController.text.trim().length < 2) {
      return const Padding(
        padding: EdgeInsets.only(top: 12),
        child: Text(
          'Enter at least 2 characters to find people.',
          style: TextStyle(color: NiptoColors.muted),
        ),
      );
    }
    if (_searchResults.isEmpty) {
      return const Padding(
        padding: EdgeInsets.only(top: 24),
        child: _EmptyPanel(
          title: 'No people found',
          subtitle: 'Check the spelling or try another Nipto ID.',
          icon: Icons.person_search_rounded,
        ),
      );
    }
    return Column(
      children: _searchResults.map((profile) {
        final name = profile['display_name'] as String? ?? 'Nipto user';
        final handle = profile['nipto_id'] as String? ?? '';
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: NiptoColors.violetSoft,
                child: Text(_initials(name), style: const TextStyle(color: NiptoColors.violet)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, style: const TextStyle(fontWeight: FontWeight.w700)),
                    Text('@' + handle, style: const TextStyle(color: NiptoColors.muted, fontSize: 12)),
                  ],
                ),
              ),
              IconButton(
                tooltip: 'Message',
                onPressed: () => _startChat(profile),
                icon: const Icon(Icons.chat_bubble_outline_rounded, color: NiptoColors.violet),
              ),
              OutlinedButton(
                onPressed: () => _follow(profile),
                child: Text(profile['is_private'] == true ? 'Request' : 'Follow'),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  String _initials(String value) {
    final parts = value.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return 'N';
    if (parts.length == 1) return parts.first.characters.first.toUpperCase();
    return (parts.first.characters.first + parts.last.characters.first).toUpperCase();
  }
}

class _ChatPreview {
  const _ChatPreview({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.message,
    required this.initials,
    required this.updatedAt,
  });

  final String id;
  final String title;
  final String subtitle;
  final String message;
  final String initials;
  final DateTime? updatedAt;
}

class _StatusAvatar extends StatelessWidget {
  const _StatusAvatar({
    required this.label,
    required this.initials,
    required this.onTap,
  });

  final String label;
  final String initials;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 17),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: onTap,
        child: SizedBox(
          width: 66,
          child: Column(
            children: [
              Container(
                width: 58,
                height: 58,
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: NiptoColors.coral, width: 2),
                ),
                child: CircleAvatar(
                  backgroundColor: NiptoColors.violetSoft,
                  child: Text(
                    initials,
                    style: const TextStyle(color: NiptoColors.violet, fontWeight: FontWeight.w800, fontSize: 19),
                  ),
                ),
              ),
              const SizedBox(height: 7),
              Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyPanel extends StatelessWidget {
  const _EmptyPanel({
    required this.title,
    required this.subtitle,
    required this.icon,
  });

  final String title;
  final String subtitle;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 30, horizontal: 12),
      child: Column(
        children: [
          Icon(icon, size: 34, color: NiptoColors.violet),
          const SizedBox(height: 12),
          Text(title, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
          const SizedBox(height: 6),
          Text(subtitle, textAlign: TextAlign.center, style: const TextStyle(color: NiptoColors.muted, height: 1.4)),
        ],
      ),
    );
  }
}
