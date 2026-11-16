import 'dart:async';
import 'dart:convert';
import 'dart:io';

// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio/llamadart_studio.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

import '../../llamadart_studio_core/test/studio_test_fakes.dart' as core_fakes;
import '../integration_test/support/chat_diagnostics.dart';
import '../integration_test/support/cloud_mobile_profile.dart';
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

class _ProfileStorage extends FakeStoragePort {
  _ProfileStorage(this.path);
  final String path;

  @override
  Future<ResolvedModelAssets> ensureDownloaded(
    StudioModelDescriptor descriptor, {
    required bool isWeb,
    String? bearerToken,
  }) async => ResolvedModelAssets(
    descriptor: descriptor,
    primarySource: ModelSource.path(path),
  );
}

class _ProfileBackend extends core_fakes.FakeSpeculativeFallbackBackend {
  final loads = <ModelParams>[];
  final generations = <GenerationParams>[];

  @override
  Future<int> contextCreate(int modelHandle, ModelParams params) async {
    loads.add(params);
    return super.contextCreate(modelHandle, params);
  }

  @override
  Future<int> getContextSize(int contextHandle) async => loads.last.contextSize;

  @override
  Stream<List<int>> generate(
    int contextHandle,
    String prompt,
    GenerationParams params, {
    List<LlamaContentPart>? parts,
  }) async* {
    generations.add(params);
    yield utf8.encode('4');
  }
}

class _DelayedReloadInference extends FakeInferencePort {
  final entered = Completer<void>();
  final release = Completer<void>();
  int loads = 0;

  @override
  Future<void> loadModel({
    required ResolvedModelAssets assets,
    required StudioSettings settings,
    required bool isWeb,
  }) async {
    if (++loads == 2) {
      entered.complete();
      await release.future;
    }
    await super.loadModel(assets: assets, settings: settings, isWeb: isWeb);
  }
}

void main() {
  test(
    'admitted profile correction waits for the changed engine load',
    () async {
      final inference = _DelayedReloadInference();
      final deps = await buildTestDeps(inferencePort: inference);
      addTearDown(deps.dispose);
      await deps.shellController.updateSettings(cloudMobileSettings);
      await deps.modelHubController.activateChatModel(
        CuratedModelCatalog.models.first,
      );
      final presetSignature =
          inference.runtimeStore.state.loadedEngineSignature;
      var applied = false;
      final correction = applyCloudMobileProfile(deps)
          .then((_) => applied = true);
      await inference.entered.future;
      expect(applied, isFalse);
      expect(
        inference.runtimeStore.state.loadedEngineSignature,
        presetSignature,
      );
      inference.release.complete();
      await correction;
      expect(applied, isTrue);
      expect(
        inference.runtimeStore.state.loadedEngineSignature,
        deps.shellController.state.settings.engineLoadSignature(isWeb: false),
      );
      expectCloudMobileSettings(deps.shellController.state.settings);
    },
  );

  testWidgets(
    'curated activation then admitted profile reaches real Send and backend',
    (tester) async {
      final dir = Directory.systemTemp.createTempSync('cloud-profile-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final model = File('${dir.path}/model.gguf')
        ..writeAsBytesSync([0x47, 0x47, 0x55, 0x46]);
      final journal = ChatDiagnostics(File('${dir.path}/chat.jsonl'));
      final backend = _ProfileBackend();
      // Engine lifecycle futures and file I/O must share the real async zone.
      final port = (await tester.runAsync(
        () async => RecordingInferencePort(
          DirectLlamaInferencePort(backend: backend),
          journal,
        ),
      ))!;
      final deps = await buildTestDeps(
        inferencePort: port,
        storagePort: _ProfileStorage(model.path),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(deps.dispose);
      });
      await tester.binding.setSurfaceSize(const Size(1440, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      // Retain the old initial configuration: activation must really overwrite it.
      await deps.shellController.updateSettings(cloudMobileSettings);
      await tester.pumpWidget(LlamadartStudioApp(dependencies: deps));
      await tester.pumpAndSettle();
      final descriptor = CuratedModelCatalog.models.firstWhere(
        (model) => model.id == 'qwen3.5-0.8b-q4-k-m',
      );
      await tester.runAsync(
        () => deps.modelHubController.activateChatModel(descriptor),
      );
      final preset = deps.shellController.state.settings;
      expect(preset.contextSize, 4096);
      expect(preset.maxTokens, 2048);
      expect(preset.temperature, 0.7);
      expect(preset.thinkingEnabled, isTrue);
      expect(backend.loads.single.contextSize, 4096);

      await tester.runAsync(() => applyCloudMobileProfile(deps));
      await tester.pumpAndSettle();
      const prompt = 'What is 2 + 2? Reply with just the digit.';
      await tester.enterText(
        find.byKey(const Key('chat_composer_input')),
        prompt,
      );
      await tester.tap(find.byKey(const Key('chat_send_button')));
      for (var i = 0; i < 100 && port.completedResult == null; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 1)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      await tester.pumpAndSettle();
      expect(port.lastRequest?.history.last.text, prompt);
      expect(deps.chatController.state.lastTurnError, isNull);
      expect(
        deps.chatController.state.activeConversation!.activeBranch.last.text,
        '4',
      );
      // These are backend-bound arguments from the real Direct port / ChatSession,
      // independent of the fixture's settings assertions and diagnostic conversion.
      final load = backend.loads.last;
      final generation = backend.generations.single;
      final evidence = {
        'load_contexts': backend.loads.map((p) => p.contextSize).toList(),
        'compute': load.device.name,
        'gpu_layers': load.gpuLayers,
        'threads': load.numberOfThreads,
        'batch_threads': (load as LlamaCppModelParams).numberOfThreadsBatch,
        'max_tokens': generation.maxTokens,
        'temperature': generation.temp,
        'request_thinking': port.lastRequest!.settings.thinkingEnabled,
        'request_tools': port.lastRequest!.settings.toolsEnabled,
      };
      debugPrint('profile backend evidence: ${jsonEncode(evidence)}');
      expect(load.contextSize, 2048);
      expect(load.device, ComputeDevice.cpu);
      expect(load.gpuLayers, 0);
      expect(load.numberOfThreads, 2);
      expect(load.numberOfThreadsBatch, 2);
      expect(generation.maxTokens, 32);
      expect(generation.temp, 0);
      expect(generation.thinkingBudget, isNull);
      expectCloudMobileRuntime(deps, port);
      expectCloudMobileTurn(port);
      final rows = journal.file
          .readAsLinesSync()
          .map((line) => jsonDecode(line) as Map<String, dynamic>)
          .toList();
      final request = rows.singleWhere((r) => r['phase'] == 'stream_requested');
      expect(
        request['effective_settings'],
        chatProfileSettings(port.lastRequest!.settings),
      );
      expect(
        (request['generation_options_from_request'] as Map)['max_tokens'],
        generation.maxTokens,
      );
    },
  );

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
