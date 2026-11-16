import 'package:flutter_test/flutter_test.dart';
import 'package:nipto/theme/nipto_theme.dart';

void main() {
  group('Nipto design system', () {
    test('uses Material 3 with the Nipto violet primary color', () {
      final theme = NiptoTheme.light;

      expect(theme.useMaterial3, isTrue);
      expect(theme.colorScheme.primary, NiptoColors.violet);
      expect(theme.scaffoldBackgroundColor, NiptoColors.canvas);
    });

    test('keeps core palette tokens stable', () {
      expect(NiptoColors.ink.toARGB32(), 0xFF171827);
      expect(NiptoColors.violet.toARGB32(), 0xFF6657E8);
      expect(NiptoColors.coral.toARGB32(), 0xFFFF806B);
      expect(NiptoColors.danger.toARGB32(), 0xFFD94B5B);
    });
  });
}
