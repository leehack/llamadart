// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_studio/llamadart_studio.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

import '../integration_test/support/fixture_text_input.dart';
import 'studio_widget_test_helpers.dart';

// Match integration_test's registration policy without a device or model.
class _FixtureBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get registerTestTextInput => false;
}

class _ObservingInference extends FakeInferencePort {
  final requests = <StudioTurnRequest>[];

  @override
  Stream<StudioTurnEvent> streamTurn(StudioTurnRequest request) {
    requests.add(request);
    return super.streamTurn(request);
  }
}

int _currentClientId(WidgetTester tester) {
  expect(tester.testTextInput.isRegistered, isTrue);
  expect(tester.testTextInput.hasAnyClients, isTrue);
  final call = tester.testTextInput.log.lastWhere(
    (call) => call.method == 'TextInput.setClient',
  );
  final id = (call.arguments as List<dynamic>).first as int;
  expect(id, greaterThan(0));
  debugPrint('fixture input current client ID: $id');
  return id;
}

String _text(WidgetTester tester, String key) =>
    tester.widget<TextField>(find.byKey(Key(key))).controller!.text;

void main() {
  _FixtureBinding();

  testWidgets(
    'unregistered fixture edits reach real Send and Notes controllers',
    (tester) async {
      final input = tester.testTextInput;
      expect(input.isRegistered, isFalse);
      final registration = <int>[0];
      addTearDown(() {
        registration.add(input.isRegistered ? 1 : 0);
        expect(registration, [0, 1, 0]);
        // Retain the observed teardown result in the model-free test log.
        debugPrint('fixture input registration: ${registration.join('/')}');
      });
      registerFixtureTextInput(tester);
      registration.add(input.isRegistered ? 1 : 0);
      final inference = _ObservingInference();
      final deps = await buildTestDeps(inferencePort: inference);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await deps.dispose();
      });
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(LlamadartStudioApp(dependencies: deps));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('nav_workspace_models')));
      await tester.pumpAndSettle();
      await enterFixtureText(
        tester,
        find.byKey(const Key('model_hub_search_field')),
        'qwen3.5 0.8b',
      );
      final searchClient = _currentClientId(tester);
      expect(_text(tester, 'model_hub_search_field'), 'qwen3.5 0.8b');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('nav_workspace_chat')));
      await tester.pumpAndSettle();
      const prompt = 'What is 2 + 2? Reply with just the digit.';
      await enterFixtureText(
        tester,
        find.byKey(const Key('chat_composer_input')),
        prompt,
      );
      final composerClient = _currentClientId(tester);
      expect(composerClient, isNot(searchClient));
      expect(_text(tester, 'chat_composer_input'), prompt);
      expect(inference.requests, isEmpty);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('chat_send_button')))
            .onPressed,
        isNotNull,
      );
      await tester.tap(find.byKey(const Key('chat_send_button')));
      await tester.pumpAndSettle();
      expect(inference.requests, hasLength(1));
      expect(inference.requests.single.history.last.text, prompt);
      expect(
        deps.chatController.state.activeConversation!.activeBranch
            .where((node) => node.role == StudioRole.user)
            .single
            .text,
        prompt,
      );
      expect(_text(tester, 'chat_composer_input'), isEmpty);

      await tester.tap(find.byKey(const Key('nav_workspace_notes')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('vault_new_note_button')));
      await tester.pumpAndSettle();
      await enterFixtureText(
        tester,
        find.byKey(const Key('vault_note_title_input')),
        'Cloud acceptance — Montréal',
      );
      final titleClient = _currentClientId(tester);
      expect(titleClient, isNot(composerClient));
      final content = find.byKey(const Key('vault_note_content_input'));
      await tester.ensureVisible(content);
      await tester.pumpAndSettle();
      await enterFixtureText(tester, content, 'Synthetic physical-host note.');
      expect(_currentClientId(tester), isNot(titleClient));
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('vault_save_note_button')));
      await tester.pumpAndSettle();
      expect(
        deps.notebookController.state.selectedNote?.title,
        'Cloud acceptance — Montréal',
      );
      expect(
        deps.notebookController.state.selectedNote?.content,
        'Synthetic physical-host note.',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('preexisting registration survives fixture teardown', (
    tester,
  ) async {
    final input = tester.testTextInput;
    expect(input.isRegistered, isFalse);
    input.register();
    addTearDown(() {
      expect(input.isRegistered, isTrue);
      input.unregister();
    });
    registerFixtureTextInput(tester);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: TextField())),
    );
    await enterFixtureText(
      tester,
      find.byType(TextField),
      'Already registered',
    );
    _currentClientId(tester);
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).controller.text,
      'Already registered',
    );
  });

  testWidgets(
    'omitted registration fails before debug can mask the missing client',
    (tester) async {
      expect(tester.testTextInput.isRegistered, isFalse);
      final inference = _ObservingInference();
      final deps = await buildTestDeps(inferencePort: inference);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await deps.dispose();
      });
      await tester.pumpWidget(LlamadartStudioApp(dependencies: deps));
      await tester.pumpAndSettle();
      await expectLater(
        () => enterFixtureText(
          tester,
          find.byKey(const Key('chat_composer_input')),
          'Lost',
        ),
        throwsA(
          isA<TestFailure>().having(
            (error) => error.message,
            'reason',
            contains('Register fixture text input inside the test body'),
          ),
        ),
      );
      expect(_text(tester, 'chat_composer_input'), isEmpty);
      expect(inference.requests, isEmpty);
    },
  );

  testWidgets('registration after focus fails the actual-client guard', (
    tester,
  ) async {
    expect(tester.testTextInput.isRegistered, isFalse);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: TextField())),
    );
    await tester.showKeyboard(find.byType(TextField));
    registerFixtureTextInput(tester);
    await expectLater(
      () => enterFixtureText(tester, find.byType(TextField), 'Lost'),
      throwsA(
        isA<TestFailure>().having(
          (error) => error.message,
          'reason',
          contains('captured positive TextInput client ID'),
        ),
      ),
    );
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).controller.text,
      isEmpty,
    );
  });
}
