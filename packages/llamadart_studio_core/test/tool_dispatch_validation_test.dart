import 'dart:convert';
import 'dart:io';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

import 'studio_test_fakes.dart';

void main() {
  late Directory directory;
  late File victim;
  late _DispatchBackend backend;
  late DirectLlamaInferencePort port;
  var handlerCalls = 0;
  const original = 'preserve existing user work';
  const settings = StudioSettings(
    thinkingEnabled: false,
    toolsEnabled: true,
    enabledBuiltInTools: [],
  );
  setUp(() async {
    handlerCalls = 0;
    directory = await Directory.systemTemp.createTemp('studio_dispatch_');
    victim = await File('${directory.path}/victim.txt').writeAsString(original);
    final file = await File(
      '${directory.path}/model.gguf',
    ).writeAsBytes([71, 71, 85, 70]);
    backend = _DispatchBackend();
    port = DirectLlamaInferencePort(backend: backend);
    await port.loadModel(
      assets: ResolvedModelAssets(
        descriptor: StudioModelDescriptor(
          id: 'dispatch',
          name: 'Dispatch fixture',
          description: 'Untrusted model tool emissions',
          category: StudioModelCategory.chat,
          filename: 'model.gguf',
          sourceUri: file.path,
        ),
        primarySource: ModelSource.path(file.path),
      ),
      settings: settings,
      isWeb: false,
    );
  });
  tearDown(() async {
    await port.dispose();
    await directory.delete(recursive: true);
  });

  Future<StudioToolInvocation> invoke(Map<String, Object?> arguments) async {
    backend.outputs.addAll([
      jsonEncode([
        {
          'type': 'function',
          'function': {'name': 'mutate', 'arguments': arguments},
        },
      ]),
      'Finished.',
    ]);
    final tool = ToolDefinition(
      name: 'mutate',
      description: 'A legacy tool with external side effects',
      parameters: [
        ToolParam.string('path', required: true),
        ToolParam.string('content', required: true),
        ToolParam.object(
          'options',
          properties: [ToolParam.integer('count', required: true)],
        ),
        ToolParam.array('labels', itemType: ToolParam.string('label')),
      ],
      handler: (params) async {
        handlerCalls++;
        // Intentionally unsafe fallback: validation belongs before dispatch.
        await victim.writeAsString(params.getString('content') ?? '');
        return {'written': true};
      },
    );
    final events = await port
        .streamTurn(
          StudioTurnRequest(
            history: [
              StudioMessage(
                id: 'user',
                role: StudioRole.user,
                text: 'Make the authorized change.',
                createdAt: DateTime.utc(2026),
              ),
            ],
            settings: settings,
            includeBuiltInTools: false,
            extraTools: [tool],
          ),
        )
        .toList();
    return events
        .whereType<StudioTurnCompletedEvent>()
        .single
        .result
        .toolInvocations
        .single;
  }

  final invalidArguments = <String, Map<String, Object?>>{
    'missing required content': {'path': 'victim.txt'},
    'wrong content type': {'path': 'victim.txt', 'content': 42},
    'wrong path type': {'path': false, 'content': 'overwrite'},
    'unknown top-level property': {
      'path': 'victim.txt',
      'content': 'overwrite',
      'unexpected': true,
    },
    'missing nested required field': {
      'path': 'victim.txt',
      'content': 'overwrite',
      'options': <String, Object?>{},
    },
    'wrong nested type': {
      'path': 'victim.txt',
      'content': 'overwrite',
      'options': {'count': 'one'},
    },
    'unknown nested property': {
      'path': 'victim.txt',
      'content': 'overwrite',
      'options': {'count': 1, 'unexpected': true},
    },
    'wrong array item type': {
      'path': 'victim.txt',
      'content': 'overwrite',
      'labels': [true],
    },
  };
  for (final entry in invalidArguments.entries) {
    test(
      'legacy dispatch refuses ${entry.key} before external side effects',
      () async {
        final call = await invoke(entry.value);
        expect(handlerCalls, 0);
        expect(await victim.readAsString(), original);
        expect(call.isError, isTrue);
        expect(call.resultJson, contains('input schema'));
      },
    );
  }
  for (final content in ['', 'authorized replacement']) {
    test(
      'legacy dispatch accepts valid content including empty (${content.isEmpty})',
      () async {
        final call = await invoke({
          'path': 'victim.txt',
          'content': content,
          'options': {'count': 1},
          'labels': <String>[],
        });
        expect(handlerCalls, 1);
        expect(call.isError, isFalse);
        expect(await victim.readAsString(), content);
      },
    );
  }
  test('canonical open-property policy survives the dispatch guard', () async {
    await port.unloadModel();
    backend.useHermes = true;
    await port.loadModel(
      assets: ResolvedModelAssets(
        descriptor: StudioModelDescriptor(
          id: 'canonical',
          name: 'Hermes fixture',
          description: 'Qualified full-schema format',
          category: StudioModelCategory.chat,
          filename: 'model.gguf',
          sourceUri: '${directory.path}/model.gguf',
        ),
        primarySource: ModelSource.path('${directory.path}/model.gguf'),
      ),
      settings: settings,
      isWeb: false,
    );
    final canonical = ToolDefinition.fromJsonSchema(
      name: 'open',
      description: 'Canonical tool allowing extra fields',
      schema: {
        'type': 'object',
        'properties': {
          'content': {'type': 'string'},
        },
        'required': ['content'],
      },
      handler: (params) async {
        handlerCalls++;
        await victim.writeAsString(params.getRequiredString('content'));
        return params.raw;
      },
    );
    backend.outputs.addAll([
      '<tool_call>${jsonEncode({
        'name': 'open',
        'arguments': {'content': 'authorized', 'extra': true},
      })}</tool_call>',
      'Finished.',
    ]);
    final events = await port
        .streamTurn(
          StudioTurnRequest(
            history: [
              StudioMessage(
                id: 'user',
                role: StudioRole.user,
                text: 'Make the authorized change.',
                createdAt: DateTime.utc(2026),
              ),
            ],
            settings: settings,
            includeBuiltInTools: false,
            extraTools: [canonical],
          ),
        )
        .toList();
    expect(
      events
          .whereType<StudioTurnCompletedEvent>()
          .single
          .result
          .toolInvocations
          .single
          .isError,
      isFalse,
    );
    expect(handlerCalls, 1);
    expect(await victim.readAsString(), 'authorized');
  });
  for (final content in <String?>[null, '']) {
    test(
      'production Coding write validates content (empty=${content != null})',
      () async {
        final kv = InMemoryKeyValueStore();
        final shell = StudioShellController(keyValueStore: kv);
        final manager = McpManager(keyValueStore: kv);
        final skills = SkillRegistry(keyValueStore: kv);
        final coding = CodingWorkspaceController(
          inferencePort: port,
          shellController: shell,
          keyValueStore: kv,
          mcpManager: manager,
          skillRegistry: skills,
          autoConnectWorkspaceMcp: false,
        );
        addTearDown(() async {
          await coding.dispose();
          await manager.dispose();
          await skills.dispose();
          await shell.dispose();
        });
        await shell.initialize();
        await shell.updateSettings((_) => settings);
        await coding.setWorkspaceRoot(directory.path);
        backend.outputs.addAll([
          '<|tool_call>call:write${jsonEncode({'path': 'victim.txt', 'content': ?content})}<tool_call|>',
          'Finished.',
        ]);
        await coding.sendCodingPrompt('Make the authorized change.');
        expect(await victim.readAsString(), content ?? original);
        expect(
          coding.state.messages.last.toolCalls.single.isError,
          content == null,
        );
      },
    );
  }
}

class _DispatchBackend extends FakeSpeculativeFallbackBackend {
  final outputs = <String>[];
  bool useHermes = false;
  @override
  Future<Map<String, String>> modelMetadata(int modelHandle) async => {
    'general.architecture': 'gemma4',
    'tokenizer.chat_template': useHermes
        ? '{# <tool_call> #}{{ messages | tojson }}'
        : '{#- OpenAI Chat Completions: <|turn> <turn|> #}{{ messages | tojson }}',
  };
  @override
  Stream<List<int>> generate(
    int contextHandle,
    String prompt,
    GenerationParams params, {
    List<LlamaContentPart>? parts,
  }) async* {
    yield utf8.encode(outputs.removeAt(0));
  }
}
