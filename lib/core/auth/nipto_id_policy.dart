/// Shared client-side Nipto ID policy.
///
/// This validates formatting only. The server/database remains authoritative for
/// availability, reserved names, and atomic uniqueness.
class NiptoIdPolicy {
  NiptoIdPolicy._();

  static const minLength = 3;
  static const maxLength = 24;

  static const reservedIds = <String>{
    'admin',
    'administrator',
    'support',
    'help',
    'nipto',
    'official',
    'security',
    'moderator',
  };

  static String normalize(String? value) =>
      (value ?? '').trim().toLowerCase().replaceFirst(RegExp(r'^@'), '');

  static String? validate(String? value) {
    final input = normalize(value);
    if (!RegExp(r'^[a-z0-9_]{3,24}$').hasMatch(input)) {
      return 'Use 3–24 lowercase letters, numbers or underscores.';
    }
    if (reservedIds.contains(input)) {
      return 'This Nipto ID is reserved.';
    }
    return null;
  }
}
