import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/nipto_session_manager.dart';

import '../theme/nipto_theme.dart';
import 'settings_screen.dart';
import 'connections_screen.dart';
import 'notifications_screen.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key, this.unreadCount = 0});

  final int unreadCount;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late Future<_ProfileData> _profile;
  final _picker = ImagePicker();
  bool _uploadingPost = false;

  SupabaseClient get _client => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _profile = _loadProfile();
  }

  Future<_ProfileData> _loadProfile() async {
    final userId = NiptoSessionManager.instance.userId!;
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

  Future<void> _createPost() async {
    if (_uploadingPost) return;
    final file = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 88,
      maxWidth: 1800,
    );
    if (file == null || !mounted) return;

    final extension = file.name.split('.').last.toLowerCase();
    const mimeTypes = {
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'png': 'image/png',
      'webp': 'image/webp',
    };
    final contentType = mimeTypes[extension];
    if (contentType == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Choose a JPG, PNG or WebP image.')),
      );
      return;
    }

    final size = await file.length();
    if (size > 20 * 1024 * 1024) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Choose an image smaller than 20 MB.')),
      );
      return;
    }

    var visibility = 'followers';
    final captionController = TextEditingController();
    final caption = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
        title: const Text('Add a caption'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: captionController,
              maxLength: 2200,
              maxLines: 4,
              decoration: const InputDecoration(hintText: 'Write something about this photo…'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: visibility,
              decoration: const InputDecoration(labelText: 'Who can see this post'),
              items: const [
                DropdownMenuItem(value: 'followers', child: Text('Followers')),
                DropdownMenuItem(value: 'public', child: Text('Everyone')),
              ],
              onChanged: (value) {
                if (value != null) setDialogState(() => visibility = value);
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, captionController.text.trim()),
            child: const Text('Continue'),
          ),
        ],
        ),
      ),
    );
    captionController.dispose();
    if (caption == null || !mounted) return;

    final userId = NiptoSessionManager.instance.userId;
    if (userId == null) return;
    final path = userId + '/' + DateTime.now().microsecondsSinceEpoch.toString() + '.' + extension;

    setState(() => _uploadingPost = true);
    var uploaded = false;
    try {
      await _client.storage.from('posts').upload(
        path,
        File(file.path),
        fileOptions: FileOptions(contentType: contentType, upsert: false),
      );
      uploaded = true;

      await _client.from('posts').insert({
        'author_id': userId,
        'caption': caption,
        'media_path': path,
        'media_type': 'image',
        'visibility': visibility,
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Photo submitted. It will appear to followers after review.')),
      );
      setState(() => _profile = _loadProfile());
    } catch (_) {
      if (uploaded) {
        try {
          await _client.storage.from('posts').remove([path]);
        } catch (_) {
          // Any failed cleanup remains private and inaccessible to other users.
        }
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Photo could not be shared. Please try again.')),
      );
    } finally {
      if (mounted) setState(() => _uploadingPost = false);
    }
  }

  Future<void> _changeAvatar() async {
    final file = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 88,
      maxWidth: 1200,
    );
    if (file == null || !mounted) return;

    final extension = file.name.split('.').last.toLowerCase();
    const mimeTypes = {
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'png': 'image/png',
      'webp': 'image/webp',
    };
    final contentType = mimeTypes[extension];
    if (contentType == null || await file.length() > 8 * 1024 * 1024) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Choose a JPG, PNG or WebP image smaller than 8 MB.')),
      );
      return;
    }

    final userId = NiptoSessionManager.instance.userId;
    if (userId == null) return;
    final path = userId + '/avatar.' + extension;
    try {
      await _client.storage.from('avatars').upload(
        path,
        File(file.path),
        fileOptions: FileOptions(contentType: contentType, upsert: true),
      );
      await _client.from('profiles').update({'avatar_path': path}).eq('id', userId);
      if (mounted) setState(() => _profile = _loadProfile());
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Profile photo could not be updated.')),
      );
    }
  }

  Future<void> _editProfile(_ProfileData data) async {
    final nameController = TextEditingController(
      text: data.profile['display_name'] as String? ?? '',
    );
    final bioController = TextEditingController(
      text: data.profile['bio'] as String? ?? '',
    );
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
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
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
      await _client.from('profiles').update(result).eq(
        'id',
        NiptoSessionManager.instance.userId!,
      );
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
                        tooltip: 'Notifications',
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(builder: (_) => const NotificationsScreen()),
                        ),
                        icon: widget.unreadCount > 0
                            ? Badge(
                                label: Text(widget.unreadCount > 99 ? '99+' : widget.unreadCount.toString()),
                                child: const Icon(Icons.notifications_none_rounded),
                              )
                            : const Icon(Icons.notifications_none_rounded),
                      ),
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
                      GestureDetector(
                        onTap: _changeAvatar,
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            CircleAvatar(
                              radius: 48,
                              backgroundColor: NiptoColors.violetSoft,
                              backgroundImage: data.avatarUrl == null
                                  ? null
                                  : NetworkImage(data.avatarUrl!),
                              child: data.avatarUrl == null
                                  ? Text(
                                      displayName.isEmpty
                                          ? 'N'
                                          : displayName.substring(0, 1).toUpperCase(),
                                      style: const TextStyle(
                                        color: NiptoColors.violet,
                                        fontSize: 28,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    )
                                  : null,
                            ),
                            Positioned(
                              right: -2,
                              bottom: -2,
                              child: Container(
                                width: 30,
                                height: 30,
                                decoration: BoxDecoration(
                                  color: NiptoColors.violet,
                                  shape: BoxShape.circle,
                                  border: Border.all(color: Colors.white, width: 2),
                                ),
                                child: const Icon(
                                  Icons.camera_alt_rounded,
                                  color: Colors.white,
                                  size: 15,
                                ),
                              ),
                            ),
                          ],
                        ),
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
                          _Count(
                            label: 'Followers',
                            count: data.followers,
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => const ConnectionsScreen(direction: 'followers'),
                              ),
                            ),
                          ),
                          const SizedBox(width: 42),
                          _Count(
                            label: 'Following',
                            count: data.following,
                            onTap: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => const ConnectionsScreen(direction: 'following'),
                              ),
                            ),
                          ),
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
                      const SizedBox(height: 10),
                      FilledButton.tonalIcon(
                        onPressed: _uploadingPost ? null : _createPost,
                        icon: _uploadingPost
                            ? const SizedBox(
                                width: 17,
                                height: 17,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.add_photo_alternate_outlined, size: 18),
                        label: Text(_uploadingPost ? 'Uploading photo…' : 'Share a photo'),
                        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
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
                        return _ProfilePostTile(post: post);
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
  const _Count({required this.label, required this.count, this.onTap});

  final String label;
  final int count;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Column(
          children: [
            Text(
              count.toString(),
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 2),
            Text(label, style: const TextStyle(color: NiptoColors.muted, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}


class _ProfilePostTile extends StatefulWidget {
  const _ProfilePostTile({required this.post});

  final Map<String, dynamic> post;

  @override
  State<_ProfilePostTile> createState() => _ProfilePostTileState();
}

class _ProfilePostTileState extends State<_ProfilePostTile> {
  late Future<String> _signedUrl;

  @override
  void initState() {
    super.initState();
    _signedUrl = _load();
  }

  Future<String> _load() {
    return Supabase.instance.client.storage
        .from('posts')
        .createSignedUrl(widget.post['media_path'] as String, 1800);
  }

  @override
  Widget build(BuildContext context) {
    final pending = widget.post['moderation_state'] == 'pending';
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Stack(
        fit: StackFit.expand,
        children: [
          FutureBuilder<String>(
            future: _signedUrl,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return Container(
                  color: NiptoColors.violetSoft,
                  child: const Center(
                    child: Icon(Icons.broken_image_outlined, color: NiptoColors.violet, size: 30),
                  ),
                );
              }
              if (!snapshot.hasData) {
                return Container(
                  color: NiptoColors.violetSoft,
                  child: const Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                );
              }
              return Image.network(
                snapshot.data!,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => Container(
                  color: NiptoColors.violetSoft,
                  child: const Center(
                    child: Icon(Icons.broken_image_outlined, color: NiptoColors.violet),
                  ),
                ),
              );
            },
          ),
          if (pending)
            Positioned(
              left: 4,
              right: 4,
              bottom: 4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text(
                  'In review',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w700),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
