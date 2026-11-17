import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/nipto_session_manager.dart';

import '../theme/nipto_theme.dart';

class HomeFeedScreen extends StatefulWidget {
  const HomeFeedScreen({super.key});
  @override
  State<HomeFeedScreen> createState() => _HomeFeedScreenState();
}

class _HomeFeedScreenState extends State<HomeFeedScreen> {
  List<Map<String, dynamic>> _posts = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _error;
  final ScrollController _scroll = ScrollController();
  final Set<String> _busyLikes = {};
  SupabaseClient get _client => Supabase.instance.client;

  @override
  void initState() { super.initState(); _loadFeed(); _scroll.addListener(_onScroll); }
  @override
  void dispose() { _scroll.removeListener(_onScroll); _scroll.dispose(); super.dispose(); }

  void _onScroll() {
    if (_scroll.hasClients && !_loadingMore && _hasMore && _scroll.position.extentAfter < 700) _loadMore();
  }

  Future<List<Map<String, dynamic>>> _fetchPage({DateTime? before}) async {
    final rows = await _client.rpc('get_home_feed', params: {
      'p_limit': 20,
      'p_before': before?.toUtc().toIso8601String(),
    });
    return (rows as List).map((row) => Map<String, dynamic>.from(row)).toList();
  }

  Future<void> _loadFeed() async {
    setState(() { _loading = true; _error = null; });
    try {
      final rows = await _fetchPage();
      if (!mounted) return;
      setState(() { _posts = rows; _hasMore = rows.length == 20; _loading = false; });
    } catch (_) {
      if (mounted) setState(() { _error = 'Your feed could not load. Please try again.'; _loading = false; });
    }
  }

