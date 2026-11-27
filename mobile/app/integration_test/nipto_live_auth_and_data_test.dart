import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:nipto/main.dart' as app;

// Creates a real Nipto account and status in the configured Supabase project.
// Delete the probe using the printed NIPTO_E2E_ID after every run.
Finder findField(String label) => find.byWidgetPredicate(
  (widget) => widget is InputDecorator && widget.decoration.labelText == label,
);

Future<void> pumpUntil(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 45),
  String? description,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 250));
    if (tester.any(finder)) return;
  }
  fail('Timed out waiting for ${description ?? finder.toString()}');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('real Nipto registration and signed-in data write', (
    tester,
  ) async {
    final suffix = DateTime.now().millisecondsSinceEpoch;
    final niptoId = 'e2e$suffix';
    const password = 'NiptoE2E!2026';
    final statusText = 'Live E2E status $suffix';

    await app.main();
    await pumpUntil(
      tester,
      find.text('Your Nipto account. Your identity.'),
      description: 'auth screen',
    );

    await tester.tap(
      find.widgetWithText(OutlinedButton, 'Create Nipto account'),
    );
    await pumpUntil(
      tester,
      find.text('Create your Nipto account'),
      description: 'registration screen',
    );

    await tester.enterText(findField('Display name'), 'Nipto E2E Probe');
    await tester.enterText(findField('Nipto ID'), niptoId);
    await tester.enterText(findField('Password'), password);
    await tester.enterText(findField('Confirm password'), password);
    await tester.pump(const Duration(milliseconds: 600));

    await pumpUntil(
      tester,
      find.text('This Nipto ID is available.'),
      timeout: const Duration(seconds: 30),
      description: 'Nipto ID availability confirmation',
    );

    final createAccountButton = find.widgetWithText(
      FilledButton,
      'Create Nipto account',
    );
    await tester.ensureVisible(createAccountButton);
    await tester.tap(createAccountButton);
    await pumpUntil(
      tester,
      find.byType(NavigationBar),
      timeout: const Duration(seconds: 60),
      description: 'signed-in main shell',
    );

    // ignore: avoid_print
    print('NIPTO_E2E_ID=$niptoId');
    // ignore: avoid_print
    print('NIPTO_E2E_STATUS=$statusText');

    await tester.tap(find.widgetWithText(NavigationDestination, 'Chats'));
    await pumpUntil(
      tester,
      find.text('Your status'),
      description: 'status tray',
    );
    await tester.ensureVisible(find.text('Your status'));
    await tester.pump();

    await tester.tap(find.text('Your status'));
    await pumpUntil(
      tester,
      find.text('Text status'),
      description: 'status creation sheet',
    );

    await tester.tap(find.text('Text status'));
    await pumpUntil(
      tester,
      find.text('Write a status'),
      description: 'text status dialog',
    );

    final statusField = find.byWidgetPredicate(
      (widget) =>
          widget is TextField &&
          widget.decoration?.hintText == 'What’s on your mind?',
    );
    await tester.enterText(statusField, statusText);
    await tester.tap(find.text('Share'));
    await pumpUntil(
      tester,
      find.text('Your update'),
      timeout: const Duration(seconds: 45),
      description: 'persisted own status',
    );

    expect(find.text('Home'), findsWidgets);
    expect(find.text('Shorts'), findsWidgets);
    expect(find.text('You'), findsWidgets);
  });
}
