import 'package:flutter_test/flutter.dart';
import 'package:nipto/core/auth/nipto_id_suggestions.dart';

void main() {
  group('NiptoIdSuggestions', () {
    test('returns deterministic, valid alternatives', () {
      final suggestions = NiptoIdSuggestions.generate('hello');
      expect(suggestions, ['hello_2', "hello_3", "hello2", "hello3", "my_hello"]);
      expect(suggestions.every((id) => id != 'hello'), isTrue);
    });

    test('respects limit and non-positive limits', () {
      expect(NiptoIdSuggestions.generate('hello', limit: 2), hasLength(2));
      expect(NiptoIdSuggestions.generate('hello', limit: 0), isEmpty);
    });

    test('returns no suggestions for empty input', () {
      expect(NiptoIdSuggestions.generate(''), isEmpty);
    });

    test('filters candidates that exceed max length', () {
      final suggestions = NiptoIdSuggestions.generate('a' * 24);
      expect(suggestions.every((id) => id.length <= 24), isTrue);
    });
  });
}