  Future<void> _loadMore() async {
    if (_posts.isEmpty || _loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final before = DateTime.tryParse(_posts.last['created_at'] as String? ?? '');
      final rows = await _fetchPage(before: before);
      if (mounted) setState(() { _posts.addAll(rows); _hasMore = rows.length == 20; });
    } catch (_) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not load more posts.')));
    } finally { if (mounted) setState(() => _loadingMore = false); }
  }

  Future<void> _toggleLike(Map<String, dynamic> post) async {
    final id = post['id'] as String;
    if (_busyLikes.contains(id)) return;
    final userId = NiptoSessionManager.instance.userId;
    if (userId == null) return;
    final liked = post['viewer_liked'] == true;
    setState(() {
      _busyLikes.add(id);
      post['viewer_liked'] = !liked;
      final count = (post['like_count'] as num?)?.toInt() ?? 0;
      post['like_count'] = (count + (liked ? -1 : 1)).clamp(0, 1 << 30);
    });
    try {
      if (liked) {
        await _client.from('post_likes').delete().match({'post_id': id, 'user_id': userId});
      } else {
        await _client.from('post_likes').insert({'post_id': id, 'user_id': userId});
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          post['viewer_liked'] = liked;
          final count = (post['like_count'] as num).toInt();
          post['like_count'] = (count + (liked ? 1 : -1)).clamp(0, 1 << 30);
        });
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Your reaction could not be saved.')));
      }
    } finally { if (mounted) setState(() => _busyLikes.remove(id)); }
  }

  Future<void> _showComments(Map<String, dynamic> post) async {
    await showModalBottomSheet<void>(
      context: context, isScrollControlled: true, showDragHandle: true,
      builder: (_) => _PostCommentsSheet(postId: post['id'] as String),
    );
    if (!mounted) return;
    final index = _posts.indexWhere((p) => p['id'] == post['id']);
    if (index < 0) return;
    try {
      final rows = await _client.from('post_comments').select('id').eq('post_id', post['id']);
      if (mounted) setState(() => _posts[index]['comment_count'] = (rows as List).length);
    } catch (_) {}
  }

  String _timeAgo(String? raw) {
    final created = DateTime.tryParse(raw ?? '')?.toLocal();
    if (created == null) return '';
    final elapsed = DateTime.now().difference(created);
    if (elapsed.inMinutes < 1) return 'now';
    if (elapsed.inHours < 1) return '${elapsed.inMinutes}m';
    if (elapsed.inDays < 1) return '${elapsed.inHours}h';
    if (elapsed.inDays < 7) return '${elapsed.inDays}d';
    return '${created.day}/${created.month}';
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: RefreshIndicator(
        onRefresh: _loadFeed,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? ListView(children: [
                    const SizedBox(height: 140),
                    const Icon(Icons.cloud_off_rounded, size: 42, color: NiptoColors.muted),
                    const SizedBox(height: 12),
                    Center(child: Text(_error!)),
                    Center(child: TextButton(onPressed: _loadFeed, child: const Text('Try again'))),
                  ])
                : CustomScrollView(
                    controller: _scroll,
                    physics: const AlwaysScrollableScrollPhysics(),
                    slivers: [
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                        sliver: SliverToBoxAdapter(
                          child: Row(children: [
                            const Text('nipto', style: TextStyle(color: NiptoColors.ink, fontSize: 29, fontWeight: FontWeight.w900, letterSpacing: -1.5)),
                            const Spacer(),
                            DecoratedBox(
                              decoration: BoxDecoration(gradient: NiptoBrand.markGradient, borderRadius: BorderRadius.circular(11)),
                              child: const SizedBox(width: 34, height: 34, child: Icon(Icons.bubble_chart_rounded, color: Colors.white)),
                            ),
                          ]),
                        ),
                      ),
                      if (_posts.isEmpty)
                        const SliverFillRemaining(
                          hasScrollBody: false,
                          child: Center(child: Padding(
                            padding: EdgeInsets.all(30),
                            child: Column(mainAxisSize: MainAxisSize.min, children: [
                              Icon(Icons.auto_awesome_rounded, color: NiptoColors.violet, size: 42),
                              SizedBox(height: 12),
                              Text('Your Nipto feed starts here', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
                              SizedBox(height: 8),
                              Text('Follow people to see their approved photos and posts here.', textAlign: TextAlign.center, style: TextStyle(color: NiptoColors.muted, height: 1.4)),
                            ]),
                          )),
                        )
                      else
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                          sliver: SliverList.separated(
                            itemCount: _posts.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 14),
                            itemBuilder: (context, index) {
                              final post = _posts[index];
                              return _FeedPostCard(
                                key: ValueKey<String>(post['id'] as String),
                                post: post,
                                timeAgo: _timeAgo(post['created_at'] as String?),
                                onLike: () => _toggleLike(post),
                                onComments: () => _showComments(post),
                              );
                            },
                          ),
                        ),
                      if (_loadingMore) const SliverToBoxAdapter(child: Padding(padding: EdgeInsets.all(18), child: Center(child: CircularProgressIndicator()))),
                      const SliverToBoxAdapter(child: SizedBox(height: 18)),
                    ],
                  ),
      ),
    );
  }
}

class _FeedPostCard extends StatefulWidget {
  const _FeedPostCard({super.key, required this.post, required this.timeAgo, required this.onLike, required this.onComments});
  final Map<String, dynamic> post;
  final String timeAgo;
  final VoidCallback onLike;
  final VoidCallback onComments;
  @override
  State<_FeedPostCard> createState() => _FeedPostCardState();
}

