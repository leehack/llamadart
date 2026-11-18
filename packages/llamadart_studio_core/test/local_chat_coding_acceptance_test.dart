@Tags(<String>['local-only'])
library;

import 'dart:io';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

void main() {
  final modelPath = Platform.environment['STUDIO_ACCEPTANCE_CHAT_MODEL'];
  test(
    'real local model answers Chat and reads a Coding workspace file',
    () async {
      expect(File(modelPath!).existsSync(), isTrue);
      final root = await Directory.systemTemp.createTemp(
        'studio_coding_accept_',
      );
      final file = File('${root.path}/release.txt');
      const token = 'MONTREAL-4827';
      await file.writeAsString('The release confirmation token is $token.\n');
      final kv = InMemoryKeyValueStore();
      final shell = StudioShellController(keyValueStore: kv);
      await shell.initialize();
      const settings = StudioSettings(
        computeDevice: ComputeDevice.cpu,
        gpuLayers: 0,
        autoTuneHardware: false,
        contextSize: 4096,
        requestedContextSize: 4096,
        numberOfThreads: 2,
        numberOfThreadsBatch: 2,
        maxTokens: 192,
        temperature: 0,
        thinkingEnabled: false,
        enabledBuiltInTools: <String>[],
      );
      await shell.updateSettings((_) => settings);
      final inference = DirectLlamaInferencePort();
      final mcp = McpManager(keyValueStore: kv);
      final skills = SkillRegistry(keyValueStore: kv);
      final coding = CodingWorkspaceController(
        inferencePort: inference,
        shellController: shell,
        keyValueStore: kv,
        mcpManager: mcp,
        skillRegistry: skills,
        autoConnectWorkspaceMcp: false,
      );
      addTearDown(() async {
        await coding.dispose();
        await skills.dispose();
        await mcp.dispose();
        await inference.dispose();
        await shell.dispose();
        await root.delete(recursive: true);
      });
      final watch = Stopwatch()..start();
      await inference.loadModel(
        assets: ResolvedModelAssets(
          descriptor: CuratedModelCatalog.byId('qwen3.5-0.8b-q4-k-m')!,
          primarySource: ModelSource.path(modelPath),
        ),
        settings: settings,
        isWeb: false,
      );
      expect(inference.runtimeStore.state.isReady, isTrue);
      StudioTurnResult? answer;
      await for (final event in inference.streamTurn(
        StudioTurnRequest(
          history: <StudioMessage>[
            StudioMessage(
              id: 'chat',
              role: StudioRole.user,
              text: 'What is 2 + 2? Reply with just the digit.',
              createdAt: DateTime.now(),
            ),
          ],
          settings: settings,
          systemPrompt: 'Answer briefly and accurately.',
          includeBuiltInTools: false,
          toolsEnabledOverride: false,
        ),
      )) {
        if (event is StudioTurnCompletedEvent) answer = event.result;
      }
      expect(answer, isNotNull);
      expect(answer!.text.trim(), '4');
      await coding.initialize(autoDetectDefaultRoot: false);
      await coding.setWorkspaceRoot(root.path);
      expect(coding.state.lastError, isNull);
      await coding.sendCodingPrompt(
        'Use the read tool to open release.txt. Report the exact release confirmation token from the file. Do not modify any files or run commands.',
      );
      expect(coding.state.lastError, isNull);
      final assistant = coding.state.messages.last;
      print(
        'REAL_CHAT_CODING chat=${answer.text} backend=${inference.runtimeStore.state.backendName} answer=${assistant.text} tools=${assistant.toolCalls.map((t) => '${t.name}:${t.resultJson}').join('|')} elapsedMs=${watch.elapsedMilliseconds}',
      );
      expect(assistant.isError, isFalse);
      expect(
        assistant.toolCalls.any(
          (t) => t.name == 'read' && (t.resultJson?.contains(token) ?? false),
        ),
        isTrue,
      );
      expect(assistant.text, contains(token));
      expect(
        await file.readAsString(),
        'The release confirmation token is $token.\n',
      );
      expect(
        root.listSync().whereType<File>().map((f) => f.uri.pathSegments.last),
        <String>['release.txt'],
      );
    },
    skip: modelPath == null
        ? 'Set STUDIO_ACCEPTANCE_CHAT_MODEL to an explicit local GGUF path.'
        : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
