import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../theme/nipto_theme.dart';
import 'settings_screen.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late Future<_ProfileData> _profile;

  SupabaseClient get _client => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _profile = _loadProfile();
  }

  Future<_ProfileData> _loadProfile() async {
    final userId = _client.auth.currentUser!.id;
    final raw = await _client.from('profiles').select().eq('id', userId).single();
    final profile = Map<String, dynamic>.from(raw);

    final followers = await _client
        .from('follows')
        .select('follower_id')
        .eq('following_id', userId)
        .eq('status', 'accepted');
    final following = await _client
        .from('follows')
        .select('following_id')
        .eq('follower_id', userId)
        .eq('status', 'accepted');
    final posts = await _client
        .from('posts')
        .select('id, media_path, media_type, caption, moderation_state')
        .eq('author_id', userId)
        .order('created_at', ascending: false)
        .limit(30);

    String? avatarUrl;
    final avatarPath = profile['avatar_path'] as String?;
    if (avatarPath != null && avatarPath.isNotEmpty) {
      avatarUrl = await _client.storage.from('avatars').createSignedUrl(avatarPath, 1800);
    }

    return _ProfileData(
      profile: profile,
      followers: (followers as List).length,
      following: (following as List).length,
      posts: (posts as List).map((row) => Map<String, dynamic>.from(row)).toList(),
      avatarUrl: avatarUrl,
    );
  }

  Future<void> _editProfile(_ProfileData data) async {
    final nameController = TextEditingController(text: data.profile['display_name'] as String? ?? '');
    final bioController = TextEditingController(text: data.profile['bio'] as String? ?? '');
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit profile'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              maxLength: 50,
              decoration: const InputDecoration(labelText: 'Display name'),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: bioController,
              maxLength: 160,
              maxLines: 3,
              decoration: const InputDecoration(labelText: 'Bio'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(context, {
              'display_name': nameController.text.trim(),
              'bio': bioController.text.trim(),
            }),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    nameController.dispose();
    bioController.dispose();
    if (result == null || !mounted) return;
    if (result['display_name']!.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Display name cannot be empty.')),
      );
      return;
    }

    try {
      await _client.from('profiles').update(result).eq('id', _client.auth.currentUser!.id);
      if (mounted) setState(() => _profile = _loadProfile());
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not update your profile.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: FutureBuilder<_ProfileData>(
        future: _profile,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError || !snapshot.hasData) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Profile could not load.'),
                  TextButton(
                    onPressed: () => setState(() => _profile = _loadProfile()),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            );
          }

          final data = snapshot.data!;
          final profile = data.profile;
          final displayName = profile['display_name'] as String? ?? 'Nipto user';
          final handle = profile['nipto_id'] as String? ?? '';
          final bio = profile['bio'] as String? ?? '';

          return CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 14, 12, 20),
                sliver: SliverToBoxAdapter(
                  child: Row(
                    children: [
                      Text('Your space', style: Theme.of(context).textTheme.headlineSmall),
                      const Spacer(),
                      IconButton(
                        tooltip: 'Settings',
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(builder: (_) => const SettingsScreen()),
                        ).then((_) {
                          if (mounted) setState(() => _profile = _loadProfile());
                        }),
                        icon: const Icon(Icons.settings_outlined),
                      ),
                    ],
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                sliver: SliverToBoxAdapter(
                  child: Column(
                    children: [
                      CircleAvatar(
                        radius: 48,
                        backgroundColor: NiptoColors.violetSoft,
                        backgroundImage: data.avatarUrl == null ? null : NetworkImage(data.avatarUrl!),
                        child: data.avatarUrl == null
                            ? Text(
                                displayName.isEmpty ? 'N' : displayName.substring(0, 1).toUpperCase(),
                                style: const TextStyle(color: NiptoColors.violet, fontSize: 28, fontWeight: FontWeight.w800),
                              )
                            : null,
                      ),
                      const SizedBox(height: 14),
                      Text(displayName, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
                      const SizedBox(height: 3),
                      Text('@' + handle, style: const TextStyle(color: NiptoColors.muted)),
                      if (bio.isNotEmpty) ...[
                        const SizedBox(height: 10),
                        Text(bio, textAlign: TextAlign.center, style: const TextStyle(height: 1.4)),
                      ],
                      const SizedBox(height: 20),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _Count(label: 'Followers', count: data.followers),
                          const SizedBox(width: 42),
                          _Count(label: 'Following', count: data.following),
                          const SizedBox(width: 42),
                          _Count(label: 'Posts', count: data.posts.length),
                        ],
                      ),
                      const SizedBox(height: 20),
                      OutlinedButton.icon(
                        onPressed: () => _editProfile(data),
                        icon: const Icon(Icons.edit_outlined, size: 18),
                        label: const Text('Edit profile'),
                        style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(46)),
                      ),
                    ],
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 28, 20, 10),
                sliver: SliverToBoxAdapter(
                  child: Row(
                    children: [
                      Text('Your posts', style: Theme.of(context).textTheme.titleLarge),
                      const Spacer(),
                      Text(
                        data.posts.length.toString(),
                        style: const TextStyle(color: NiptoColors.muted, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ),
              if (data.posts.isEmpty)
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(34),
                    child: Text(
                      'Your shared moments will appear here.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: NiptoColors.muted),
                    ),
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  sliver: SliverGrid(
                    delegate: SliverChildBuilderDelegate(
                      (context, index) {
                        final post = data.posts[index];
                        return Container(
                          decoration: BoxDecoration(
                            color: NiptoColors.violetSoft,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Center(
                            child: Icon(
                              post['media_type'] == 'video'
                                  ? Icons.play_circle_outline_rounded
                                  : Icons.image_outlined,
                              size: 34,
                              color: NiptoColors.violet,
                            ),
                          ),
                        );
                      },
                      childCount: data.posts.length,
                    ),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      crossAxisSpacing: 7,
                      mainAxisSpacing: 7,
                    ),
                  ),
                ),
              const SliverToBoxAdapter(child: SizedBox(height: 28)),
            ],
          );
        },
      ),
    );
  }
}

class _ProfileData {
  const _ProfileData({
    required this.profile,
    required this.followers,
    required this.following,
    required this.posts,
    required this.avatarUrl,
  });

  final Map<String, dynamic> profile;
  final int followers;
  final int following;
  final List<Map<String, dynamic>> posts;
  final String? avatarUrl;
}

class _Count extends StatelessWidget {
  const _Count({required this.label, required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          count.toString(),
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 2),
        Text(label, style: const TextStyle(color: NiptoColors.muted, fontSize: 12)),
      ],
    );
  }
}