class _FeedPostCardState extends State<_FeedPostCard> {
  late Future<String> _url;
  late Future<String?> _avatarUrl;
  @override
  void initState() {
    super.initState();
    final client = Supabase.instance.client;
    _url = client.storage.from('posts').createSignedUrl(widget.post['media_path'] as String, 1800);
    final avatar = widget.post['author_avatar_path'] as String?;
    _avatarUrl = avatar == null ? Future.value(null) : client.storage.from('avatars').createSignedUrl(avatar, 1800);
  }
  @override
  Widget build(BuildContext context) {
    final name = widget.post['author_display_name'] as String? ?? 'Nipto member';
    final handle = widget.post['author_nipto_id'] as String? ?? '';
    final caption = widget.post['caption'] as String? ?? '';
    final liked = widget.post['viewer_liked'] == true;
    final likes = (widget.post['like_count'] as num?)?.toInt() ?? 0;
    final comments = (widget.post['comment_count'] as num?)?.toInt() ?? 0;
    return Card(clipBehavior: Clip.antiAlias, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(13, 12, 13, 10),
        child: Row(children: [
          FutureBuilder<String?>(
            future: _avatarUrl,
            builder: (context, snapshot) => CircleAvatar(
              radius: 19, backgroundColor: NiptoColors.violetSoft,
              backgroundImage: snapshot.data == null ? null : NetworkImage(snapshot.data!),
              child: snapshot.data == null ? const Icon(Icons.person_outline_rounded, color: NiptoColors.violet, size: 20) : null,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, style: const TextStyle(fontWeight: FontWeight.w800)),
            Text('@$handle · ${widget.timeAgo}', style: const TextStyle(color: NiptoColors.muted, fontSize: 11)),
          ])),
          const Icon(Icons.more_horiz_rounded, color: NiptoColors.muted),
        ]),
      ),
      FutureBuilder<String>(
        future: _url,
        builder: (context, snapshot) {
          if (snapshot.hasError) return Container(height: 250, color: NiptoColors.violetSoft, child: const Center(child: Icon(Icons.broken_image_outlined, color: NiptoColors.violet)));
          if (!snapshot.hasData) return Container(height: 250, color: NiptoColors.violetSoft, child: const Center(child: CircularProgressIndicator(strokeWidth: 2)));
          if (widget.post['media_type'] == 'video') {
            return _FeedVideoPlayer(url: snapshot.data!);
          }
          return Image.network(
            snapshot.data!,
            width: double.infinity,
            height: 330,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => Container(
              height: 250,
              color: NiptoColors.violetSoft,
              child: const Center(
                child: Icon(Icons.broken_image_outlined, color: NiptoColors.violet),
              ),
            ),
          );
        },
      ),
      if (caption.isNotEmpty) Padding(padding: const EdgeInsets.fromLTRB(14, 12, 14, 0), child: Text(caption, style: const TextStyle(height: 1.4))),
      Padding(
        padding: const EdgeInsets.fromLTRB(5, 4, 8, 8),
        child: Row(children: [
          IconButton(tooltip: liked ? 'Unlike' : 'Like', onPressed: widget.onLike, icon: Icon(liked ? Icons.favorite_rounded : Icons.favorite_border_rounded, color: liked ? NiptoColors.coral : NiptoColors.ink)),
          Text(likes.toString(), style: const TextStyle(fontSize: 12, color: NiptoColors.muted)),
          const SizedBox(width: 10),
          IconButton(tooltip: 'Comments', onPressed: widget.onComments, icon: const Icon(Icons.mode_comment_outlined)),
          Text(comments.toString(), style: const TextStyle(fontSize: 12, color: NiptoColors.muted)),
          const Spacer(),
          IconButton(
            tooltip: 'Copy post ID',
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: widget.post['id'] as String));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Post ID copied.')),
                );
              }
            },
            icon: const Icon(Icons.link_rounded),
          ),
          const SizedBox(width: 8),
        ]),
      ),
    ]));
  }
}

class _PostCommentsSheet extends StatefulWidget {
  const _PostCommentsSheet({required this.postId});
  final String postId;
  @override
  State<_PostCommentsSheet> createState() => _PostCommentsSheetState();
}

