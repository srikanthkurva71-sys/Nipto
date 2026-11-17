import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/nipto_session_manager.dart';
import 'package:video_player/video_player.dart';

import '../theme/nipto_theme.dart';

class ShortsScreen extends StatefulWidget {
  const ShortsScreen({super.key});

  @override
  State<ShortsScreen> createState() => _ShortsScreenState();
}

class _ShortsScreenState extends State<ShortsScreen> {
  late Future<List<Map<String, dynamic>>> _clips;
  final _picker = ImagePicker();
  bool _uploading = false;
  int _activeIndex = 0;

  SupabaseClient get _client => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _clips = _loadClips();
  }

  Future<List<Map<String, dynamic>>> _loadClips() async {
    final rows = await _client
        .from('shorts')
        .select('id, creator_id, video_path, thumbnail_path, caption, duration_seconds')
        .eq('moderation_state', 'approved')
        .order('created_at', ascending: false)
        .limit(30);

    final clips = <Map<String, dynamic>>[];
    for (final raw in rows as List) {
      final clip = Map<String, dynamic>.from(raw);
      final profile = await _client
          .from('profiles')
          .select('display_name, nipto_id, avatar_path')
          .eq('id', clip['creator_id'])
          .maybeSingle();
      clip['creator_name'] = profile?['display_name'] ?? 'Nipto creator';
      clip['creator_nipto_id'] = profile?['nipto_id'] ?? '';
      final url = await _client.storage
          .from('shorts')
          .createSignedUrl(clip['video_path'] as String, 3600);
      clip['signed_url'] = url;
      clips.add(clip);
    }
    return clips;
  }

  Future<void> _uploadShort() async {
    if (_uploading) return;
    final file = await _picker.pickVideo(
      source: ImageSource.gallery,
      maxDuration: const Duration(minutes: 3),
    );
    if (file == null || !mounted) return;

    final extension = file.name.split('.').last.toLowerCase();
    if (extension != 'mp4') {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('For now, Shorts uploads must be MP4 videos.')),
      );
      return;
    }

    final size = await file.length();
    if (size > 195 * 1024 * 1024) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Choose a video smaller than 195 MB.')),
      );
      return;
    }

    var visibility = 'followers';
    final captionController = TextEditingController();
    final caption = await showDialog<String>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: const Text('Caption your Short'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: captionController,
                maxLength: 2200,
                maxLines: 4,
                decoration: const InputDecoration(hintText: 'Add a caption…'),
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                value: visibility,
                decoration: const InputDecoration(labelText: 'Who can see this Short'),
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

    setState(() => _uploading = true);
    VideoPlayerController? preview;
    try {
      preview = VideoPlayerController.file(File(file.path));
      await preview.initialize();
      final duration = preview.value.duration.inMilliseconds / 1000.0;
      await preview.dispose();
      preview = null;
      if (duration <= 0 || duration > 180) {
        throw const FormatException('Short videos must be 3 minutes or less.');
      }

      final userId = NiptoSessionManager.instance.userId!;
      final path = userId + '/' + DateTime.now().microsecondsSinceEpoch.toString() + '.mp4';
      await _client.storage.from('shorts').upload(
        path,
        File(file.path),
        fileOptions: const FileOptions(contentType: 'video/mp4', upsert: false),
      );
      await _client.from('shorts').insert({
        'creator_id': userId,
        'video_path': path,
        'caption': caption,
        'duration_seconds': duration,
        'visibility': visibility,
      });

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Short submitted. It will appear after review.')),
      );
    } on FormatException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message)),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Short upload failed. Please try again.')),
      );
    } finally {
      await preview?.dispose();
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _showComments(Map<String, dynamic> clip) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _ShortCommentsSheet(shortId: clip['id'] as String),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: _clips,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return _ShortsEmpty(
            icon: Icons.cloud_off_rounded,
            title: 'Shorts could not load',
            subtitle: 'Check your connection and try again.',
            onRetry: () => setState(() => _clips = _loadClips()),
          );
        }
        final clips = snapshot.data ?? [];
        if (clips.isEmpty) {
          return _ShortsEmpty(
            icon: Icons.play_circle_outline_rounded,
            title: 'A new kind of feed',
            subtitle: 'Approved short videos from Nipto creators will appear here.',
            actionLabel: 'Share a Short',
            onRetry: _uploadShort,
          );
        }
        return Stack(
          children: [
            PageView.builder(
              scrollDirection: Axis.vertical,
              itemCount: clips.length,
              onPageChanged: (index) => setState(() => _activeIndex = index),
              itemBuilder: (context, index) => _ShortTile(
                key: ValueKey(clips[index]['id']),
                clip: clips[index],
                isActive: _activeIndex == index,
                onComment: () => _showComments(clips[index]),
              ),
            ),
            Positioned(
              top: 12,
              left: 20,
              right: 14,
              child: SafeArea(
                child: Row(
                  children: const [
                    Text(
                      'Shorts',
                      style: TextStyle(color: Colors.white, fontSize: 23, fontWeight: FontWeight.w800),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              top: 12,
              right: 12,
              child: SafeArea(
                child: IconButton.filledTonal(
                  tooltip: 'Upload a Short',
                  onPressed: _uploading ? null : _uploadShort,
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.black45,
                    foregroundColor: Colors.white,
                  ),
                  icon: _uploading
                      ? const SizedBox(
                          width: 19,
                          height: 19,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.add_rounded),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _ShortTile extends StatefulWidget {
  const _ShortTile({
    super.key,
    required this.clip,
    required this.isActive,
    required this.onComment,
  });

  final Map<String, dynamic> clip;
  final bool isActive;
  final VoidCallback onComment;

  @override
  State<_ShortTile> createState() => _ShortTileState();
}

class _ShortTileState extends State<_ShortTile> with WidgetsBindingObserver {
  VideoPlayerController? _controller;
  bool _ready = false;
  bool _failed = false;
  bool _liked = false;
  bool _likeBusy = false;
  int _likeCount = 0;

  SupabaseClient get _client => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeVideo();
    _loadLikeState();
  }

  @override
  void didUpdateWidget(covariant _ShortTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActive != widget.isActive && _ready) {
      if (widget.isActive) {
        _controller?.play();
      } else {
        _controller?.pause();
      }
    }
  }

  Future<void> _initializeVideo() async {
    try {
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(widget.clip['signed_url'] as String),
      );
      _controller = controller;
      await controller.initialize();
      await controller.setLooping(true);
      if (widget.isActive) await controller.play();
      if (mounted) setState(() => _ready = true);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  Future<void> _loadLikeState() async {
    final userId = NiptoSessionManager.instance.userId;
    if (userId == null) return;
    try {
      final rows = await _client
          .from('short_likes')
          .select('user_id')
          .eq('short_id', widget.clip['id']);
      if (!mounted) return;
      setState(() {
        _likeCount = (rows as List).length;
        _liked = rows.any((row) => row['user_id'] == userId);
      });
    } catch (_) {
      // The video remains playable when engagement metadata is unavailable.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _controller?.pause();
    } else if (_ready && widget.isActive) {
      _controller?.play();
    }
  }

  Future<void> _toggleLike() async {
    if (_likeBusy) return;
    final userId = NiptoSessionManager.instance.userId;
    if (userId == null) return;
    final next = !_liked;
    setState(() {
      _likeBusy = true;
      _liked = next;
      _likeCount = _likeCount + (next ? 1 : -1);
      if (_likeCount < 0) _likeCount = 0;
    });
    try {
      if (next) {
        await _client.from('short_likes').insert({
          'short_id': widget.clip['id'],
          'user_id': userId,
        });
      } else {
        await _client.from('short_likes').delete().match({
          'short_id': widget.clip['id'],
          'user_id': userId,
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _liked = !next;
          _likeCount = _likeCount + (next ? -1 : 1);
          if (_likeCount < 0) _likeCount = 0;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not update your reaction.')),
        );
      }
    } finally {
      if (mounted) setState(() => _likeBusy = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final caption = widget.clip['caption'] as String? ?? '';
    final creator = widget.clip['creator_name'] as String? ?? 'Nipto creator';
    final handle = widget.clip['creator_nipto_id'] as String? ?? '';

    return Stack(
      fit: StackFit.expand,
      children: [
        Container(color: const Color(0xFF171827)),
        if (_ready && _controller != null)
          GestureDetector(
            onTap: () {
              if (_controller!.value.isPlaying) {
                _controller!.pause();
              } else if (widget.isActive) {
                _controller!.play();
              }
              setState(() {});
            },
            child: Center(
              child: AspectRatio(
                aspectRatio: _controller!.value.aspectRatio,
                child: VideoPlayer(_controller!),
              ),
            ),
          )
        else
          Center(
            child: _failed
                ? const Icon(Icons.play_disabled_rounded, color: Colors.white54, size: 48)
                : const CircularProgressIndicator(color: Colors.white),
          ),
        Positioned(
          left: 18,
          right: 18,
          bottom: 28,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(creator, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15)),
                    if (handle.isNotEmpty)
                      Text('@' + handle, style: const TextStyle(color: Colors.white70, fontSize: 11)),
                    const SizedBox(height: 8),
                    Text(
                      caption.isEmpty ? 'A little moment, shared.' : caption,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              Column(
                children: [
                  _ActionIcon(
                    icon: _liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                    label: _likeCount == 0 ? 'Like' : _likeCount.toString(),
                    color: _liked ? NiptoColors.coral : Colors.white,
                    onTap: _likeBusy ? null : _toggleLike,
                  ),
                  const SizedBox(height: 17),
                  _ActionIcon(
                    icon: Icons.mode_comment_outlined,
                    label: 'Comment',
                    onTap: widget.onComment,
                  ),
                  const SizedBox(height: 17),
                  _ActionIcon(
                    icon: Icons.share_outlined,
                    label: 'Copy ID',
                    onTap: () async {
                      await Clipboard.setData(ClipboardData(text: widget.clip['id'] as String));
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Short ID copied.')),
                        );
                      }
                    },
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ShortCommentsSheet extends StatefulWidget {
  const _ShortCommentsSheet({required this.shortId});

  final String shortId;

  @override
  State<_ShortCommentsSheet> createState() => _ShortCommentsSheetState();
}

class _ShortCommentsSheetState extends State<_ShortCommentsSheet> {
  final _controller = TextEditingController();
  bool _sending = false;
  String? _editingCommentId;
  late Future<List<Map<String, dynamic>>> _comments;

  SupabaseClient get _client => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _comments = _loadComments();
  }

  Future<List<Map<String, dynamic>>> _loadComments() async {
    final rows = await _client
        .from('short_comments')
        .select('id, author_id, body, created_at')
        .eq('short_id', widget.shortId)
        .order('created_at')
        .limit(100);
    return (rows as List).map((row) => Map<String, dynamic>.from(row)).toList();
  }

  Future<void> _send() async {
    final body = _controller.text.trim();
    final userId = NiptoSessionManager.instance.userId;
    if (body.isEmpty || userId == null || _sending) return;
    setState(() => _sending = true);
    try {
      final editingId = _editingCommentId;
      if (editingId != null) {
        await _client.from('short_comments').update({'body': body})
            .eq('id', editingId).eq('author_id', userId);
      } else {
        await _client.from('short_comments').insert({
          'short_id': widget.shortId,
          'author_id': userId,
          'body': body,
        });
      }
      _controller.clear();
      if (mounted) {
        setState(() {
          _editingCommentId = null;
          _comments = _loadComments();
        });
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Comment could not be sent.')),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _editComment(Map<String, dynamic> comment) async {
    _controller.text = comment['body'] as String? ?? '';
    setState(() => _editingCommentId = comment['id'] as String);
  }

  Future<void> _deleteComment(String id) async {
    final userId = NiptoSessionManager.instance.userId;
    if (userId == null) return;
    try {
      await _client.from('short_comments').delete()
          .eq('id', id).eq('author_id', userId);
      if (!mounted) return;
      setState(() => _comments = _loadComments());
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Comment deleted.')),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Comment could not be deleted.')),
        );
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(18, 8, 18, MediaQuery.viewInsetsOf(context).bottom + 12),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.62,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Comments', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
              const SizedBox(height: 12),
              Expanded(
                child: FutureBuilder<List<Map<String, dynamic>>>(
                  future: _comments,
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final comments = snapshot.data!;
                    if (comments.isEmpty) {
                      return const Center(
                        child: Text('Be the first to comment.', style: TextStyle(color: NiptoColors.muted)),
                      );
                    }
                    return ListView.separated(
                      itemCount: comments.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final comment = comments[index];
                        final mine = comment['author_id'] == NiptoSessionManager.instance.userId;
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const CircleAvatar(
                            backgroundColor: NiptoColors.violetSoft,
                            child: Icon(Icons.person_outline_rounded, color: NiptoColors.violet),
                          ),
                          title: Text(mine ? 'You' : 'Nipto member'),
                          subtitle: Text(comment['body'] as String),
                          trailing: mine ? PopupMenuButton<String>(
                            tooltip: 'Comment options',
                            onSelected: (action) {
                              if (action == 'edit') _editComment(comment);
                              if (action == 'delete') _deleteComment(comment['id'] as String);
                            },
                            itemBuilder: (_) => const [
                              PopupMenuItem(value: 'edit', child: Text('Edit comment')),
                              PopupMenuItem(value: 'delete', child: Text('Delete comment')),
                            ],
                          ) : null,
                        );
                      },
                    );
                  },
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      maxLength: 2000,
                      maxLines: 2,
                      decoration: InputDecoration(
                        hintText: _editingCommentId == null ? 'Write a comment…' : 'Edit your comment…',
                        counterText: '',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _sending ? null : _send,
                    icon: _sending
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.arrow_upward_rounded),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionIcon extends StatelessWidget {
  const _ActionIcon({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color = Colors.white,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(24),
      child: SizedBox(
        width: 54,
        child: Column(
          children: [
            Icon(icon, color: color, size: 29),
            const SizedBox(height: 4),
            Text(label, style: const TextStyle(color: Colors.white, fontSize: 10)),
          ],
        ),
      ),
    );
  }
}

class _ShortsEmpty extends StatelessWidget {
  const _ShortsEmpty({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onRetry,
    this.actionLabel,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onRetry;
  final String? actionLabel;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF171827),
      padding: const EdgeInsets.all(32),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 52, color: NiptoColors.coral),
            const SizedBox(height: 18),
            Text(title, style: const TextStyle(color: Colors.white, fontSize: 21, fontWeight: FontWeight.w800)),
            const SizedBox(height: 9),
            Text(subtitle, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70, height: 1.4)),
            if (onRetry != null) ...[
              const SizedBox(height: 18),
              OutlinedButton(onPressed: onRetry, child: Text(actionLabel ?? 'Try again')),
            ],
          ],
        ),
      ),
    );
  }
}
