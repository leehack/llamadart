import 'dart:async';
import 'dart:convert';
import 'dart:io';

// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_studio/llamadart_studio.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

import '../integration_test/support/chat_diagnostics.dart';
import 'studio_widget_test_helpers.dart';

class ControlledInference extends FakeInferencePort {
  final events = StreamController<StudioTurnEvent>();
  StudioTurnRequest? request;
  int requests = 0;
  int cancellations = 0;
  @override
  Stream<StudioTurnEvent> streamTurn(StudioTurnRequest value) {
    request = value;
    requests++;
    return events.stream;
  }

  @override
  void cancelGeneration() {
    cancellations++;
  }

  @override
  Future<void> dispose() async {
    await events.close();
    await super.dispose();
  }
}

void main() {
  testWidgets('timeout diagnostics preserve pending Flutter error details', (
    tester,
  ) async {
    final dir = Directory.systemTemp.createTempSync(
      'chat-timeout-diagnostics-',
    );
    addTearDown(() => dir.deleteSync(recursive: true));
    final journal = ChatDiagnostics(File('${dir.path}/chat.jsonl'));
    final original = StateError('original framework failure');
    FlutterError.reportError(
      FlutterErrorDetails(exception: original, stack: StackTrace.current),
    );

    await expectLater(
      expectChatWaitFinished(
        tester: tester,
        diagnostics: journal,
        done: () => false,
        phase: 'chat generation',
        checkpoint: const {'is_generating': true, 'text_length': 7},
        reason: 'original 90-second deadline expired',
      ),
      throwsA(isA<TestFailure>()),
    );

    expect(tester.takeException(), same(original));
    final row = jsonDecode(
      journal.file.readAsLinesSync().single,
    ) as Map<String, Object?>;
    expect(row['phase'], 'wait_end');
    expect(row['done'], false);
    expect(row['text_length'], 7);
  });

  testWidgets(
    'real Send forwards request; stalled and error states survive journal flush',
    (tester) async {
      final dir = Directory.systemTemp.createTempSync('chat-diagnostics-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final journal = ChatDiagnostics(
        File('${dir.path}/validation/runs/run/chat-diagnostics.jsonl'),
      );
      final controlled = ControlledInference();
      final port = RecordingInferencePort(controlled, journal);
      final deps = await buildTestDeps(inferencePort: port);
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(LlamadartStudioApp(dependencies: deps));
      await tester.pumpAndSettle();
      const prompt = 'Synthetic diagnostic prompt';
      await tester.enterText(
        find.byKey(const Key('chat_composer_input')),
        prompt,
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('chat_composer_input')))
            .controller!
            .text,
        prompt,
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('chat_send_button')))
            .onPressed,
        isNotNull,
      );
      journal.record('before_send', chatCheckpoint(deps, prompt));
      await tester.tap(find.byKey(const Key('chat_send_button')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      expect(controlled.requests, 1);
      expect(controlled.request!.history.last.text, prompt);
      expect(controlled.request!.settings, deps.shellController.state.settings);
      controlled.events.add(const StudioTextDeltaEvent('partial'));
      controlled.events.add(const StudioThinkingDeltaEvent('reason'));
      await tester.pump();
      // Short model-free control; the maintained physical fixture retains 90 s.
      await tester.pump(const Duration(milliseconds: 100));
      expect(deps.chatController.activeStreamStore.state.isGenerating, isTrue);
      expect(
        () => expect(
          !deps.chatController.activeStreamStore.state.isGenerating,
          isTrue,
        ),
        throwsA(isA<TestFailure>()),
      );
      journal.record('timeout_control', chatCheckpoint(deps, prompt));
      controlled.events.addError(StateError('synthetic'));
      await tester.pumpAndSettle();
      expect(deps.chatController.state.lastTurnError, isNotNull);
      journal.record('error_control', chatCheckpoint(deps, prompt));
      await journal.flush();
      final rows = journal.file
          .readAsLinesSync()
          .map((s) => jsonDecode(s) as Map<String, dynamic>)
          .toList();
      final stalled = rows.singleWhere((r) => r['phase'] == 'timeout_control');
      expect(stalled['is_generating'], true);
      expect(stalled['text_length'], 7);
      expect(stalled['thinking_length'], 6);
      expect(
        rows.where((r) => r['phase'] == 'stream_subscribed'),
        hasLength(1),
      );
      expect(rows.any((r) => r['phase'] == 'stream_error'), true);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(deps.dispose);
      await journal.flush();
      expect(journal.file.existsSync(), true);
    },
  );

  test('events, errors, completion and cancellation forward once; journal is bounded', () async {
    final dir = Directory.systemTemp.createTempSync('chat-diagnostics-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final journal = ChatDiagnostics(File('${dir.path}/chat.jsonl'));
    final controlled = ControlledInference();
    final port = RecordingInferencePort(controlled, journal);
    final request = StudioTurnRequest(
      history: const [],
      settings: StudioSettings(),
    );
    final received = <StudioTurnEvent>[];
    final errors = <Object>[];
    final done = Completer<void>();
    port
        .streamTurn(request)
        .listen(received.add, onError: errors.add, onDone: done.complete);
    final event = StudioTurnCompletedEvent(
      StudioTurnResult(
        text: '4',
        metrics: const StudioTurnMetrics(
          generatedTokens: 1,
          elapsedMs: 1,
          decodeElapsedMs: 1,
          modelName: 'fake',
          backendLabel: 'fake',
        ),
      ),
    );
    final error = StateError('synthetic');
    controlled.events.add(event);
    controlled.events.addError(error);
    port.cancelGeneration();
    await controlled.events.close();
    await done.future;
    expect(identical(controlled.request, request), true);
    expect(received.single, same(event));
    expect(errors.single, same(error));
    expect(controlled.cancellations, 1);
    await journal.flush();
    expect(journal.file.readAsStringSync(), contains('stream_closed'));
    for (var i = 0; i < 500; i++) {
      journal.record('bounded');
    }
    await journal.flush();
    expect(
      journal.file.lengthSync(),
      lessThanOrEqualTo(ChatDiagnostics.maxBytes),
    );
    expect(journal.file.readAsLinesSync().length, ChatDiagnostics.maxRecords);
    await port.dispose();
  });
}