class _PostCommentsSheetState extends State<_PostCommentsSheet> {
  final _text = TextEditingController();
  late Future<List<Map<String, dynamic>>> _comments;
  bool _sending = false;
  SupabaseClient get _client => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _comments = _load();
  }

  Future<List<Map<String, dynamic>>> _load() async {
    final rows = await _client
        .from('post_comments')
        .select('id, author_id, body, created_at')
        .eq('post_id', widget.postId)
        .order('created_at')
        .limit(100);
    return (rows as List)
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
  }

  Future<void> _send() async {
    final body = _text.text.trim();
    final userId = NiptoSessionManager.instance.userId;
    if (body.isEmpty || _sending || userId == null) return;
    setState(() => _sending = true);
    try {
      await _client.from('post_comments').insert({
        'post_id': widget.postId,
        'author_id': userId,
        'body': body,
      });
      _text.clear();
      if (mounted) {
        setState(() => _comments = _load());
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

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }
  @override
  Widget build(BuildContext context) {
    return SafeArea(child: Padding(
      padding: EdgeInsets.fromLTRB(18, 8, 18, MediaQuery.viewInsetsOf(context).bottom + 12),
      child: SizedBox(height: MediaQuery.sizeOf(context).height * 0.62, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Comments', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
        const SizedBox(height: 12),
        Expanded(child: FutureBuilder<List<Map<String, dynamic>>>(
          future: _comments,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
            if (snapshot.hasError) return const Center(child: Text('Comments could not load.'));
            final rows = snapshot.data ?? [];
            if (rows.isEmpty) return const Center(child: Text('Be the first to comment.', style: TextStyle(color: NiptoColors.muted)));
            return ListView.separated(itemCount: rows.length, separatorBuilder: (_, __) => const Divider(height: 1), itemBuilder: (context, index) => ListTile(contentPadding: EdgeInsets.zero, leading: const CircleAvatar(backgroundColor: NiptoColors.violetSoft, child: Icon(Icons.person_outline_rounded, color: NiptoColors.violet)), title: Text(rows[index]['author_id'] == NiptoSessionManager.instance.userId ? 'You' : 'Nipto member'), subtitle: Text(rows[index]['body'] as String)));
          },
        )),
        Row(children: [
          Expanded(child: TextField(controller: _text, maxLength: 2000, maxLines: 2, decoration: const InputDecoration(hintText: 'Write a comment…', counterText: ''))),
          const SizedBox(width: 8),
          IconButton.filled(onPressed: _sending ? null : _send, icon: _sending ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.arrow_upward_rounded)),
        ]),
      ])),
    ));
  }
}

class _FeedVideoPlayer extends StatefulWidget {
  const _FeedVideoPlayer({required this.url});

  final String url;

  @override
  State<_FeedVideoPlayer> createState() => _FeedVideoPlayerState();
}

class _FeedVideoPlayerState extends State<_FeedVideoPlayer>
    with WidgetsBindingObserver {
  VideoPlayerController? _controller;
  bool _loading = true;
  bool _failed = false;
  bool _playing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      final controller = VideoPlayerController.networkUrl(Uri.parse(widget.url));
      _controller = controller;
      await controller.initialize();
      await controller.setLooping(false);
      if (mounted) setState(() => _loading = false);
    } catch (_) {
      if (mounted) setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  Future<void> _togglePlayback() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    try {
      if (controller.value.isPlaying) {
        await controller.pause();
      } else {
        if (controller.value.position >= controller.value.duration) {
          await controller.seekTo(Duration.zero);
        }
        await controller.play();
      }
      if (mounted) setState(() => _playing = controller.value.isPlaying);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Video playback failed.')),
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && _controller?.value.isPlaying == true) {
      _controller?.pause();
      if (mounted) setState(() => _playing = false);
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
    final controller = _controller;
    return GestureDetector(
      onTap: _togglePlayback,
      child: Container(
        height: 330,
        width: double.infinity,
        color: const Color(0xFF101C50),
        child: _loading
            ? const Center(child: CircularProgressIndicator(color: Colors.white))
            : _failed || controller == null
                ? const Center(
                    child: Icon(Icons.videocam_off_rounded, color: Colors.white70, size: 40),
                  )
                : Stack(
                    alignment: Alignment.center,
                    children: [
                      Center(
                        child: AspectRatio(
                          aspectRatio: controller.value.aspectRatio,
                          child: VideoPlayer(controller),
                        ),
                      ),
                      if (!_playing)
                        const CircleAvatar(
                          radius: 30,
                          backgroundColor: Color(0x99000000),
                          child: Icon(Icons.play_arrow_rounded, color: Colors.white, size: 38),
                        ),
                      Positioned(
                        left: 12,
                        right: 12,
                        bottom: 10,
                        child: VideoProgressIndicator(
                          controller,
                          allowScrubbing: true,
                          colors: const VideoProgressColors(
                            playedColor: NiptoColors.coral,
                            bufferedColor: Colors.white54,
                            backgroundColor: Colors.white24,
                          ),
                        ),
                      ),
                    ],
                  ),
      ),
    );
  }
}
