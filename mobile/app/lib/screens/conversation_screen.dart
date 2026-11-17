import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/nipto_session_manager.dart';

import '../theme/nipto_theme.dart';
import 'call_screen.dart';

class ConversationScreen extends StatefulWidget {
  const ConversationScreen({
    super.key,
    required this.conversationId,
    required this.title,
    required this.subtitle,
    this.enableCalls = true,
  });

  final String conversationId;
  final String title;
  final String subtitle;
  final bool enableCalls;

  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends State<ConversationScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final _picker = ImagePicker();
  static const _messagePageSize = 50;
  final List<Map<String, dynamic>> _olderMessages = [];
  bool _sending = false;
  bool _loadingOlder = false;
  bool _hasMoreOlder = true;
  bool _markReadInFlight = false;
  bool _markReadAgain = false;
  String? _lastObservedNewestMessageId;
  late final Stream<List<Map<String, dynamic>>> _messagesStream;

  SupabaseClient get _client => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _messagesStream = _client
        .from('messages')
        .stream(primaryKey: ['id'])
        .eq('conversation_id', widget.conversationId)
        .order('created_at', ascending: false)
        .order('id', ascending: false)
        .limit(_messagePageSize);
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _markIncomingRead() async {
    if (NiptoSessionManager.instance.userId == null) return;
    if (_markReadInFlight) {
      _markReadAgain = true;
      return;
    }

    _markReadInFlight = true;
    try {
      do {
        _markReadAgain = false;
        try {
          await _client.rpc(
            'mark_conversation_read',
            params: {'p_conversation_id': widget.conversationId},
          );
        } catch (_) {
          // A read receipt failure should not prevent the conversation from working.
        }
      } while (_markReadAgain && mounted);
    } finally {
      _markReadInFlight = false;
    }
  }

