import 'package:flutter_test/flutter_test.dart';
import 'package:nipto/services/nipto_conversation_header.dart';

class FakeHeaderSource implements NiptoConversationHeaderSource {
  FakeHeaderSource({this.conversation = const [], this.peers = const []});

  List<Map<String, dynamic>> conversation;
  List<Map<String, dynamic>> peers;
  bool throwOnConversation = false;

  @override
  Future<List<Map<String, dynamic>>> loadConversation(
    String conversationId,
  ) async {
    if (throwOnConversation) throw StateError('offline');
    return conversation;
  }

  @override
  Future<List<Map<String, dynamic>>> loadPeers(List<String> userIds) async =>
      peers;
}

void main() {
  group('NiptoConversationHeaderResolver', () {
    test('group conversations keep their title and disable calls', () async {
      final source = FakeHeaderSource(
        conversation: [
          <String, dynamic>{
            'id': 'group-1',
            'conversation_type': 'group',
            'title': 'Weekend plans',
          },
        ],
      );
      final header = await NiptoConversationHeaderResolver(
        source: source,
        currentUserId: 'me',
      ).resolve('group-1');

      expect(header.isGroup, isTrue);
      expect(header.title, 'Weekend plans');
      expect(header.subtitle, 'Group conversation');
    });

    test('direct conversations resolve the connected peer profile', () async {
      final source = FakeHeaderSource(
        conversation: [
          <String, dynamic>{
            'id': 'direct-1',
            'conversation_type': 'direct',
            'direct_user_a': 'me',
            'direct_user_b': 'peer-9',
          },
        ],
        peers: [
          <String, dynamic>{
            'id': 'peer-9',
            'display_name': 'Ada Lovelace',
            'nipto_id': 'ada',
          },
        ],
      );
      final header = await NiptoConversationHeaderResolver(
        source: source,
        currentUserId: 'me',
      ).resolve('direct-1');

      expect(header.isGroup, isFalse);
      expect(header.title, 'Ada Lovelace');
      expect(header.subtitle, '@ada');
    });

    test(
      'direct conversations use neutral labels when the peer is hidden',
      () async {
        final source = FakeHeaderSource(
          conversation: [
            <String, dynamic>{
              'id': 'direct-2',
              'conversation_type': 'direct',
              'direct_user_a': 'peer-1',
              'direct_user_b': 'me',
            },
          ],
        );
        final header = await NiptoConversationHeaderResolver(
          source: source,
          currentUserId: 'me',
        ).resolve('direct-2');

        expect(header.title, NiptoConversationHeader.fallback.title);
        expect(header.subtitle, NiptoConversationHeader.fallback.subtitle);
      },
    );

    test('missing conversations fall back without throwing', () async {
      final header = await NiptoConversationHeaderResolver(
        source: FakeHeaderSource(),
        currentUserId: 'me',
      ).resolve('missing');
      expect(header.title, 'Nipto member');
    });

    test(
      'backend failures fall back without crashing notification routing',
      () async {
        final source = FakeHeaderSource()..throwOnConversation = true;
        final header = await NiptoConversationHeaderResolver(
          source: source,
          currentUserId: 'me',
        ).resolve('direct-3');
        expect(header.title, 'Nipto member');
      },
    );

    test('groups without a title fall back safely', () async {
      final source = FakeHeaderSource(
        conversation: [
          <String, dynamic>{
            'id': 'group-2',
            'conversation_type': 'group',
            'title': '   ',
          },
        ],
      );
      final header = await NiptoConversationHeaderResolver(
        source: source,
        currentUserId: 'me',
      ).resolve('group-2');
      expect(header.isGroup, isFalse);
      expect(header.title, 'Nipto member');
    });
  });
}
