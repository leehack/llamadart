@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

import 'studio_test_fakes.dart';

// Actual SDK tool schemas with deterministic Qwen-family XML emissions. The
// Qwen3.8 preset uses the recorded Qwen3.5 family template fixture here; this
// verifies adapter admission, not inference on Qwen3.8 weights/template assets.
void main() {
  late Directory root;
  late McpManager manager;
  late InMemoryKeyValueStore kv;
  setUpAll(() async {
    root = await Directory.systemTemp.createTemp('studio_default_mcp_');
    await File(
      '${root.path}/release.txt',
    ).writeAsString('needle release proof');
    await File('${root.path}/model.gguf').writeAsBytes([71, 71, 85, 70]);
    kv = InMemoryKeyValueStore();
    manager = McpManager(keyValueStore: kv);
    await manager.saveServer(
      McpServerConfig(
        id: McpManager.builtInDartFlutterServerId,
        name: 'Dart & Flutter MCP',
        transportType: McpTransportType.stdio,
        command: Platform.resolvedExecutable,
        args: const ['mcp-server'],
        workingDirectory: root.path,
        origin: McpServerOrigin.builtIn,
        disabledTools: McpManager.defaultDisabledBuiltInDartTools,
      ),
    );
    await manager.connectServer(McpManager.builtInDartFlutterServerId);
  });
  tearDownAll(() async {
    await manager.dispose();
    await root.delete(recursive: true);
  });

  for (final modelId in ['qwen3.5-0.8b-q4-k-m', 'qwen3.8-27b-ud-q4-k-xl']) {
    test(
      '$modelId default MCP retains compatible tools and Core search',
      () async {
        final backend = _DefaultMcpBackend();
        final inference = DirectLlamaInferencePort(backend: backend);
        final shell = StudioShellController(keyValueStore: kv);
        final skills = SkillRegistry(keyValueStore: kv);
        final coding = CodingWorkspaceController(
          inferencePort: inference,
          shellController: shell,
          keyValueStore: kv,
          mcpManager: manager,
          skillRegistry: skills,
          autoConnectWorkspaceMcp: false,
        );
        addTearDown(() async {
          await coding.dispose();
          await skills.dispose();
          await inference.dispose();
          await shell.dispose();
        });
        await shell.initialize();
        const settings = StudioSettings(
          thinkingEnabled: false,
          toolsEnabled: true,
          enabledBuiltInTools: [],
        );
        await shell.updateSettings((_) => settings);
        await inference.loadModel(
          assets: ResolvedModelAssets(
            descriptor: CuratedModelCatalog.byId(modelId)!,
            primarySource: ModelSource.path('${root.path}/model.gguf'),
          ),
          settings: settings,
          isWeb: false,
        );
        await coding.setWorkspaceRoot(root.path);
        expect(manager.state.servers.single.tools, hasLength(14));
        expect(manager.state.activeTools.map((t) => t.name).toSet(), {
          'rip_grep_packages',
          'read_package_uris',
          'pub_dev_search',
          'pub',
          'roots',
          'analyze_files',
          'lsp',
        });
        await coding.sendCodingPrompt(
          'Use grep to find needle in the workspace.',
        );
        expect(coding.state.lastError, isNull);
        final calls = coding.state.messages.last.toolCalls;
        expect(calls.single.name, 'grep');
        expect(calls.single.resultJson, contains('needle release proof'));
        final notices = coding.state.toolAvailabilityNotices;
        expect(notices.where((n) => n.isUnavailable).map((n) => n.toolName), [
          'rip_grep_packages',
        ]);
        expect(
          notices.where((n) => !n.isUnavailable).map((n) => n.toolName).toSet(),
          {'pub', 'analyze_files'},
        );
        expect(notices.every((n) => n.reason.contains('model')), isTrue);
        final prompt = backend.prompts.first;
        expect(prompt, contains('analyze_files'));
        expect(prompt, contains('pub_dev_search'));
        expect(prompt, contains('read_package_uris'));
        expect(prompt, contains('grep'));
        print(
          'STUDIO_DEFAULT_MCP modelPreset=$modelId server=${manager.state.servers.single.serverVersion} active=7 admitted=6 unavailable=rip_grep_packages restricted=pub,analyze_files coreSearch=grep',
        );
        coding.clearSession();
        expect(coding.state.toolAvailabilityNotices, isEmpty);
      },
    );
  }
}

class _DefaultMcpBackend extends FakeSpeculativeFallbackBackend {
  final prompts = <String>[];
  int replies = 0;

  @override
  Future<Map<String, String>> modelMetadata(int modelHandle) async => {
    'general.architecture': 'qwen35',
    'tokenizer.chat_template': File(
      '../../test/fixtures/templates/Qwen3_5-0_8B.jinja',
    ).readAsStringSync(),
  };

  @override
  Stream<List<int>> generate(
    int contextHandle,
    String prompt,
    GenerationParams params, {
    List<LlamaContentPart>? parts,
  }) async* {
    prompts.add(prompt);
    yield utf8.encode(
      replies++ == 0
          ? '<tool_call>\n<function=grep>\n<parameter=query>\nneedle\n</parameter>\n</function>\n</tool_call>'
          : 'Found needle release proof in release.txt.',
    );
  }
}
