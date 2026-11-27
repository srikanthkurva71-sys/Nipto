import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nipto/screens/auth_screen.dart';

void main() {
  testWidgets('primary sign-in action opens the native credential form', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: AuthScreen()));

    await tester.tap(find.text('Sign in with Nipto ID'));
    await tester.pumpAndSettle();

    expect(find.text('Sign in to Nipto'), findsOneWidget);
    expect(find.text('Nipto ID'), findsOneWidget);
    expect(find.text('Password'), findsOneWidget);
  });

  testWidgets('primary registration action opens the native account form', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: AuthScreen()));

    await tester.tap(find.text('Create Nipto account').first);
    await tester.pumpAndSettle();

    expect(find.text('Create your Nipto account'), findsOneWidget);
    expect(find.text('Display name'), findsOneWidget);
    expect(find.text('Nipto ID'), findsOneWidget);
  });
}
