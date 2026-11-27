import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nipto/screens/native_nipto_registration_screen.dart';

Finder findField(String label) => find.byWidgetPredicate(
  (widget) => widget is InputDecorator && widget.decoration.labelText == label,
);

Future<void> tapSubmit(WidgetTester tester) async {
  await tester.ensureVisible(find.text('Create Nipto account'));
  await tester.pump();
  await tester.tap(find.text('Create Nipto account'));
}

void main() {
  testWidgets(
    'registration defers recovery account setup until after registration',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: NativeNiptoRegistrationScreen(
            onSubmit:
                ({
                  required displayName,
                  required niptoId,
                  required password,
                  required passwordConfirmation,
                }) async {},
          ),
        ),
      );

      expect(findField('Recovery Nipto ID (optional)'), findsNothing);
      expect(
        find.text(
          'Choose a display name and unique Nipto ID. You can add a recovery account later in Settings.',
        ),
        findsOneWidget,
      );
    },
  );
  testWidgets('registration rejects invalid display name before submit', (
    tester,
  ) async {
    var submitCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: NativeNiptoRegistrationScreen(
          onSubmit:
              ({
                required displayName,
                required niptoId,
                required password,
                required passwordConfirmation,
              }) async {
                submitCount++;
              },
        ),
      ),
    );

    await tapSubmit(tester);
    await tester.pump();

    expect(find.text('Display name must be 2–50 characters.'), findsOneWidget);
    expect(submitCount, 0);
  });

  testWidgets(
    'registration does not submit until ID availability is confirmed',
    (tester) async {
      var submitCount = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: NativeNiptoRegistrationScreen(
            onSubmit:
                ({
                  required displayName,
                  required niptoId,
                  required password,
                  required passwordConfirmation,
                }) async {
                  submitCount++;
                },
          ),
        ),
      );

      await tester.enterText(findField('Display name'), 'Nipto User');
      await tester.enterText(findField('Nipto ID'), 'sample_user');
      await tester.enterText(findField('Password'), 'StrongPassword1!');
      await tester.enterText(findField('Confirm password'), 'StrongPassword1!');
      await tapSubmit(tester);
      await tester.pump();

      expect(
        find.text('Wait for a successful availability check.'),
        findsOneWidget,
      );
      expect(submitCount, 0);
    },
  );

  testWidgets(
    'prevents duplicate submission while registration callback is pending',
    (tester) async {
      var submitCount = 0;
      final completion = Completer<void>();
      await tester.pumpWidget(
        MaterialApp(
          home: NativeNiptoRegistrationScreen(
            checkNiptoIdAvailability: (id) async => {'available': true},
            onSubmit:
                ({
                  required displayName,
                  required niptoId,
                  required password,
                  required passwordConfirmation,
                }) async {
                  submitCount++;
                  await completion.future;
                },
          ),
        ),
      );

      await tester.enterText(findField('Display name'), 'Nipto User');
      await tester.enterText(findField('Nipto ID'), 'sample_user');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();

      expect(find.text('This Nipto ID is available.'), findsOneWidget);

      await tester.enterText(findField('Password'), 'StrongPassword1!');
      await tester.enterText(findField('Confirm password'), 'StrongPassword1!');
      await tapSubmit(tester);
      await tester.pump();
      // While the callback is pending the button is disabled (spinner shown), so
      // a second tap must not submit again.
      await tester.tap(find.byType(FilledButton));
      await tester.pump();

      expect(submitCount, 1);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      completion.complete();
      await tester.pump();
      await tester.pump();
      expect(find.text('Create Nipto account'), findsOneWidget);
    },
  );
}
