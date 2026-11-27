import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nipto/screens/native_nipto_login_screen.dart';
import 'package:nipto/services/nipto_session_manager.dart';

Finder findField(String label) => find.byWidgetPredicate(
  (widget) => widget is InputDecorator && widget.decoration.labelText == label,
);

void main() {
  testWidgets('normalizes the Nipto ID and submits both credentials', (
    tester,
  ) async {
    late String submittedId;
    late String submittedPassword;
    await tester.pumpWidget(
      MaterialApp(
        home: NativeNiptoLoginScreen(
          onSubmit: ({required niptoId, required password}) async {
            submittedId = niptoId;
            submittedPassword = password;
          },
        ),
      ),
    );

    await tester.enterText(findField('Nipto ID'), '@Example_User');
    await tester.enterText(findField('Password'), 'StrongPassword1!');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    expect(submittedId, 'example_user');
    expect(submittedPassword, 'StrongPassword1!');
  });

  testWidgets('shows the server auth message on failure', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: NativeNiptoLoginScreen(
          onSubmit: ({required niptoId, required password}) async {
            throw const NiptoAuthException('That account is unavailable.');
          },
        ),
      ),
    );

    await tester.enterText(findField('Nipto ID'), 'example_user');
    await tester.enterText(findField('Password'), 'StrongPassword1!');
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();

    expect(find.text('That account is unavailable.'), findsOneWidget);
  });
}