  Future<void> _loadOlderMessages(List<Map<String, dynamic>> latestMessages) async {
    if (_loadingOlder || !_hasMoreOlder) return;

    final cursor = _olderMessages.isNotEmpty
        ? _olderMessages.first
        : (latestMessages.isNotEmpty ? latestMessages.last : null);
    if (cursor == null) {
      setState(() => _hasMoreOlder = false);
      return;
    }

    final createdAt = cursor['created_at'] as String?;
    final id = cursor['id'] as String?;
    if (createdAt == null || id == null) return;

    final previousPixels =
        _scrollController.hasClients ? _scrollController.position.pixels : 0.0;
    final previousMaxExtent = _scrollController.hasClients
        ? _scrollController.position.maxScrollExtent
        : 0.0;

    setState(() {
      _loadingOlder = true;
    });

    try {
      final rows = await _client
          .from('messages')
          .select()
          .eq('conversation_id', widget.conversationId)
          .or('created_at.lt.$createdAt,and(created_at.eq.$createdAt,id.lt.$id)')
          .order('created_at', ascending: false)
          .order('id', ascending: false)
          .limit(_messagePageSize);

      final page = List<Map<String, dynamic>>.from(rows)
        ..sort((a, b) {
          final byDate = (a['created_at'] as String)
              .compareTo(b['created_at'] as String);
          return byDate != 0
              ? byDate
              : (a['id'] as String).compareTo(b['id'] as String);
        });

      if (!mounted) return;
      setState(() {
        final knownIds = _olderMessages.map((message) => message['id']).toSet();
        for (final message in page) {
          if (knownIds.add(message['id'])) {
            _olderMessages.add(message);
          }
        }
        _hasMoreOlder = rows.length == _messagePageSize;
        _loadingOlder = false;
      });

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollController.hasClients) return;
        final addedExtent =
            _scrollController.position.maxScrollExtent - previousMaxExtent;
        _scrollController.jumpTo(
          (previousPixels + addedExtent)
              .clamp(0.0, _scrollController.position.maxScrollExtent),
        );
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingOlder = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Older messages could not be loaded. Please try again.'),
        ),
      );
    }
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    final userId = NiptoSessionManager.instance.userId;
    if (text.isEmpty || userId == null || _sending) return;

    setState(() => _sending = true);
    _controller.clear();
    try {
      await _client.from('messages').insert({
        'conversation_id': widget.conversationId,
        'sender_id': userId,
        'message_type': 'text',
        'body': text,
      });
    } catch (_) {
      if (!mounted) return;
      _controller.text = text;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Message not sent. Please try again.')),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _attachImage() async {
    if (_sending) return;
    final userId = NiptoSessionManager.instance.userId;
    if (userId == null) return;

    XFile? file;
    try {
      file = await _picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 88,
        maxWidth: 1800,
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open your photo library. Please try again.')),
        );
      }
      return;
    }
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

    final fileSize = await file.length();
    if (fileSize > 10 * 1024 * 1024) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Choose an image smaller than 10 MB.')),
      );
      return;
    }

    final path = widget.conversationId + '/' + userId + '/' +
        DateTime.now().microsecondsSinceEpoch.toString() + '.' + extension;

    setState(() => _sending = true);
    var uploaded = false;
    try {
      await _client.storage.from('chat-media').upload(
        path,
        File(file.path),
        fileOptions: FileOptions(contentType: contentType, upsert: false),
      );
      uploaded = true;

      await _client.from('messages').insert({
        'conversation_id': widget.conversationId,
        'sender_id': userId,
        'message_type': 'image',
        'media_path': path,
      });
    } catch (_) {
      if (uploaded) {
        try {
          await _client.storage.from('chat-media').remove([path]);
        } catch (_) {
          // A failed cleanup leaves an inaccessible orphan, not a public file.
        }
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Photo could not be sent. Check your connection and try again.')),
      );
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _startCall(String mediaType) async {
    if (NiptoSessionManager.instance.userId == null) return;
    try {
      final result = await _client.rpc(
        'start_nipto_call',
        params: {
          'p_conversation_id': widget.conversationId,
          'p_media_type': mediaType,
        },
      );
      final rows = List<Map<String, dynamic>>.from(result as List);
      if (rows.isEmpty) throw StateError('Call could not be started.');
      final call = rows.first;
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => CallScreen(
            callId: call['call_id'] as String,
            mediaType: mediaType,
            isCaller: true,
            peerTitle: widget.title,
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      final message = error.toString().toLowerCase().contains('already active')
          ? 'A call is already active in this conversation.'
          : error.toString().toLowerCase().contains('permission')
              ? 'Call permission is unavailable.'
              : 'Could not start this call. Check the conversation and try again.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentUserId = NiptoSessionManager.instance.userId;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            CircleAvatar(
              radius: 18,
              backgroundColor: NiptoColors.violetSoft,
              child: Text(
                widget.title.isNotEmpty ? widget.title.substring(0, 1).toUpperCase() : 'N',
                style: const TextStyle(color: NiptoColors.violet, fontWeight: FontWeight.w800),
              ),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                  Text(widget.subtitle, style: const TextStyle(fontSize: 11, color: NiptoColors.muted)),
                ],
              ),
            ),
          ],
        ),
        actions: [
          if (widget.enableCalls) ...[
            IconButton(
              tooltip: 'Voice call',
              onPressed: () => _startCall('audio'),
              icon: const Icon(Icons.call_outlined),
            ),
            IconButton(
              tooltip: 'Video call',
              onPressed: () => _startCall('video'),
              icon: const Icon(Icons.videocam_outlined),
            ),
          ],
          IconButton(
            tooltip: 'Conversation options',
            onPressed: () {},
            icon: const Icon(Icons.more_horiz_rounded),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<List<Map<String, dynamic>>>(
              stream: _messagesStream,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return const Center(
                    child: Text('Messages could not be loaded.', style: TextStyle(color: NiptoColors.muted)),
                  );
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }

                final latestMessages = snapshot.data!;
                if (latestMessages.length < _messagePageSize &&
                    _olderMessages.isEmpty) {
                  _hasMoreOlder = false;
                }
                final combinedById = <String, Map<String, dynamic>>{
                  for (final message in _olderMessages)
                    message['id'] as String: message,
                  for (final message in latestMessages)
                    message['id'] as String: message,
                };
                final messages = combinedById.values.toList()
                  ..sort((a, b) {
                    final byDate = (a['created_at'] as String)
                        .compareTo(b['created_at'] as String);
                    return byDate != 0
                        ? byDate
                        : (a['id'] as String).compareTo(b['id'] as String);
                  });

                final newestMessageId = latestMessages.isEmpty
                    ? null
                    : latestMessages.first['id'] as String?;
                if (newestMessageId != null &&
                    _lastObservedNewestMessageId != newestMessageId) {
                  _lastObservedNewestMessageId = newestMessageId;
                  final shouldStayAtBottom = !_scrollController.hasClients ||
                      _scrollController.position.maxScrollExtent -
                              _scrollController.position.pixels <=
                          120;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!mounted) return;
                    _markIncomingRead();
                    if (shouldStayAtBottom && _scrollController.hasClients) {
                      _scrollController.jumpTo(
                        _scrollController.position.maxScrollExtent,
                      );
                    }
                  });
                }

                if (messages.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        Icon(Icons.waving_hand_rounded, size: 34, color: NiptoColors.violet),
                        SizedBox(height: 10),
                        Text('Say hello', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
                        SizedBox(height: 5),
                        Text('Your conversation starts here.', style: TextStyle(color: NiptoColors.muted)),
                      ],
                    ),
                  );
                }

                return ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.fromLTRB(16, 18, 16, 20),
                  itemCount: messages.length + (_hasMoreOlder ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (_hasMoreOlder && index == 0) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 14),
                          child: TextButton.icon(
                            onPressed: _loadingOlder
                                ? null
                                : () => _loadOlderMessages(latestMessages),
                            icon: _loadingOlder
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : const Icon(Icons.history_rounded),
                            label: Text(
                              _loadingOlder
                                  ? 'Loading earlier messages…'
                                  : 'Load earlier messages',
                            ),
                          ),
                        ),
                      );
                    }
                    final messageIndex =
                        index - (_hasMoreOlder ? 1 : 0);
                    final message = messages[messageIndex];
                    final mine = message['sender_id'] == currentUserId;
                    final deleted = message['deleted_at'] != null;
                    final isImage = !deleted && message['message_type'] == 'image' &&
                        message['media_path'] is String;
                    final body = deleted
                        ? 'Message deleted'
                        : (message['body'] as String? ?? 'Media message');

                    return Align(
                      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
                      child: Container(
                        constraints: BoxConstraints(
                          maxWidth: MediaQuery.sizeOf(context).width * 0.78,
                        ),
                        margin: const EdgeInsets.only(bottom: 9),
                        padding: isImage
                            ? const EdgeInsets.all(5)
                            : const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
                        decoration: BoxDecoration(
                          color: mine ? NiptoColors.violet : Colors.white,
                          borderRadius: BorderRadius.only(
                            topLeft: const Radius.circular(18),
                            topRight: const Radius.circular(18),
                            bottomLeft: Radius.circular(mine ? 18 : 5),
                            bottomRight: Radius.circular(mine ? 5 : 18),
                          ),
                          border: mine ? null : Border.all(color: NiptoColors.border),
                        ),
                        child: isImage
                            ? _ChatImage(path: message['media_path'] as String)
                            : Text(
                                body,
                                style: TextStyle(
                                  color: mine ? Colors.white : NiptoColors.ink,
                                  fontStyle: deleted ? FontStyle.italic : FontStyle.normal,
                                ),
                              ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
              child: Row(
                children: [
                  IconButton(
                    tooltip: 'Attach photo',
                    onPressed: _sending ? null : _attachImage,
                    icon: const Icon(Icons.image_outlined, color: NiptoColors.violet),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      minLines: 1,
                      maxLines: 5,
                      maxLength: 10000,
                      textCapitalization: TextCapitalization.sentences,
                      onSubmitted: (_) => _send(),
                      decoration: const InputDecoration(
                        hintText: 'Write a message…',
                        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Material(
                    color: NiptoColors.violet,
                    borderRadius: BorderRadius.circular(16),
                    child: IconButton(
                      tooltip: 'Send message',
                      onPressed: _sending ? null : _send,
                      icon: _sending
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.arrow_upward_rounded, color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChatImage extends StatefulWidget {
  const _ChatImage({required this.path});

  final String path;

  @override
  State<_ChatImage> createState() => _ChatImageState();
}

class _ChatImageState extends State<_ChatImage> {
  late Future<String> _signedUrl;

  @override
  void initState() {
    super.initState();
    _signedUrl = _load();
  }

  Future<String> _load() {
    return Supabase.instance.client.storage
        .from('chat-media')
        .createSignedUrl(widget.path, 1800);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: _signedUrl,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const SizedBox(
            width: 180,
            height: 120,
            child: Center(child: Icon(Icons.broken_image_outlined, color: NiptoColors.muted)),
          );
        }
        if (!snapshot.hasData) {
          return const SizedBox(
            width: 180,
            height: 120,
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }
        return ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Image.network(
            snapshot.data!,
            width: 230,
            height: 220,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => const SizedBox(
              width: 180,
              height: 120,
              child: Center(child: Icon(Icons.broken_image_outlined, color: NiptoColors.muted)),
            ),
          ),
        );
      },
    );
  }
}
