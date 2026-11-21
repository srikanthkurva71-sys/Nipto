import 'package:flutter_test/flutter_test.dart';
import 'package:nipto/core/auth/nipto_id_policy.dart';

void main() {
  group('NiptoIdPolicy', () {

    test('normalizes whitespace, case, and a leading @', () {
      expect(NiptoIdPolicy.normalize('  @Nipto_User  '), 'nipto_user');
    });

    test('accepts IDs at the minimum and maximum lengths', () {
      expect(NiptoIdPolicy.validate('abc'), isNull);
      expect(NiptoIdPolicy.validate('a' * 24), isNull);
    });

    test('rejects IDs outside the length and character rules', () {
      expect(NiptoIdPolicy.validate('ab'), isNotNull);
      expect(NiptoIdPolicy.validate('a' * 25), isNotNull);
      expect(NiptoIdPolicy.validate('name-with-dash'), isNotNull);
      expect(NiptoIdPolicy.validate('has space'), isNotNull);
    });

    test('rejects reserved IDs case-insensitively', () {
      expect(NiptoIdPolicy.validate('ADMIN'), isNotNull);
      expect(NiptoIdPolicy.validate('support'), isNotNull);
    });
  });
}
