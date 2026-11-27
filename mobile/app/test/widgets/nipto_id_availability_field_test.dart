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
    await tester.pump();
    expect(
      find.text('Enter a valid Nipto ID (3–24 characters).'),
      findsOneWidget,
    );
  });

  testWidgets('requires a successful server availability check', (
    tester,
  ) async {
    idController.text = 'valid_id';
    await tester.pumpWidget(buildHarness());

    expect(formKey.currentState!.validate(), isFalse);
    await tester.pump();
    expect(
      find.text('Wait for a successful availability check.'),
      findsOneWidget,
    );
  });

  testWidgets('shows local validation guidance for too-short IDs', (
    tester,
  ) async {
    idController.text = 'ab';
    await tester.pumpWidget(buildHarness());
    await tester.pump();

    expect(
      find.textContaining('Use 3–24 lowercase letters or numbers'),
      findsOneWidget,
    );
    expect(formKey.currentState!.validate(), isFalse);
  });
  testWidgets('revalidates when the text controller is replaced', (
    tester,
  ) async {
    final replacementController = TextEditingController(text: 'bad__id');
    var availabilityCallbackCount = 0;
    Widget buildWithController(TextEditingController controller) => MaterialApp(
      home: Scaffold(
        body: NiptoIdAvailabilityField(
          controller: controller,
          onAvailabilityChanged: (_) => availabilityCallbackCount++,
        ),
      ),
    );

    await tester.pumpWidget(buildWithController(idController));
    await tester.pumpWidget(buildWithController(replacementController));
    await tester.pump();

    expect(
      find.text(
        'Use 3–24 lowercase letters or numbers, with single underscores between parts. Reserved IDs are unavailable.',
      ),
      findsOneWidget,
    );
    expect(availabilityCallbackCount, greaterThan(0));

    idController.text = 'another_valid_id';
    await tester.pump();
    expect(
      find.text(
        'Use 3–24 lowercase letters or numbers, with single underscores between parts. Reserved IDs are unavailable.',
      ),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    replacementController.dispose();
  });

  testWidgets('renders server suggestions and selecting one rechecks it', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'taken_id');
    var checkedId = '';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NiptoIdAvailabilityField(
            controller: controller,
            checkAvailability: (id) async {
              checkedId = id;
              return {
                'available': false,
                'suggestions': ['taken_id2', 'taken_id3'],
              };
            },
          ),
        ),
      ),
    );

    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    expect(checkedId, 'taken_id');
    expect(find.text('@taken_id2'), findsOneWidget);
    await tester.tap(find.text('@taken_id2'));
    await tester.pump();

    expect(controller.text, 'taken_id2');
    expect(find.text('Checking availability…'), findsNothing);
    expect(
      find.text(
        'Use 3–24 lowercase letters or numbers, with single underscores between parts.',
      ),
      findsNothing,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('reports available after injected server check', (tester) async {
    final controller = TextEditingController(text: 'fresh_id');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NiptoIdAvailabilityField(
            controller: controller,
            checkAvailability: (_) async => {'available': true},
          ),
        ),
      ),
    );

    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();

    expect(find.text('This Nipto ID is available.'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}
