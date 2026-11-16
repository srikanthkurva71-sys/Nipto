import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:video_player/video_player.dart';

import '../theme/nipto_theme.dart';

class StatusTray extends StatefulWidget {
  const StatusTray({super.key});

  @override
  State<StatusTray> createState() => _StatusTrayState();
}

class _StatusTrayState extends State<StatusTray> {
  late Future<List<_StatusGroup>> _groups;
  final _picker = ImagePicker();
  bool _uploading = false;

  SupabaseClient get _client => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _groups = _loadGroups();
  }

  Future<List<_StatusGroup>> _loadGroups() async {
    final now = DateTime.now().toUtc().toIso8601String();
    final rows = await _client
        .from('statuses')
        .select('id, owner_id, status_type, text_content, media_path, background_color, visibility, expires_at, created_at')
        .gt('expires_at', now)
        .order('created_at', ascending: false)
        .limit(120)
        .order('created_at', ascending: false)
        .limit(120);

    final byOwner = <String, List<Map<String, dynamic>>>{};
    for (final raw in rows as List) {
      final row = Map<String, dynamic>.from(raw);
      final ownerId = row['owner_id'] as String;
      byOwner.putIfAbsent(ownerId, () => []).add(row);
    }

    if (byOwner.isEmpty) return [];
    final profiles = await _client
        .from('profiles')
        .select('id, nipto_id, display_name, avatar_path')
        .inFilter('id', byOwner.keys.toList());

    final profileById = <String, Map<String, dynamic>>{};
    for (final raw in profiles as List) {
      final profile = Map<String, dynamic>.from(raw);
      profileById[profile['id'] as String] = profile;
    }

    return byOwner.entries
        .where((entry) => profileById.containsKey(entry.key))
        .map((entry) {
          final profile = profileById[entry.key]!;
          return _StatusGroup(
            ownerId: entry.key,
            name: profile['display_name'] as String? ?? 'Nipto user',
            niptoId: profile['nipto_id'] as String? ?? '',
            avatarPath: profile['avatar_path'] as String?,
            statuses: entry.value,
          );
        })
        .toList();
  }

  Future<void> _showCreateOptions() async {
    if (_uploading) return;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Share a status', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              const Text('A status disappears after 24 hours.', style: TextStyle(color: NiptoColors.muted)),
              const SizedBox(height: 14),
              ListTile(
                leading: const Icon(Icons.text_fields_rounded, color: NiptoColors.violet),
                title: const Text('Text status'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _createTextStatus();
                },
              ),
              ListTile(
                leading: const Icon(Icons.photo_outlined, color: NiptoColors.violet),
                title: const Text('Photo status'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _pickMediaStatus(isVideo: false);
                },
              ),
              ListTile(
                leading: const Icon(Icons.videocam_outlined, color: NiptoColors.violet),
                title: const Text('Video status'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  _pickMediaStatus(isVideo: true);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _createTextStatus() async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Write a status'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 700,
          maxLines: 4,
          decoration: const InputDecoration(hintText: 'What’s on your mind?'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('Share'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (text == null || text.isEmpty || !mounted) return;
    try {
      final userId = _client.auth.currentUser!.id;
      await _client.from('statuses').insert({
        'owner_id': userId,
        'status_type': 'text',
        'text_content': text,
        'visibility': 'followers',
        'background_color': '#6657E8',
      });
      await _refresh();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Status could not be shared. Please try again.')),
      );
    }
  }

  Future<void> _pickMediaStatus({required bool isVideo}) async {
    final file = isVideo
        ? await _picker.pickVideo(source: ImageSource.gallery, maxDuration: const Duration(seconds: 60))
        : await _picker.pickImage(source: ImageSource.gallery, imageQuality: 88, maxWidth: 1800);
    if (file == null || !mounted) return;

    final extension = file.name.split('.').last.toLowerCase();
    const imageTypes = {
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'png': 'image/png',
      'webp': 'image/webp',
    };
    final contentType = isVideo ? 'video/mp4' : imageTypes[extension];
    if (contentType == null || (isVideo && extension != 'mp4')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Choose a supported JPG, PNG, WebP or MP4 file.')),
      );
      return;
    }

    final size = await file.length();
    if (size > 48 * 1024 * 1024) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Status media must be smaller than 48 MB.')),
      );
      return;
    }

    setState(() => _uploading = true);
    try {
      final userId = _client.auth.currentUser!.id;
      final path = userId + '/' + DateTime.now().microsecondsSinceEpoch.toString() + '.' + extension;
      await _client.storage.from('statuses').upload(
        path,
        File(file.path),
        fileOptions: FileOptions(contentType: contentType, upsert: false),
      );
      await _client.from('statuses').insert({
        'owner_id': userId,
        'status_type': isVideo ? 'video' : 'image',
        'media_path': path,
        'visibility': 'followers',
      });
      await _refresh();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Status shared with your followers.')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Upload failed. Check your connection and try again.')),
      );
    } finally {
      if (mounted) setState(() => _uploading = false);
    }
  }

  Future<void> _refresh() async {
    setState(() => _groups = _loadGroups());
  }

  String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return 'N';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1)).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 105,
      child: FutureBuilder<List<_StatusGroup>>(
        future: _groups,
        builder: (context, snapshot) {
          final groups = snapshot.data ?? [];
          return ListView(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            scrollDirection: Axis.horizontal,
            children: [
              _StatusAvatar(
                label: _uploading ? 'Uploading…' : 'Your status',
                initials: '+',
                isOwn: true,
                onTap: _showCreateOptions,
              ),
              ...groups.map((group) => _StatusAvatar(
                    label: group.ownerId == _client.auth.currentUser?.id ? 'Your update' : group.name,
                    initials: _initials(group.name),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => StatusViewerPage(group: group),
                      ),
                    ),
                  )),
              if (snapshot.hasError)
                const Padding(
                  padding: EdgeInsets.only(left: 8, top: 20),
                  child: Text('Statuses unavailable', style: TextStyle(color: NiptoColors.muted, fontSize: 11)),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _StatusGroup {
  const _StatusGroup({
    required this.ownerId,
    required this.name,
    required this.niptoId,
    required this.avatarPath,
    required this.statuses,
  });

  final String ownerId;
  final String name;
  final String niptoId;
  final String? avatarPath;
  final List<Map<String, dynamic>> statuses;
}

class _StatusAvatar extends StatelessWidget {
  const _StatusAvatar({
    required this.label,
    required this.initials,
    required this.onTap,
    this.isOwn = false,
  });

  final String label;
  final String initials;
  final VoidCallback onTap;
  final bool isOwn;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
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
                  border: Border.all(color: isOwn ? NiptoColors.border : NiptoColors.coral, width: 2),
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

class StatusViewerPage extends StatelessWidget {
  const StatusViewerPage({super.key, required this.group});

  final _StatusGroup group;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF171827),
      appBar: AppBar(
        backgroundColor: const Color(0xFF171827),
        foregroundColor: Colors.white,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(group.name, style: const TextStyle(color: Colors.white, fontSize: 16)),
            Text('@' + group.niptoId, style: const TextStyle(color: Colors.white60, fontSize: 11)),
          ],
        ),
      ),
      body: PageView.builder(
        itemCount: group.statuses.length,
        itemBuilder: (context, index) => _StatusPage(
          status: group.statuses[index],
          ownerId: group.ownerId,
        ),
      ),
    );
  }
}

