import 'package:flutter_test/flutter_test.dart';
import 'package:nipto/services/nipto_password_policy.dart';

void main() {
  group('NiptoPasswordPolicy', () {
    test('accepts a password meeting all local requirements', () {
      expect(NiptoPasswordPolicy.isValid('SecurePassword7!'), isTrue);
    });

    test('rejects a password shorter than 12 characters', () {
      expect(NiptoPasswordPolicy.isValid('Aa1!short'), isFalse);
    });

    test('rejects a password missing lowercase letters', () {
      expect(NiptoPasswordPolicy.isValid('ABCDEFGHIJKL7!'), isFalse);
    });

    test('rejects a password missing uppercase letters', () {
      expect(NiptoPasswordPolicy.isValid('abcdefghijkl7!'), isFalse);
    });

    test('rejects a password missing numbers', () {
      expect(NiptoPasswordPolicy.isValid('SecurePassword!!'), isFalse);
    });

    test('rejects a password missing symbols', () {
      expect(NiptoPasswordPolicy.isValid('SecurePassword77'), isFalse);
    });

    test('rejects passwords over the input maximum', () {
      expect(NiptoPasswordPolicy.isValid('A' * 128 + 'a1!'), isFalse);
    });

    test('confirmation requires non-empty exact match', () {
      expect(NiptoPasswordPolicy.matches('SecurePassword7!', ''), isFalse);
      expect(NiptoPasswordPolicy.matches('SecurePassword7!', 'SecurePassword7!'), isTrue);
      expect(NiptoPasswordPolicy.matches('SecurePassword7!', 'SecurePassword7'), isFalse);
    });
  });
}
