import 'package:supabase_flutter/supabase_flutter.dart';

import 'nipto_session_manager.dart';

/// Human-readable header for a conversation opened from a notification.
///
/// Push payloads are intentionally ID-only, so the title cannot travel inside
/// FCM data. It is resolved from the database with the same connected-profile
/// lookup the inbox uses, and falls back to neutral text when unavailable.
class NiptoConversationHeader {
  const NiptoConversationHeader({
    required this.title,
    required this.subtitle,
    required this.isGroup,
  });

  static const NiptoConversationHeader fallback = NiptoConversationHeader(
    title: 'Nipto member',
    subtitle: 'Nipto member',
    isGroup: false,
  );

  final String title;
  final String subtitle;
  final bool isGroup;
}

/// Testable seam around the two backend reads needed for a header.
abstract class NiptoConversationHeaderSource {
  Future<List<Map<String, dynamic>>> loadConversation(String conversationId);

  Future<List<Map<String, dynamic>>> loadPeers(List<String> userIds);
}

class NiptoSupabaseConversationHeaderSource
    implements NiptoConversationHeaderSource {
  const NiptoSupabaseConversationHeaderSource({SupabaseClient? client})
    : _client = client;

  final SupabaseClient? _client;

  SupabaseClient get _supabase => _client ?? Supabase.instance.client;

  @override
  Future<List<Map<String, dynamic>>> loadConversation(
    String conversationId,
  ) async {
    final rows = await _supabase
        .from('conversations')
        .select('id, conversation_type, title, direct_user_a, direct_user_b')
        .eq('id', conversationId)
        .limit(1);
    return rows
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList(growable: false);
  }

  @override
  Future<List<Map<String, dynamic>>> loadPeers(List<String> userIds) async {
    if (userIds.isEmpty) return const <Map<String, dynamic>>[];
    final rows = await _supabase.rpc(
      'list_chat_connections',
      params: {'p_user_ids': userIds},
    );
    return (rows as List)
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList(growable: false);
  }
}

class NiptoConversationHeaderResolver {
  const NiptoConversationHeaderResolver({
    NiptoConversationHeaderSource? source,
    String? currentUserId,
  }) : _source = source,
       _currentUserId = currentUserId;

  final NiptoConversationHeaderSource? _source;
  final String? _currentUserId;

  Future<NiptoConversationHeader> resolve(String conversationId) async {
    final source = _source ?? const NiptoSupabaseConversationHeaderSource();
    final me = _currentUserId ?? NiptoSessionManager.instance.userId;
    try {
      final rows = await source.loadConversation(conversationId);
      if (rows.isEmpty) return NiptoConversationHeader.fallback;
      final row = rows.first;

      if (row['conversation_type'] == 'group') {
        final title = (row['title'] as String?)?.trim();
        if (title == null || title.isEmpty) {
          return NiptoConversationHeader.fallback;
        }
        return NiptoConversationHeader(
          title: title,
          subtitle: 'Group conversation',
          isGroup: true,
        );
      }

      final first = row['direct_user_a'] as String?;
      final second = row['direct_user_b'] as String?;
      final peerId = first == me ? second : first;
      if (peerId == null) return NiptoConversationHeader.fallback;

      final peers = await source.loadPeers(<String>[peerId]);
      for (final peer in peers) {
        if (peer['id'] != peerId) continue;
        final displayName = (peer['display_name'] as String?)?.trim();
        if (displayName == null || displayName.isEmpty) continue;
        final handle = (peer['nipto_id'] as String?)?.trim();
        return NiptoConversationHeader(
          title: displayName,
          subtitle: handle == null || handle.isEmpty
              ? 'Nipto member'
              : '@$handle',
          isGroup: false,
        );
      }
      return NiptoConversationHeader.fallback;
    } catch (_) {
      // A missing or unauthorized conversation must never crash notification
      // routing. The inbox remains a safe destination with neutral labels.
      return NiptoConversationHeader.fallback;
    }
  }
}
