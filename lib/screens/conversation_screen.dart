import 'package:flutter/material.dart';
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
  bool _sending = false;

  SupabaseClient get _client => Supabase.instance.client;

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
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
              stream: _client
                  .from('messages')
                  .stream(primaryKey: ['id'])
                  .eq('conversation_id', widget.conversationId)
                  .order('created_at'),
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

                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (_scrollController.hasClients) {
                    _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
                  }
                });

                return ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.fromLTRB(16, 18, 16, 20),
                  itemCount: messages.length,
                  itemBuilder: (context, index) {
                    final message = messages[index];
                    final mine = message['sender_id'] == currentUserId;
                    final deleted = message['deleted_at'] != null;
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
                        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
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
                        child: Text(
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
                    tooltip: 'Attach media',
                    onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Media attachments are being added next.')),
                    ),
                    icon: const Icon(Icons.add_circle_outline_rounded, color: NiptoColors.violet),
                  ),
                  Expanded(
                    child: TextField(
                      controller: _controller,
                      minLines: 1,
                      maxLines: 5,
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
