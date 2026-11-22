import 'dart:async';

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
  testWidgets('registration rejects invalid display name before submit',
      (tester) async {
    var submitCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: NativeNiptoRegistrationScreen(
          onSubmit: ({
            required displayName,
            required niptoId,
            required password,
            recoveryNiptoId,
          }) async {
            submitCount++;
          },
        ),
      ),
    );

    await tester.tap(find.text('Create Nipto account'));
    await tester.pump();

    expect(find.text('Display name must be 2–50 characters.'), findsOneWidget);
    expect(submitCount, 0);
  });

  testWidgets('registration does not submit until ID availability is confirmed',
      (tester) async {
    var submitCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: NativeNiptoRegistrationScreen(
          onSubmit: ({
            required displayName,
            required niptoId,
            required password,
            recoveryNiptoId,
          }) async {
            submitCount++;
          },
        ),
      ),
    );

    await tester.enterText(find.byLabelText('Display name'), 'Nipto User');
    await tester.enterText(find.byLabelText('Nipto ID'), 'sample_user');
    await tester.enterText(find.byLabelText('Password'), 'StrongPassword1!');
    await tester.enterText(find.byLabelText('Confirm password'), 'StrongPassword1!');
    await tester.tap(find.text('Create Nipto account'));
    await tester.pump();

    expect(
      find.text('Wait for a successful availability check.'),
      findsOneWidget,
    );
    expect(submitCount, 0);
  });

  testWidgets('prevents duplicate submission while registration callback is pending',
      (tester) async {
    var submitCount = 0;
    final completion = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        home: NativeNiptoRegistrationScreen(
          checkNiptoIdAvailability: (id) async => {'available': true},
          onSubmit: ({
            required displayName,
            required niptoId,
            required password,
            recoveryNiptoId,
          }) async {
            submitCount++;
            await completion.future;
          },
        ),
      ),
    );

    await tester.enterText(find.byLabelText('Display name'), 'Nipto User');
    await tester.enterText(find.byLabelText('Nipto ID'), 'sample_user');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    expect(find.text('This Nipto ID is available.'), findsOneWidget);

    await tester.enterText(find.byLabelText('Password'), 'StrongPassword1!');
    await tester.enterText(find.byLabelText('Confirm password'), 'StrongPassword1!');
    await tester.tap(find.text('Create Nipto account'));
    await tester.pump();
    await tester.tap(find.text('Create Nipto account'));
    await tester.pump();

    expect(submitCount, 1);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    completion.complete();
    await tester.pump();
    await tester.pump();
    expect(find.text('Create Nipto account'), findsOneWidget);
  });
}
