@Tags(<String>['local-only'])
library;

import 'dart:convert';
import 'dart:io';

// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio/llamadart_studio.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:path_provider/path_provider.dart';

import '../test/studio_widget_test_helpers.dart';

const _enabled = bool.fromEnvironment('STUDIO_CLOUD_ACCEPTANCE');
const _modelSha256 = String.fromEnvironment('STUDIO_CLOUD_MODEL_SHA256');
const _modelBytes = 532517120;

class _StagedModelStorage extends FakeStoragePort {
  _StagedModelStorage(this.modelPath);
  final String modelPath;

  @override
  List<StudioModelDescriptor> get discoveredLocalModels => const [];

  @override
  Future<List<StudioModelDescriptor>> refreshLocalModels({
    List<String> extraDirectories = const [],
  }) async => const [];

  @override
  Future<bool> isCached(
    StudioModelDescriptor descriptor, {
    required bool isWeb,
  }) async => descriptor.id == 'qwen3.5-0.8b-q4-k-m';

  @override
  Future<ResolvedModelAssets> ensureDownloaded(
    StudioModelDescriptor descriptor, {
    required bool isWeb,
    String? bearerToken,
  }) async {
    if (descriptor.id != 'qwen3.5-0.8b-q4-k-m') {
      throw StateError('Only the admitted staged model is available.');
    }
    return ResolvedModelAssets(
      descriptor: descriptor,
      primarySource: ModelSource.path(modelPath),
    );
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'physical Android Studio Chat inference and Notes persistence',
    (tester) async {
      WidgetController.hitTestWarningShouldBeFatal = true;
      addTearDown(() => WidgetController.hitTestWarningShouldBeFatal = false);
      expect(Platform.isAndroid, isTrue);
      expect(RegExp(r'^[a-f0-9]{64}$').hasMatch(_modelSha256), isTrue);
      final cache = await getTemporaryDirectory();
      final model = File('${cache.path}/firebase-model.gguf');
      expect(await model.length(), _modelBytes);
      final support = await getApplicationSupportDirectory();
      final temp = await Directory('${support.path}/studio_cloud').create();
      final manager = DefaultModelDownloadManager(
        defaultCacheDirectory: '${temp.path}/models',
      );
      final verified = await manager.ensureModel(
        ModelSource.path(model.path),
        options: ModelLoadOptions(sha256: _modelSha256),
      );
      expect(verified.sha256, _modelSha256);
      final kv = InMemoryKeyValueStore();
      final notes = createDefaultNoteStore(
        fallbackKeyValueStore: kv,
        directoryPath: temp.path,
      );
      final inference = DirectLlamaInferencePort();
      final deps = await StudioDependencies.fromPorts(
        keyValueStore: kv,
        conversationStore: KeyValueConversationStore(kv),
        noteStore: notes,
        storagePort: _StagedModelStorage(model.path),
        inferencePort: inference,
        speechPort: FakeSpeechPort(),
        imagePort: FakeImagePort(),
        playgroundPort: FakePlaygroundPort(),
        isMobile: true,
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await deps.dispose();
        if (await temp.exists()) await temp.delete(recursive: true);
      });
      await deps.shellController.updateSettings(
        (s) => s.copyWith(
          computeDevice: ComputeDevice.cpu,
          gpuLayers: 0,
          autoTuneHardware: false,
          contextSize: 2048,
          requestedContextSize: 2048,
          numberOfThreads: 2,
          numberOfThreadsBatch: 2,
          maxTokens: 32,
          temperature: 0,
          thinkingEnabled: false,
          toolsEnabled: false,
          enabledBuiltInTools: const [],
        ),
      );
      await tester.pumpWidget(LlamadartStudioApp(dependencies: deps));
      await tester.pumpAndSettle();
      Future<void> tap(String key) async {
        final notificationDeadline = DateTime.now().add(
          const Duration(seconds: 10),
        );
        while (find.byType(SnackBar).evaluate().isNotEmpty &&
            DateTime.now().isBefore(notificationDeadline)) {
          await tester.pump(const Duration(milliseconds: 100));
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(find.byType(SnackBar), findsNothing);
        final target = find.byKey(Key(key));
        await tester.ensureVisible(target);
        await tester.pumpAndSettle();
        await tester.tap(target);
        await tester.pump();
      }

      Future<void> navigate(String workspace) async {
        await tap('open_sidebar_drawer_button');
        await tester.pumpAndSettle();
        await tap('nav_workspace_$workspace');
        await tester.pumpAndSettle();
      }

      Future<void> waitFor(bool Function() done, String phase) async {
        final deadline = DateTime.now().add(const Duration(seconds: 90));
        while (!done() && DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 100));
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(
          done(),
          isTrue,
          reason:
              '$phase: runtime=${inference.runtimeStore.state.phase} '
              'error=${inference.runtimeStore.state.errorMessage} '
              'activating=${deps.modelHubController.state.activatingDescriptor?.id} '
              'noteTitle=${deps.notebookController.state.selectedNote?.title}',
        );
        expect(tester.takeException(), isNull, reason: phase);
      }

      await navigate('models');
      await tester.enterText(
        find.byKey(const Key('model_hub_search_field')),
        'qwen3.5 0.8b',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tap('activate_model_qwen3.5-0.8b-q4-k-m');
      await waitFor(
        () =>
            inference.runtimeStore.state.isReady &&
            deps.shellController.state.activeWorkspace == StudioWorkspace.chat,
        'model load and navigation',
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('chat_composer_input')),
        'What is 2 + 2? Reply with just the digit.',
      );
      await tap('chat_send_button');
      await waitFor(
        () =>
            !deps.chatController.activeStreamStore.state.isGenerating &&
            (deps
                        .chatController
                        .state
                        .activeConversation
                        ?.activeBranch
                        .length ??
                    0) >=
                2,
        'chat generation',
      );
      final answer = deps
          .chatController
          .state
          .activeConversation!
          .activeBranch
          .last
          .text
          .trim();
      expect(deps.chatController.state.lastTurnError, isNull);
      expect(answer, '4');
      await navigate('notes');
      final priorNoteIds = deps.notebookController.state.notes
          .map((n) => n.id)
          .toSet();
      await tap('vault_new_note_button');
      await waitFor(
        () =>
            deps.notebookController.state.selectedNote != null &&
            !priorNoteIds.contains(
              deps.notebookController.state.selectedNote!.id,
            ),
        'note creation',
      );
      await tester.enterText(
        find.byKey(const Key('vault_note_title_input')),
        'Cloud acceptance — Montréal',
      );
      await tester.ensureVisible(
        find.byKey(const Key('vault_note_content_input')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('vault_note_content_input')),
        'Saved on the physical Android host.',
      );
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tap('vault_save_note_button');
      await waitFor(
        () =>
            deps.notebookController.state.selectedNote?.title ==
                'Cloud acceptance — Montréal' &&
            deps.notebookController.state.selectedNote?.content ==
                'Saved on the physical Android host.',
        'note save completed',
      );
      final reopened = await createDefaultNoteStore(
        fallbackKeyValueStore: kv,
        directoryPath: temp.path,
      ).loadAll();
      expect(
        reopened.any(
          (note) =>
              note.title == 'Cloud acceptance — Montréal' &&
              note.content == 'Saved on the physical Android host.',
        ),
        isTrue,
      );
      final external = await getExternalStorageDirectory();
      expect(external, isNotNull);
      final output = await Directory('${external!.path}/studio-acceptance')
          .create(recursive: true);
      await File('${output.path}/receipt.json').writeAsString(
        jsonEncode({
          'schema': 1,
          'model_sha256': _modelSha256,
          'model_bytes': _modelBytes,
          'backend': inference.runtimeStore.state.backendName,
          'chat_answer': answer,
          'note_reopened': true,
          'compute': 'cpu',
          'threads': 2,
          'qualified_scope': 'chat-ui-inference-and-notes-persistence',
        }),
        flush: true,
      );
    },
    skip: !_enabled,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
