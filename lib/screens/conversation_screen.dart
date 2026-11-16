import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../theme/nipto_theme.dart';

class ConversationScreen extends StatefulWidget {
  const ConversationScreen({
    super.key,
    required this.conversationId,
    required this.title,
    required this.subtitle,
  });

  final String conversationId;
  final String title;
  final String subtitle;

  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends State<ConversationScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final _picker = ImagePicker();
  bool _sending = false;
  bool _markReadInFlight = false;
  bool _markReadAgain = false;
  int? _lastObservedMessageCount;
  late final Stream<List<Map<String, dynamic>>> _messagesStream;

  SupabaseClient get _client => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _messagesStream = _client
        .from('messages')
        .stream(primaryKey: ['id'])
        .eq('conversation_id', widget.conversationId)
        .order('created_at');
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _markIncomingRead() async {
    if (_client.auth.currentUser == null) return;
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

  Future<void> _send() async {
    final text = _controller.text.trim();
    final userId = _client.auth.currentUser?.id;
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
    final userId = _client.auth.currentUser?.id;
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

  @override
  Widget build(BuildContext context) {
    final currentUserId = _client.auth.currentUser?.id;
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

                final messages = snapshot.data!;
                final messageCount = messages.length;
                if (_lastObservedMessageCount != messageCount) {
                  _lastObservedMessageCount = messageCount;
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
                  itemCount: messages.length,
                  itemBuilder: (context, index) {
                    final message = messages[index];
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
