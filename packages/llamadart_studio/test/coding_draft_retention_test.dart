import 'dart:async';

// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio/llamadart_studio.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

import 'studio_widget_test_helpers.dart';
import 'test_io_helper.dart';

class _HeldCodingInference extends FakeInferencePort {
  final StreamController<StudioTurnEvent> events =
      StreamController<StudioTurnEvent>();
  StreamController<StudioTurnEvent>? nextEvents;
  StudioTurnRequest? request;
  int cancellations = 0;

  @override
  void cancelGeneration() {
    cancellations++;
  }

  @override
  Stream<StudioTurnEvent> streamTurn(StudioTurnRequest request) {
    if (this.request != null) {
      nextEvents = StreamController<StudioTurnEvent>();
      this.request = request;
      return nextEvents!.stream;
    }
    this.request = request;
    return events.stream;
  }
}

void main() {
  final prompt = find.byKey(const Key('coding_prompt_input'));

  String promptText(WidgetTester tester) =>
      tester.widget<TextField>(prompt).controller!.text;

  testWidgets('Coding drafts survive disposal and remain scoped to folders', (
    WidgetTester tester,
  ) async {
    final deps = await buildTestDeps();
    addTearDown(deps.dispose);
    final first = await tester.runAsync(() => createTempDir('studio_draft_a_'));
    final second = await tester.runAsync(
      () => createTempDir('studio_draft_b_'),
    );
    addTearDown(() => tester.runAsync(() => deleteDirIfExists(first)));
    addTearDown(() => tester.runAsync(() => deleteDirIfExists(second)));
    if (first != null) {
      await tester.runAsync(
        () => deps.codingController.setWorkspaceRoot(first),
      );
    }

    Future<void> showCoding(bool visible) async {
      await tester.pumpWidget(
        StudioScope(
          deps: deps,
          child: MaterialApp(
            theme: StudioTheme.dark(),
            home: Scaffold(
              body: visible
                  ? const CodingWorkspaceView()
                  : const Text('Models'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await showCoding(true);
    await tester.enterText(prompt, '  Keep the first project instructions\n');
    await showCoding(false);
    await showCoding(true);
    expect(promptText(tester), '  Keep the first project instructions\n');

    // Folder selection requires the native workspace filesystem.
    if (first != null && second != null) {
      await tester.runAsync(
        () => deps.codingController.setWorkspaceRoot(second),
      );
      await tester.pumpAndSettle();
      expect(promptText(tester), isEmpty);
      await tester.enterText(prompt, 'Second project instructions');
      await showCoding(false);
      await tester.runAsync(
        () => deps.codingController.setWorkspaceRoot(first),
      );
      await showCoding(true);
      expect(promptText(tester), '  Keep the first project instructions\n');
      await tester.runAsync(
        () => deps.codingController.setWorkspaceRoot(second),
      );
      await tester.pumpAndSettle();
      expect(promptText(tester), 'Second project instructions');
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('Sending clears submitted text and retains edits during a turn', (
    WidgetTester tester,
  ) async {
    final inference = _HeldCodingInference();
    final deps = await buildTestDeps(inferencePort: inference);
    addTearDown(deps.dispose);

    Future<void> showCoding(bool visible) async {
      await tester.pumpWidget(
        StudioScope(
          deps: deps,
          child: MaterialApp(
            theme: StudioTheme.dark(),
            home: Scaffold(
              body: visible
                  ? const CodingWorkspaceView()
                  : const Text('Models'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await showCoding(true);
    await tester.enterText(prompt, 'Submitted instructions');
    await tester.tap(find.byKey(const Key('coding_send_button')));
    await tester.pump();
    expect(inference.request!.history.last.text, 'Submitted instructions');
    expect(promptText(tester), isEmpty);
    await tester.enterText(prompt, 'Instructions for the next turn');
    await showCoding(false);
    inference.events.add(
      const StudioTurnCompletedEvent(
        StudioTurnResult(
          text: 'Done',
          metrics: StudioTurnMetrics(
            generatedTokens: 1,
            elapsedMs: 1,
            decodeElapsedMs: 1,
          ),
        ),
      ),
    );
    unawaited(inference.events.close());
    await tester.pump();
    await showCoding(true);
    expect(promptText(tester), 'Instructions for the next turn');
    expect(deps.codingController.activeStreamStore.state.isGenerating, isFalse);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'Clear cancels the turn, discards its tools and clears only its draft',
    (WidgetTester tester) async {
      final inference = _HeldCodingInference();
      final deps = await buildTestDeps(inferencePort: inference);
      addTearDown(deps.dispose);
      final directory = await tester.runAsync(
        () => createTempDir('studio_draft_clear_'),
      );
      addTearDown(() => tester.runAsync(() => deleteDirIfExists(directory)));
      if (directory != null) {
        await tester.runAsync(
          () => deps.codingController.setWorkspaceRoot(directory),
        );
      }
      const otherWorkspace = '/other-project';
      deps.codingController.setPromptDraftForWorkspace(
        otherWorkspace,
        'Other draft',
      );
      await tester.pumpWidget(
        StudioScope(
          deps: deps,
          child: MaterialApp(
            theme: StudioTheme.dark(),
            home: const Scaffold(body: CodingWorkspaceView()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(prompt, 'Old instructions');
      await tester.tap(find.byKey(const Key('coding_send_button')));
      await tester.pump();
      final oldWrite = directory == null
          ? null
          : inference.request!.extraTools.firstWhere(
              (tool) => tool.name == 'write',
            );
      await tester.enterText(prompt, 'Unsent instructions to discard');
      deps.codingController.clearSession();
      await tester.pump();
      expect(promptText(tester), isEmpty);
      expect(inference.cancellations, greaterThan(0));
      expect(
        deps.codingController.activeStreamStore.state.isGenerating,
        isTrue,
      );
      expect(
        deps.codingController.activeStreamStore.state.statusLabel,
        'Stopping previous turn…',
      );
      expect(find.byKey(const Key('coding_send_button')), findsNothing);
      expect(
        deps.codingController.promptDraftForWorkspace(otherWorkspace),
        'Other draft',
      );
      if (oldWrite != null) {
        await expectLater(
          oldWrite.invoke(<String, dynamic>{
            'path': 'late.txt',
            'content': 'Old turn',
          }),
          throwsA(isA<LlamaStateException>()),
        );
        expect(fileExistsSync('$directory/late.txt'), isFalse);
      }
      expect(deps.codingController.state.messages, isEmpty);
      await tester.enterText(prompt, 'New session instructions');
      inference.events.add(const StudioTextDeltaEvent('Late old response'));
      unawaited(inference.events.close());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(deps.codingController.state.messages, isEmpty);
      expect(promptText(tester), 'New session instructions');
      await tester.tap(find.byKey(const Key('coding_send_button')));
      await tester.pump();
      await tester.enterText(prompt, 'Next draft');
      expect(
        deps.codingController.activeStreamStore.state.isGenerating,
        isTrue,
      );
      expect(
        deps.codingController.state.messages.single.text,
        'New session instructions',
      );
      expect(promptText(tester), 'Next draft');
      expect(deps.codingController.state.recentChanges, isEmpty);
      unawaited(inference.nextEvents!.close());
      await tester.pumpAndSettle();
      expect(
        deps.codingController.activeStreamStore.state.isGenerating,
        isFalse,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
