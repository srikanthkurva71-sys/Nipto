import 'package:supabase_flutter/supabase_flutter.dart';

import 'nipto_id_policy.dart';

/// Performs server-backed Nipto ID availability checks.
///
/// This intentionally returns only an availability boolean; it never fetches or
/// exposes profile, credential, or account metadata.
class NiptoIdAvailability {
  NiptoIdAvailability({SupabaseClient? client})
      : _client = client ?? Supabase.instance.client;

  final SupabaseClient _client;

  Future<bool> isAvailable(String candidate) async {
    final normalized = candidate.trim().toLowerCase().replaceFirst(RegExp(r'^@'), '');
    final validationError = NiptoIdPolicy.validate(normalized);
    if (validationError != null) {
      throw ArgumentError.value(candidate, 'candidate', validationError);
    }

    final result = await _client.rpc(
      'nipto_id_is_available',
      params: {'candidate_id': normalized},
    );
    if (result is! bool) {
      throw const FormatException('Availability service returned an invalid response.');
    }
    return result;
  }
}
