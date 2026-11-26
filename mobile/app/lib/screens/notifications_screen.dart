import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/nipto_session_manager.dart';

import '../theme/nipto_theme.dart';
import 'conversation_screen.dart';
import 'recovery_contacts_screen.dart';

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  late Future<List<Map<String, dynamic>>> _notifications;
  final Set<String> _busyIds = {};

  SupabaseClient get _client => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    _notifications = _load();
  }

  Future<List<Map<String, dynamic>>> _load() async {
    final rows = await _client.rpc('list_my_notifications');
    return (rows as List).map((row) => Map<String, dynamic>.from(row)).toList();
  }

  Future<void> _refresh() async {
    setState(() => _notifications = _load());
    await _notifications;
  }

  Future<void> _markRead(Map<String, dynamic> item) async {
    if (item['read_at'] != null) return;
    final userId = NiptoSessionManager.instance.userId;
    final notificationId = item['id'];
    if (userId == null || notificationId == null) return;
    try {
      // Scope acknowledgement to the signed-in recipient as well as the row ID.
      // notifications is keyed by recipient_id; there is no user_id column.
      await _client
          .from('notifications')
          .update({'read_at': DateTime.now().toUtc().toIso8601String()})
          .eq('id', notificationId)
          .eq('recipient_id', userId);
      if (mounted) {
        // Refresh the shared Chats badge after the notification is acknowledged.
        await _refresh();
      }
    } catch (_) {
      // Keep the notification visible if marking it read fails.
    }
  }

  Future<void> _respondToFollowRequest(
    Map<String, dynamic> item, {
    required bool accept,
  }) async {
    final id = item['id'] as String;
    final actorId = item['actor_id'] as String?;
    final myId = NiptoSessionManager.instance.userId;
    if (actorId == null || myId == null || _busyIds.contains(id)) return;

    setState(() => _busyIds.add(id));
    try {
      if (accept) {
        await _client.from('follows').update({'status': 'accepted'}).match({
          'follower_id': actorId,
          'following_id': myId,
          'status': 'pending',
        });
      } else {
        await _client.from('follows').delete().match({
          'follower_id': actorId,
          'following_id': myId,
          'status': 'pending',
        });
      }
      await _markRead(item);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            accept ? 'Follow request accepted.' : 'Follow request declined.',
          ),
        ),
      );
      await _refresh();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('The follow request could not be updated.'),
        ),
      );
    } finally {
      if (mounted) setState(() => _busyIds.remove(id));
    }
  }

  Future<void> _respondToGroupInvite(
    Map<String, dynamic> item, {
    required bool accept,
  }) async {
    final id = item['id'] as String;
    final conversationId = item['entity_id'] as String?;
    if (conversationId == null || _busyIds.contains(id)) return;

    setState(() => _busyIds.add(id));
    try {
      await _client.rpc(
        accept ? 'accept_group_invitation' : 'decline_group_invitation',
        params: {'p_conversation_id': conversationId},
      );
      await _markRead(item);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            accept ? 'You joined the group.' : 'Group invitation declined.',
          ),
        ),
      );
      await _refresh();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('The group invitation could not be updated.'),
        ),
      );
    } finally {
      if (mounted) setState(() => _busyIds.remove(id));
    }
  }

  Future<void> _openNotification(Map<String, dynamic> item) async {
    await _markRead(item);
    final payload = item['payload'] is Map
        ? Map<String, dynamic>.from(item['payload'] as Map)
        : <String, dynamic>{};
    final kind = item['notification_type'] as String? ?? '';

    if (payload['kind'] == 'recovery_request' ||
        payload['kind'] == 'recovery_accepted' ||
        payload['kind'] == 'recovery_rejected' ||
        payload['kind'] == 'password_recovery_request') {
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const RecoveryContactsScreen()),
      );
      if (mounted) setState(() => _notifications = _load());
      return;
    }
    if (kind == 'message') {
      final conversationId = payload['conversation_id'] as String?;
      if (conversationId == null || !mounted) return;
      final name = item['actor_display_name'] as String? ?? 'Nipto member';
      final handle = item['actor_nipto_id'] as String? ?? '';
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ConversationScreen(
            conversationId: conversationId,
            title: name,
            subtitle: handle.isEmpty ? 'Nipto member' : '@$handle',
          ),
        ),
      );
      if (mounted) setState(() => _notifications = _load());
      return;
    }
    if (mounted) setState(() => _notifications = _load());
  }

  String _messageFor(Map<String, dynamic> item) {
    final name = item['actor_display_name'] as String? ?? 'Someone';
    switch (item['notification_type']) {
      case 'follow_request':
        return '$name requested to follow you.';
      case 'follow':
        return '$name started following you.';
      case 'follow_accepted':
        return '$name accepted your follow request.';
      case 'message':
        return '$name sent you a message.';
      case 'like':
        return '$name liked your Short.';
      case 'comment':
        return '$name commented on your Short.';
      case 'status_view':
        return '$name viewed your status.';
      default:
        final payload = item['payload'] is Map
            ? Map<String, dynamic>.from(item['payload'] as Map)
            : <String, dynamic>{};
        if (payload['kind'] == 'group_invite') {
          final title = payload['title']?.toString() ?? 'a group';
          return '$name invited you to $title.';
        }
        if (payload['kind'] == 'feedback_update') {
          final status = payload['status']?.toString() ?? 'updated';
          final response = payload['response']?.toString();
          return response == null || response.trim().isEmpty
              ? 'Your feedback is now $status.'
              : 'Your feedback is now $status: $response';
        }
        if (payload['kind'] == 'content_moderation') {
          final type = payload['content_type']?.toString() ?? 'content';
          final decision = payload['decision']?.toString() ?? 'reviewed';
          return 'Your $type was $decision.';
        }
        if (payload['kind'] == 'recovery_request') {
          return '$name asked to be your trusted recovery Nipto account.';
        }
        if (payload['kind'] == 'recovery_accepted') {
          return '$name accepted your recovery-contact request.';
        }
        if (payload['kind'] == 'recovery_rejected') {
          return '$name declined your recovery-contact request.';
        }
        if (payload['kind'] == 'password_recovery_request') {
          return '$name asked you to approve a password reset. Review it in Recovery Nipto account settings.';
        }
        if (payload['kind'] == 'password_recovery_approved') {
          return 'Your trusted Nipto account approved your password recovery request.';
        }
        if (payload['kind'] == 'password_recovery_rejected') {
          return 'Your trusted Nipto account declined your password recovery request.';
        }
        if (payload['kind'] == 'report_update') {
          final status = payload['status']?.toString() ?? 'updated';
          return 'Your report is now $status.';
        }
        return 'You have a Nipto update.';
    }
  }

  String _timeLabel(String? raw) {
    final value = DateTime.tryParse(raw ?? '')?.toLocal();
    if (value == null) return '';
    final difference = DateTime.now().difference(value);
    if (difference.inMinutes < 1) return 'now';
    if (difference.inHours < 1) return difference.inMinutes.toString() + 'm';
    if (difference.inDays < 1) return difference.inHours.toString() + 'h';
    if (difference.inDays < 7) return difference.inDays.toString() + 'd';
    return value.day.toString() + '/' + value.month.toString();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Notifications')),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: FutureBuilder<List<Map<String, dynamic>>>(
          future: _notifications,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasError) {
              return ListView(
                children: [
                  const SizedBox(height: 120),
                  const Icon(
                    Icons.cloud_off_rounded,
                    size: 42,
                    color: NiptoColors.muted,
                  ),
                  const SizedBox(height: 12),
                  const Center(child: Text('Notifications could not load.')),
                  Center(
                    child: TextButton(
                      onPressed: _refresh,
                      child: const Text('Try again'),
                    ),
                  ),
                ],
              );
            }

            final items = snapshot.data ?? [];
            if (items.isEmpty) {
              return ListView(
                children: [
                  const SizedBox(height: 130),
                  const Icon(
                    Icons.notifications_none_rounded,
                    size: 48,
                    color: NiptoColors.violet,
                  ),
                  const SizedBox(height: 12),
                  const Center(
                    child: Text(
                      'You’re all caught up.',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Center(
                    child: Text(
                      'New messages and activity will appear here.',
                      style: TextStyle(color: NiptoColors.muted),
                    ),
                  ),
                ],
              );
            }

            return ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              itemCount: items.length,
              separatorBuilder: (_, __) => const Divider(height: 1, indent: 62),
              itemBuilder: (context, index) {
                final item = items[index];
                final id = item['id'] as String;
                final isRead = item['read_at'] != null;
                final payload = item['payload'] is Map
                    ? Map<String, dynamic>.from(item['payload'] as Map)
                    : <String, dynamic>{};
                final isFollowRequest =
                    item['notification_type'] == 'follow_request';
                final isGroupInvite = payload['kind'] == 'group_invite';
                final isActionable = isFollowRequest || isGroupInvite;
                final busy = _busyIds.contains(id);

                return ListTile(
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 8,
                  ),
                  leading: CircleAvatar(
                    backgroundColor: isRead
                        ? NiptoColors.canvas
                        : NiptoColors.violetSoft,
                    child: Icon(
                      isFollowRequest
                          ? Icons.person_add_alt_1_rounded
                          : isGroupInvite
                          ? Icons.groups_rounded
                          : item['notification_type'] == 'message'
                          ? Icons.chat_bubble_rounded
                          : Icons.notifications_rounded,
                      color: NiptoColors.violet,
                    ),
                  ),
                  title: Text(
                    _messageFor(item),
                    style: TextStyle(
                      fontWeight: isRead ? FontWeight.w500 : FontWeight.w800,
                      fontSize: 14,
                    ),
                  ),
                  subtitle: isActionable
                      ? Padding(
                          padding: const EdgeInsets.only(top: 10),
                          child: Wrap(
                            spacing: 8,
                            children: [
                              FilledButton.tonal(
                                onPressed: busy
                                    ? null
                                    : () => isFollowRequest
                                          ? _respondToFollowRequest(
                                              item,
                                              accept: true,
                                            )
                                          : _respondToGroupInvite(
                                              item,
                                              accept: true,
                                            ),
                                child: Text(
                                  isFollowRequest ? 'Accept' : 'Join',
                                ),
                              ),
                              OutlinedButton(
                                onPressed: busy
                                    ? null
                                    : () => isFollowRequest
                                          ? _respondToFollowRequest(
                                              item,
                                              accept: false,
                                            )
                                          : _respondToGroupInvite(
                                              item,
                                              accept: false,
                                            ),
                                child: const Text('Decline'),
                              ),
                            ],
                          ),
                        )
                      : null,
                  trailing: Text(
                    _timeLabel(item['created_at'] as String?),
                    style: const TextStyle(
                      color: NiptoColors.muted,
                      fontSize: 11,
                    ),
                  ),
                  onTap: () => _openNotification(item),
                );
              },
            );
          },
        ),
      ),
    );
  }
}
