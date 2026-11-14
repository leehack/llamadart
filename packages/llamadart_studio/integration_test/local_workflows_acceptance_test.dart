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

import '../test/studio_widget_test_helpers.dart';

// Runtime ports are real; only asset resolution is restricted to explicit files.
class _LocalStorage extends FakeStoragePort {
  _LocalStorage(this.paths);
  final Map<String, String> paths;
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
  }) async => paths.containsKey(descriptor.id);
  @override
  Future<ResolvedModelAssets> ensureDownloaded(
    StudioModelDescriptor descriptor, {
    required bool isWeb,
    String? bearerToken,
  }) async {
    final path = paths[descriptor.id];
    if (path == null) {
      throw StateError('No explicit asset for ${descriptor.id}');
    }
    return ResolvedModelAssets(
      descriptor: descriptor,
      primarySource: ModelSource.path(path),
    );
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final chatPath = Platform.environment['STUDIO_ACCEPTANCE_CHAT_MODEL'];
  final embedPath = Platform.environment['STUDIO_ACCEPTANCE_EMBED_MODEL'];
  final imagePath = Platform.environment['STUDIO_ACCEPTANCE_IMAGE_MODEL'];
  testWidgets(
    'macOS UI completes Chat, Notes generated answer, Coding read, Image',
    (tester) async {
      WidgetController.hitTestWarningShouldBeFatal = true;
      addTearDown(() => WidgetController.hitTestWarningShouldBeFatal = false);
      final temp = await Directory.systemTemp.createTemp(
        'studio_ui_acceptance_',
      );
      final scratch = await Directory('${temp.path}/workspace').create();
      final source = File('${scratch.path}/release.txt');
      await source.writeAsString(
        'The release confirmation token is MONTREAL-4827.\n',
      );
      final kv = InMemoryKeyValueStore();
      final inference = DirectLlamaInferencePort();
      final deps = await StudioDependencies.fromPorts(
        keyValueStore: kv,
        conversationStore: KeyValueConversationStore(kv),
        noteStore: KeyValueNoteStore(kv),
        storagePort: _LocalStorage({
          'qwen3.5-0.8b-q4-k-m': chatPath!,
          'nomic-embed-text-v1.5-q8-0': embedPath!,
          'sdxs-512-q8_0': imagePath!,
        }),
        inferencePort: inference,
        speechPort: DirectLlamaSpeechPort(),
        imagePort: DirectLlamaImagePort(),
        playgroundPort: DirectLlamaPlaygroundPort(sharedChatPort: inference),
      );
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await deps.dispose();
        await temp.delete(recursive: true);
      });
      await deps.shellController.updateSettings(
        (s) => s.copyWith(
          computeDevice: ComputeDevice.cpu,
          gpuLayers: 0,
          autoTuneHardware: false,
          contextSize: 4096,
          requestedContextSize: 4096,
          numberOfThreads: 2,
          numberOfThreadsBatch: 2,
          toolsEnabled: false,
          enabledBuiltInTools: const [],
        ),
      );
      await deps.codingController.setWorkspaceRoot(scratch.path);
      // Isolate the baseline model prompt from optional skill instructions.
      for (final skill in deps.skillRegistry.state.activeSkills) {
        await deps.skillRegistry.setSkillEnabled(skill.id, false);
      }
      await tester.pumpWidget(LlamadartStudioApp(dependencies: deps));
      await tester.pumpAndSettle();
      Future<void> tap(String key) async {
        if (find.byType(SnackBar).evaluate().isNotEmpty) {
          await Future<void>.delayed(const Duration(seconds: 5));
          await tester.pumpAndSettle();
        }
        final f = find.byKey(Key(key));
        await tester.ensureVisible(f);
        await tester.pumpAndSettle();
        await tester.tap(f);
        await tester.pump(const Duration(milliseconds: 100));
      }

      Future<void> waitFor(bool Function() done, String phase) async {
        final deadline = DateTime.now().add(const Duration(seconds: 90));
        while (!done() && DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 100));
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        final completed = done();
        if (!completed) {
          final coding = deps.codingController.activeStreamStore.state;
          final diagnostic = <String, Object?>{
            'phase': phase,
            'runtimeReady': inference.runtimeStore.state.isReady,
            'chatGenerating':
                deps.chatController.activeStreamStore.state.isGenerating,
            'codingGenerating': coding.isGenerating,
            'codingTokens': coding.tokensGenerated,
            'codingTextLength': coding.text.length,
            'codingThinkingLength': coding.thinkingText.length,
            'codingToolCount': coding.toolInvocations.length,
            'codingReadCalls': coding.toolInvocations
                .where((t) => t.name == 'read')
                .length,
            'codingRunningTools': coding.toolInvocations
                .where((t) => t.isRunning)
                .length,
            'codingFailedTools': coding.toolInvocations
                .where((t) => t.isError)
                .length,
            'codingHasError': deps.codingController.state.lastError != null,
            'thinkingEnabled':
                deps.shellController.currentSettings.thinkingEnabled,
            'maxTokens': deps.shellController.currentSettings.maxTokens,
          };
          debugPrint('UI_ACCEPTANCE_TIMEOUT ${jsonEncode(diagnostic)}');
        }
        expect(completed, isTrue, reason: phase);
        await tester.pump(const Duration(milliseconds: 300));
        expect(tester.takeException(), isNull, reason: phase);
        debugPrint('UI_ACCEPTANCE $phase passed');
      }

      await tap('nav_workspace_models');
      await tester.enterText(
        find.byKey(const Key('model_hub_search_field')),
        'qwen3.5 0.8b',
      );
      await tester.pumpAndSettle();
      await tap('activate_model_qwen3.5-0.8b-q4-k-m');
      await waitFor(() => inference.runtimeStore.state.isReady, 'model load');
      // Model Hub applies the model preset; select the acceptance tuning after it.
      await deps.shellController.updateSettings(
        (s) => s.copyWith(
          maxTokens: 192,
          temperature: 0,
          topK: 40,
          topP: 0.9,
          penalty: 1.1,
          thinkingEnabled: false,
        ),
      );
      await Future<void>.delayed(const Duration(seconds: 5));
      await tester.pump();
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('chat_composer_input')),
        'What is 2 + 2? Reply with just the digit.',
      );
      await tap('chat_send_button');
      await waitFor(
        () =>
            !deps.chatController.activeStreamStore.state.isGenerating &&
            deps.chatController.state.activeConversation!.activeBranch.length >=
                2,
        'Chat answer',
      );
      expect(deps.chatController.state.lastTurnError, isNull);
      expect(
        deps.chatController.state.activeConversation!.activeBranch.last.text
            .trim(),
        '4',
      );
      await tap('nav_workspace_notes');
      await tap('vault_new_note_button');
      await tester.enterText(
        find.byKey(const Key('vault_note_title_input')),
        'Meetup details',
      );
      await tester.enterText(
        find.byKey(const Key('vault_note_content_input')),
        'The Flutter meetup is in Montreal on Thursday. The check-in code is MAPLE-4827.',
      );
      await tap('vault_save_note_button');
      await tester.ensureVisible(find.text('Ask notebook'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ask notebook'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Search settings'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Search settings'));
      await tester.pumpAndSettle();
      await tap('notebook_embedder_chip_nomic-embed-text-v1.5-q8-0');
      await waitFor(
        () => deps.labModelCoordinator.state.loadedLabModels.containsKey(
          StudioModelSpecialty.embedding,
        ),
        'embedder load',
      );
      await tap('vault_index_notes_button');
      await waitFor(() => !deps.notebookController.state.isBusy, 'index notes');
      await tester.enterText(
        find.byKey(const Key('vault_search_input')),
        'What is the meetup check-in code?',
      );
      await tap('notebook_ask_button');
      await waitFor(
        () => !deps.notebookController.state.isAnsweringNotebook,
        'Notes generated answer',
      );
      expect(deps.notebookController.state.errorMessage, isNull);
      expect(
        deps.notebookController.state.notebookAnswerText,
        contains('MAPLE-4827'),
      );
      await tap('nav_workspace_coding');
      await tester.enterText(
        find.byKey(const Key('coding_prompt_input')),
        'Use the read tool to open release.txt. Report the exact release confirmation token. Do not modify files or run commands.',
      );
      await tap('coding_send_button');
      await waitFor(
        () => !deps.codingController.activeStreamStore.state.isGenerating,
        'Coding read tool',
      );
      expect(deps.codingController.state.lastError, isNull);
      final answer = deps.codingController.state.messages.last;
      expect(answer.text, contains('MONTREAL-4827'));
      expect(
        answer.toolCalls.any(
          (t) =>
              t.name == 'read' &&
              (t.resultJson?.contains('MONTREAL-4827') ?? false),
        ),
        isTrue,
      );
      expect(
        await source.readAsString(),
        'The release confirmation token is MONTREAL-4827.\n',
      );
      await tap('nav_workspace_image');
      await tap('load_image_pipeline_button');
      await waitFor(
        () => !deps.imageController.state.isLoadingModel,
        'Image load',
      );
      expect(deps.imageController.state.errorMessage, isNull);
      await tap('generate_image_button');
      await waitFor(
        () => !deps.imageController.state.isGenerating,
        'Image generate',
      );
      expect(deps.imageController.state.errorMessage, isNull);
      expect(deps.imageController.state.gallery, hasLength(1));
    },
    skip: chatPath == null || embedPath == null || imagePath == null,
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
