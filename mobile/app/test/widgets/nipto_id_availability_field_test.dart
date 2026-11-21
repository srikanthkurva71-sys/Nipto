import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nipto/widgets/nipto_id_availability_field.dart';

void main() {
  late TextEditingController idController;
  late GlobalKey<FormState> formKey;

  Widget buildHarness() {
    return MaterialApp(
      home: Scaffold(
        body: Form(
          key: formKey,
          child: Column(
            children: [
              NiptoIdAvailabilityField(controller: idController),
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
    idController = TextEditingController();
    formKey = GlobalKey<FormState>();
  });

  tearDown(() {
    idController.dispose();
  });

  testWidgets('rejects IDs that violate the local grammar', (tester) async {
    idController.text = 'bad__id';
    await tester.pumpWidget(buildHarness());

    expect(formKey.currentState!.validate(), isFalse);
    expect(find.text('Enter a valid Nipto ID (3–24 characters).'), findsOneWidget);
  });

  testWidgets('requires a successful server availability check', (tester) async {
    idController.text = 'valid_id';
    await tester.pumpWidget(buildHarness());

    expect(formKey.currentState!.validate(), isFalse);
    expect(find.text('Wait for a successful availability check.'), findsOneWidget);
  });

  testWidgets('shows local validation guidance for too-short IDs', (tester) async {
    idController.text = 'ab';
    await tester.pumpWidget(buildHarness());

    expect(find.textContaining('Use 3–24 lowercase letters or numbers'), findsOneWidget);
    expect(formKey.currentState!.validate(), isFalse);
  });
}
