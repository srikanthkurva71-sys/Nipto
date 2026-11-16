import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:video_player/video_player.dart';

import '../theme/nipto_theme.dart';

class ShortsScreen extends StatefulWidget {
  const ShortsScreen({super.key});

  @override
  State<ShortsScreen> createState() => _ShortsScreenState();
}

class _ShortsScreenState extends State<ShortsScreen> {
  late Future<List<Map<String, dynamic>>> _clips;

  @override
  void initState() {
    super.initState();
    _clips = _loadClips();
  }

  Future<List<Map<String, dynamic>>> _loadClips() async {
    final client = Supabase.instance.client;
    final rows = await client
        .from('shorts')
        .select('id, creator_id, video_path, thumbnail_path, caption, duration_seconds')
        .eq('moderation_state', 'approved')
        .order('created_at', ascending: false)
        .limit(30);

    final clips = <Map<String, dynamic>>[];
    for (final raw in rows as List) {
      final clip = Map<String, dynamic>.from(raw);
      final url = await client.storage
          .from('shorts')
          .createSignedUrl(clip['video_path'] as String, 3600);
      clip['signed_url'] = url;
      clips.add(clip);
    }
    return clips;
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
          return const _ShortsEmpty(
            icon: Icons.play_circle_outline_rounded,
            title: 'A new kind of feed',
            subtitle: 'Short videos from people you follow will appear here.',
          );
        }
        return PageView.builder(
          scrollDirection: Axis.vertical,
          itemCount: clips.length,
          itemBuilder: (context, index) {
            return _ShortTile(clip: clips[index]);
          },
        );
      },
    );
  }
}

class _ShortTile extends StatefulWidget {
  const _ShortTile({required this.clip});

  final Map<String, dynamic> clip;

  @override
  State<_ShortTile> createState() => _ShortTileState();
}

class _ShortTileState extends State<_ShortTile> with WidgetsBindingObserver {
  VideoPlayerController? _controller;
  bool _ready = false;
  bool _failed = false;
  bool _liked = false;
  bool _likeBusy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeVideo();
  }

  Future<void> _initializeVideo() async {
    try {
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(widget.clip['signed_url'] as String),
      );
      _controller = controller;
      await controller.initialize();
      await controller.setLooping(true);
      await controller.play();
      if (mounted) setState(() => _ready = true);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _controller?.pause();
    } else if (_ready) {
      _controller?.play();
    }
  }

  Future<void> _toggleLike() async {
    if (_likeBusy) return;
    final client = Supabase.instance.client;
    final userId = client.auth.currentUser?.id;
    if (userId == null) return;
    setState(() => _likeBusy = true);
    try {
      if (_liked) {
        await client.from('short_likes').delete().match({
          'short_id': widget.clip['id'],
          'user_id': userId,
        });
      } else {
        await client.from('short_likes').insert({
          'short_id': widget.clip['id'],
          'user_id': userId,
        });
      }
      if (mounted) setState(() => _liked = !_liked);
    } catch (_) {
      if (mounted) {
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
    return Stack(
      fit: StackFit.expand,
      children: [
        Container(color: const Color(0xFF171827)),
        if (_ready && _controller != null)
          Center(
            child: AspectRatio(
              aspectRatio: _controller!.value.aspectRatio,
              child: VideoPlayer(_controller!),
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
                    const Text(
                      'NIPTO SHORTS',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 10,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 2,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      caption.isEmpty ? 'A little moment, shared.' : caption,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              Column(
                children: [
                  _ActionIcon(
                    icon: _liked ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                    label: 'Like',
                    color: _liked ? NiptoColors.coral : Colors.white,
                    onTap: _toggleLike,
                  ),
                  const SizedBox(height: 17),
                  _ActionIcon(
                    icon: Icons.mode_comment_outlined,
                    label: 'Comment',
                    onTap: () => ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Comments are coming in the next Shorts update.')),
                    ),
                  ),
                  const SizedBox(height: 17),
                  _ActionIcon(
                    icon: Icons.share_outlined,
                    label: 'Share',
                    onTap: () => ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Sharing will be enabled with the creator tools.')),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        Positioned(
          top: 18,
          left: 20,
          child: SafeArea(
            child: Text(
              'Shorts',
              style: const TextStyle(color: Colors.white, fontSize: 23, fontWeight: FontWeight.w800),
            ),
          ),
        ),
      ],
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
  final VoidCallback onTap;
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
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onRetry;

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
              OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
            ],
          ],
        ),
      ),
    );
  }
}
