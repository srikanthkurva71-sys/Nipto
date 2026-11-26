/// Shared local password policy checks for native Nipto account forms.
///
/// This is a user-experience check only. Server-side validation remains
/// authoritative and must enforce the same or stronger policy.
class NiptoPasswordPolicy {
  const NiptoPasswordPolicy();

  static const minimumLength = 12;
  static const maximumLength = 128;

  static bool hasMinimumLength(String password) =>
      password.length >= minimumLength && password.length <= maximumLength;
  static bool hasLowercase(String password) =>
      RegExp(r'[a-z]').hasMatch(password);
  static bool hasUppercase(String password) =>
      RegExp(r'[A-Z]').hasMatch(password);
  static bool hasNumber(String password) => RegExp(r'[0-9]').hasMatch(password);
  static bool hasSymbol(String password) =>
      RegExp(r'[^A-Za-z0-9]').hasMatch(password);

  static bool isValid(String password) =>
      hasMinimumLength(password) &&
      hasLowercase(password) &&
      hasUppercase(password) &&
      hasNumber(password) &&
      hasSymbol(password);

  static bool matches(String password, String confirmation) =>
      confirmation.isNotEmpty && password == confirmation;
}
