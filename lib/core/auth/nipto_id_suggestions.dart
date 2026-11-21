import 'nipto_id_policy.dart';

/// Deterministic alternatives for an unavailable Nipto ID.
///
/// Suggestions are not availability guarantees; the server must check each one.
class NiptoIdSuggestions {
  NiptoIdSuggestions._();

  static List<String> generate(String? requested, {int limit = 5}) {
    if (limit <= 0) return const [];

    final base = NiptoIdPolicy.normalize(requested);
    if (base.isEmpty) return const [];

    final candidates = <String>[
      '${base}_2',
      '${base}_3',
      '${base}2',
      '${base}3',
      'my_${base}',
      '${base}_n',
    ];

    final seen = <String>{base};
    final suggestions = <String>[];

    for (final candidate in candidates) {
      if (candidate.length > NiptoIdPolicy.maxLength) continue;
      if (NiptoIdPolicy.validate(candidate) != null) continue;
      if (!seen.add(candidate)) continue;

      suggestions.add(candidate);
      if (suggestions.length >= limit) break;
    }

    return suggestions;
  }
}
