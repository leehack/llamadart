import 'dart:convert';
import 'dart:io';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

import 'studio_test_fakes.dart';

const _settings = StudioSettings(thinkingEnabled: false, toolsEnabled: true);
const _read = '<|tool_call>call:read{"path":"release.txt"}<tool_call|>';

void main() {
  late Directory directory;
  late _IdentityBackend backend;
  late DirectLlamaInferencePort port;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('studio_tool_identity_');
    await File('${directory.path}/release.txt').writeAsString('release token');
    final file = await File(
      '${directory.path}/model.gguf',
    ).writeAsBytes(<int>[0x47, 0x47, 0x55, 0x46]);
    backend = _IdentityBackend();
    port = DirectLlamaInferencePort(backend: backend);
    await port.loadModel(
      assets: ResolvedModelAssets(
        descriptor: StudioModelDescriptor(
          id: 'test',
          name: 'Test',
          description: 'Scripted tool identity model',
          category: StudioModelCategory.chat,
          filename: 'model.gguf',
          sourceUri: file.path,
        ),
        primarySource: ModelSource.path(file.path),
      ),
      settings: _settings,
      isWeb: false,
    );
  });

  tearDown(() async {
    await port.dispose();
    await directory.delete(recursive: true);
  });

  for (final finalOutput in <String>['complete', '']) {
    test(
      'sequential calls retain live and ${finalOutput.isEmpty ? 'failed' : 'completed'} Coding records',
      () async {
        backend.outputs.addAll(<String>[
          _read,
          finalOutput.isEmpty ? _read : 'second inspection $_read',
          finalOutput,
        ]);
        final kv = InMemoryKeyValueStore();
        final shell = StudioShellController(keyValueStore: kv);
        final mcp = McpManager(keyValueStore: kv);
        final skills = SkillRegistry(keyValueStore: kv);
        await shell.initialize();
        await shell.updateSettings((_) => _settings);
        final coding = CodingWorkspaceController(
          inferencePort: port,
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
          await shell.dispose();
        });
        await coding.setWorkspaceRoot(directory.path);
        final live = <List<StudioToolInvocation>>[];
        final subscription = coding.activeStreamStore.stream.listen((state) {
          if (state.isGenerating && state.toolInvocations.isNotEmpty) {
            live.add(state.toolInvocations);
          }
        });
        try {
          await coding.sendCodingPrompt('Read release.txt twice.');
        } finally {
          await subscription.cancel();
        }
        expect(
          coding.state.lastError,
          finalOutput.isEmpty ? contains('no visible answer') : isNull,
        );
        final finalCalls = coding.state.messages.last.toolCalls;
        expect(finalCalls, hasLength(2));
        expect(live.last, hasLength(2));
        expect(
          live.last.map((call) => call.id),
          finalCalls.map((call) => call.id),
        );
        expect(finalCalls.map((call) => call.id).toSet(), hasLength(2));
        expect(live.last.every((call) => !call.isRunning), isTrue);
        expect(
          live.last.every((call) => call.resultJson!.contains('release token')),
          isTrue,
        );
        _expectMatchedHistory(backend.prompts.last, finalCalls);
        if (finalOutput.isNotEmpty) {
          final assistant = (jsonDecode(backend.prompts.last) as List)
              .cast<Map<String, dynamic>>()
              .where((message) => message['role'] == 'assistant')
              .last;
          expect(assistant['content'], contains('second inspection'));
        }
      },
    );
  }

  test(
    'unique explicit IDs survive collisions and same-round reservations',
    () async {
      backend.outputs.addAll(<String>[
        jsonEncode(<Object>[_call('explicit')]),
        jsonEncode(<Object>[
          _call('explicit'),
          _call('call_2_0'),
          _call('other'),
        ]),
        'complete',
      ]);
      final events = await port
          .streamTurn(
            StudioTurnRequest(
              history: <StudioMessage>[
                StudioMessage(
                  id: 'user',
                  role: StudioRole.user,
                  text: 'Read',
                  createdAt: DateTime.utc(2026),
                ),
              ],
              settings: _settings,
              includeBuiltInTools: false,
              extraTools: <ToolDefinition>[
                ToolDefinition(
                  name: 'read',
                  description: 'Reads',
                  parameters: const [],
                  handler: (_) async => 'result',
                ),
              ],
            ),
          )
          .toList();
      final calls = events
          .whereType<StudioTurnCompletedEvent>()
          .single
          .result
          .toolInvocations;
      expect(calls.map((call) => call.id).toSet(), hasLength(4));
      expect(calls[0].id, 'explicit');
      expect(calls[2].id, 'call_2_0');
      expect(calls[3].id, 'other');
      final running = events
          .whereType<StudioToolInvocationEvent>()
          .where((event) => event.invocation.isRunning)
          .map((event) => event.invocation.id);
      final finished = events
          .whereType<StudioToolInvocationEvent>()
          .where((event) => !event.invocation.isRunning)
          .map((event) => event.invocation.id);
      expect(running, calls.map((call) => call.id));
      expect(finished, running);
      _expectMatchedHistory(backend.prompts.last, calls);
    },
  );
}

Map<String, Object?> _call(String id) => <String, Object?>{
  'id': id,
  'type': 'function',
  'function': <String, Object?>{
    'name': 'read',
    'arguments': <String, Object?>{},
  },
};

void _expectMatchedHistory(String prompt, List<StudioToolInvocation> calls) {
  final messages = (jsonDecode(prompt) as List).cast<Map<String, dynamic>>();
  final assistantIds = <String>[
    for (final message in messages)
      for (final call in message['tool_calls'] as List? ?? const [])
        call['id'] as String,
  ];
  final resultIds = <String>[
    for (final message in messages)
      if (message['role'] == 'tool') message['tool_call_id'] as String,
  ];
  expect(assistantIds, calls.map((call) => call.id));
  expect(resultIds, assistantIds);
}

class _IdentityBackend extends FakeSpeculativeFallbackBackend {
  final outputs = <String>[];
  final prompts = <String>[];

  @override
  Future<Map<String, String>> modelMetadata(
    int modelHandle,
  ) async => <String, String>{
    'general.architecture': 'gemma4',
    'tokenizer.chat_template':
        '{#- OpenAI Chat Completions: <|turn> <turn|> #}{{ messages | tojson }}',
  };

  @override
  Stream<List<int>> generate(
    int contextHandle,
    String prompt,
    GenerationParams params, {
    List<LlamaContentPart>? parts,
  }) {
    prompts.add(prompt);
    final output = outputs.removeAt(0);
    Stream<List<int>> generateOutput() async* {
      yield utf8.encode(output);
    }

    return generateOutput();
  }
}
