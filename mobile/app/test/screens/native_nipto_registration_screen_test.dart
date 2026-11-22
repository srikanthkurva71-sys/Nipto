import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nipto/screens/native_nipto_registration_screen.dart';

void main() {
  testWidgets('registration defers recovery account setup until after registration',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: NativeNiptoRegistrationScreen(
          onSubmit: ({
            required displayName,
            required niptoId,
            required password,
            recoveryNiptoId,
          }) async {},
        ),
      ),
    );

    expect(find.text('Recovery Nipto ID (optional)'), findsNothing);
    expect(find.text('Only add a recovery account you trust.'), findsNothing);
    expect(
      find.text(
        'Choose a display name and unique Nipto ID. You can add a recovery account later in Settings.',
      ),
      findsOneWidget,
    );
  });
}
