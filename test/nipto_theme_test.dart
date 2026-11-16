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
      expect(NiptoColors.ink.toARGB32(), 0xFF101C50);
      expect(NiptoColors.violet.toARGB32(), 0xFF5528E8);
      expect(NiptoColors.coral.toARGB32(), 0xFFFF4D9B);
      expect(NiptoColors.danger.toARGB32(), 0xFFD94B5B);
    });

    test('exposes the logo gradient palette', () {
      expect(NiptoColors.brandCyan.toARGB32(), 0xFF08C9F4);
      expect(NiptoColors.brandBlue.toARGB32(), 0xFF0876F8);
      expect(NiptoColors.brandMagenta.toARGB32(), 0xFFE516B8);
      expect(NiptoBrand.markGradient.colors.length, 4);
    });
  });
}