class _StatusPage extends StatefulWidget {
  const _StatusPage({required this.status, required this.ownerId});

  final Map<String, dynamic> status;
  final String ownerId;

  @override
  State<_StatusPage> createState() => _StatusPageState();
}

class _StatusPageState extends State<_StatusPage> {
  String? _signedUrl;
  VideoPlayerController? _video;
  bool _failed = false;
  late Future<List<Map<String, dynamic>>> _viewers;

  @override
  void initState() {
    super.initState();
    _viewers = Supabase.instance.client.auth.currentUser?.id == widget.ownerId
        ? _loadViewers()
        : Future.value([]);
    _markViewed();
    _loadMedia();
  }

  Future<void> _markViewed() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null || userId == widget.ownerId) return;
    try {
      await Supabase.instance.client.from('status_views').insert({
        'status_id': widget.status['id'],
        'viewer_id': userId,
      });
    } catch (_) {
      // An existing view is expected when a user reopens a status.
    }
  }

  Future<void> _loadMedia() async {
    final type = widget.status['status_type'] as String;
    final path = widget.status['media_path'] as String?;
    if (type == 'text' || path == null) return;
    try {
      final url = await Supabase.instance.client.storage.from('statuses').createSignedUrl(path, 1800);
      if (!mounted) return;
      setState(() => _signedUrl = url);
      if (type == 'video') {
        final controller = VideoPlayerController.networkUrl(Uri.parse(url));
        _video = controller;
        await controller.initialize();
        await controller.setLooping(false);
        await controller.play();
        if (mounted) setState(() {});
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    _video?.dispose();
    super.dispose();
  }

  Color _background() {
    final raw = widget.status['background_color'] as String?;
    if (raw == null || !RegExp(r'^#[0-9A-Fa-f]{6}$').hasMatch(raw)) return NiptoColors.violet;
    return Color(int.parse(raw.substring(1), radix: 16) + 0xFF000000);
  }

  Future<List<Map<String, dynamic>>> _loadViewers() async {
    final rows = await Supabase.instance.client.rpc(
      'list_status_viewers',
      params: {'p_status_id': widget.status['id']},
    );
    return (rows as List)
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList();
  }

  Future<void> _showViewers() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(sheetContext).height * 0.55,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 4, 20, 12),
                child: Text('Status viewers', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
              ),
              Expanded(
                child: FutureBuilder<List<Map<String, dynamic>>>(
                  future: _viewers,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (snapshot.hasError) {
                      return const Center(child: Text('Could not load viewers. Please retry.'));
                    }
                    final viewers = snapshot.data ?? [];
                    if (viewers.isEmpty) {
                      return const Center(child: Text('No views yet.'));
                    }
                    return ListView.separated(
                      itemCount: viewers.length,
                      separatorBuilder: (_, __) => const Divider(height: 1, indent: 72),
                      itemBuilder: (context, index) {
                        final viewer = viewers[index];
                        final name = viewer['display_name']?.toString() ?? 'Nipto member';
                        final handle = viewer['nipto_id']?.toString() ?? '';
                        final viewedAt = DateTime.tryParse(viewer['viewed_at']?.toString() ?? '')?.toLocal();
                        final time = viewedAt == null
                            ? ''
                            : viewedAt.hour.toString().padLeft(2, '0') + ':' +
                                viewedAt.minute.toString().padLeft(2, '0');
                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: NiptoColors.violetSoft,
                            child: Text(name.isEmpty ? 'N' : name.substring(0, 1).toUpperCase()),
                          ),
                          title: Text(name),
                          subtitle: Text(handle.isEmpty ? 'Nipto member' : '@$handle'),
                          trailing: Text(time, style: const TextStyle(color: NiptoColors.muted, fontSize: 12)),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final type = widget.status['status_type'] as String;
    final text = widget.status['text_content'] as String? ?? '';
    Widget content;

    if (type == 'text') {
      content = Container(
        color: _background(),
        alignment: Alignment.center,
        padding: const EdgeInsets.all(36),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white, fontSize: 27, fontWeight: FontWeight.w800, height: 1.35),
        ),
      );
    } else if (_failed) {
      content = const Center(child: Text('This status is unavailable.', style: TextStyle(color: Colors.white70)));
    } else if (_signedUrl == null) {
      content = const Center(child: CircularProgressIndicator(color: Colors.white));
    } else if (type == 'image') {
      content = Center(child: Image.network(_signedUrl!, fit: BoxFit.contain));
    } else if (_video != null && _video!.value.isInitialized) {
      content = Center(
        child: AspectRatio(
          aspectRatio: _video!.value.aspectRatio,
          child: VideoPlayer(_video!),
        ),
      );
    } else {
      content = const Center(child: CircularProgressIndicator(color: Colors.white));
    }

    final isOwner = Supabase.instance.client.auth.currentUser?.id == widget.ownerId;
    return SizedBox.expand(
      child: Stack(
        fit: StackFit.expand,
        children: [
          content,
          if (isOwner)
            Positioned(
              left: 16,
              bottom: 22,
              child: SafeArea(
                child: FutureBuilder<List<Map<String, dynamic>>>(
                  future: _loadViewers(),
                  builder: (context, snapshot) {
                    final count = snapshot.data?.length;
                    return OutlinedButton.icon(
                      onPressed: _showViewers,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        backgroundColor: const Color(0x99000000),
                        side: const BorderSide(color: Colors.white54),
                      ),
                      icon: const Icon(Icons.visibility_outlined, size: 18),
                      label: Text(count == null ? 'Viewers' : '$count views'),
                    );
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }
}
