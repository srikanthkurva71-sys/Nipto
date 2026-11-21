import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nipto/widgets/nipto_password_fields.dart';

void main() {
  late TextEditingController passwordController;
  late TextEditingController confirmationController;
  late GlobalKey<FormState> formKey;

  Widget buildHarness() {
    return MaterialApp(
      home: Scaffold(
        body: Form(
          key: formKey,
          child: ListView(
            children: [
              NiptoPasswordFields(
                passwordController: passwordController,
                confirmationController: confirmationController,
              ),
              TextButton(
                onPressed: () => formKey.currentState!.validate(),
                child: const Text('Validate'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  setUp(() {
    passwordController = TextEditingController();
    confirmationController = TextEditingController();
    formKey = GlobalKey<FormState>();
  });

  tearDown(() {
    passwordController.dispose();
    confirmationController.dispose();
  });

  testWidgets('confirmation edits do not invoke password callback', (tester) async {
    var callbackCount = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: NiptoPasswordFields(
          passwordController: passwordController,
          confirmationController: confirmationController,
          onPasswordChanged: (_) => callbackCount++,
        ),
      ),
    ));

    confirmationController.text = 'ConfirmOnly123!';
    await tester.pump();
    expect(callbackCount, 0);

    passwordController.text = 'StrongPass123!';
    await tester.pump();
    expect(callbackCount, 1);
  });

  testWidgets('shows all password requirements', (tester) async {
    await tester.pumpWidget(buildHarness());

    expect(find.text('12+ characters'), findsOneWidget);
    expect(find.text('Lowercase'), findsOneWidget);
    expect(find.text('Uppercase'), findsOneWidget);
    expect(find.text('Number'), findsOneWidget);
    expect(find.text('Symbol'), findsOneWidget);
  });

  testWidgets('accepts a password that meets all requirements and matches',
      (tester) async {
    passwordController.text = 'StrongPass123!';
    confirmationController.text = 'StrongPass123!';
    await tester.pumpWidget(buildHarness());

    expect(formKey.currentState!.validate(), isTrue);
  });

  testWidgets('rejects a password that misses requirements', (tester) async {
    passwordController.text = 'weakpass';
    confirmationController.text = 'weakpass';
    await tester.pumpWidget(buildHarness());

    expect(formKey.currentState!.validate(), isFalse);
  });

  testWidgets('rejects mismatched confirmation', (tester) async {
    passwordController.text = 'StrongPass123!';
    confirmationController.text = 'DifferentPass123!';
    await tester.pumpWidget(buildHarness());

    expect(formKey.currentState!.validate(), isFalse);
  });
}
