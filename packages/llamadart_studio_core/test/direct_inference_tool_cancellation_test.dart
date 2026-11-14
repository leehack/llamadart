import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

import 'studio_test_fakes.dart';

const _settings = StudioSettings(toolsEnabled: true, thinkingEnabled: false);

void main() {
  late Directory directory;
  late _ToolBackend backend;
  late DirectLlamaInferencePort port;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('studio_tool_cancel_');
    final file = await File(
      '${directory.path}/model.gguf',
    ).writeAsBytes(<int>[0x47, 0x47, 0x55, 0x46]);
    backend = _ToolBackend();
    port = DirectLlamaInferencePort(backend: backend);
    await port.loadModel(
      assets: ResolvedModelAssets(
        descriptor: StudioModelDescriptor(
          id: 'test',
          name: 'Test',
          description: 'Fake tool-calling model',
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

  test(
    'Stop at the running event skips dispatch and permits the next turn',
    () async {
      var calls = 0;
      final tool = ToolDefinition(
        name: 'first',
        description: 'Records dispatch',
        parameters: const [],
        handler: (_) async {
          calls++;
          return 'executed';
        },
      );
      backend.outputs.add('partial<|tool_call>call:first{}<tool_call|>');
      final events = <StudioTurnEvent>[];
      await for (final event in port.streamTurn(
        _request(<ToolDefinition>[tool]),
      )) {
        events.add(event);
        if (event is StudioToolInvocationEvent && event.invocation.isRunning) {
          port.cancelGeneration();
        }
      }
      expect(calls, 0);
      expect(backend.rounds, 1);
      final completed = events
          .whereType<StudioTurnCompletedEvent>()
          .single
          .result;
      expect(completed.text, 'partial');
      expect(completed.toolInvocations.single.isRunning, isFalse);
      expect(completed.toolInvocations.single.isError, isTrue);
      expect(
        completed.toolInvocations.single.resultJson,
        contains('cancelled'),
      );

      backend.outputs.addAll(<String>[
        '<|tool_call>call:first{}<tool_call|>',
        'next answer',
      ]);
      final nextEvents = await port
          .streamTurn(_request(<ToolDefinition>[tool]))
          .toList();
      expect(calls, 1);
      expect(backend.rounds, 3);
      final next = nextEvents
          .whereType<StudioTurnCompletedEvent>()
          .single
          .result;
      expect(next.text, 'next answer');
      expect(next.toolInvocations.single.resultJson, contains('executed'));
    },
  );

  test('without Stop both tools run before the continuation', () async {
    final calls = <String>[];
    backend.outputs.addAll(<String>[
      '<|tool_call>call:first{}<tool_call|>'
          '<|tool_call>call:second{}<tool_call|>',
      'complete',
    ]);
    final events = await port
        .streamTurn(
          _request(<ToolDefinition>[
            for (final name in <String>['first', 'second'])
              ToolDefinition(
                name: name,
                description: 'Records dispatch',
                parameters: const [],
                handler: (_) async {
                  calls.add(name);
                  return 'executed';
                },
              ),
          ]),
        )
        .toList();
    expect(calls, <String>['first', 'second']);
    expect(backend.rounds, 2);
    final completed = events
        .whereType<StudioTurnCompletedEvent>()
        .single
        .result;
    expect(completed.text, 'complete');
    expect(completed.toolInvocations.length, 2);
  });

  test(
    'Stop during a handler keeps its result and skips other tools and rounds',
    () async {
      final entered = Completer<void>();
      final release = Completer<String>();
      var firstCalls = 0;
      var secondCalls = 0;
      final tools = <ToolDefinition>[
        ToolDefinition(
          name: 'first',
          description: 'Waits until released',
          parameters: const [],
          handler: (_) {
            firstCalls++;
            entered.complete();
            return release.future;
          },
        ),
        ToolDefinition(
          name: 'second',
          description: 'Must not run after Stop',
          parameters: const [],
          handler: (_) async {
            secondCalls++;
            return 'unexpected';
          },
        ),
      ];
      backend.outputs.add(
        'partial<|tool_call>call:first{}<tool_call|>'
        '<|tool_call>call:second{}<tool_call|>',
      );
      final pendingEvents = port.streamTurn(_request(tools)).toList();
      await entered.future;
      port.cancelGeneration();
      release.complete('finished in flight');
      final events = await pendingEvents;
      expect(firstCalls, 1);
      expect(secondCalls, 0);
      expect(backend.rounds, 1);
      final completed = events
          .whereType<StudioTurnCompletedEvent>()
          .single
          .result;
      expect(completed.text, 'partial');
      final invocation = completed.toolInvocations.single;
      expect(invocation.name, 'first');
      expect(invocation.isRunning, isFalse);
      expect(invocation.isError, isFalse);
      expect(invocation.resultJson, contains('finished in flight'));
      expect(
        events
            .whereType<StudioToolInvocationEvent>()
            .last
            .invocation
            .resultJson,
        contains('finished in flight'),
      );
    },
  );
}

StudioTurnRequest _request(List<ToolDefinition> tools) => StudioTurnRequest(
  history: <StudioMessage>[
    StudioMessage(
      id: 'user',
      role: StudioRole.user,
      text: 'Use the tools',
      createdAt: DateTime.utc(2026),
    ),
  ],
  settings: _settings,
  systemPrompt: '',
  includeBuiltInTools: false,
  extraTools: tools,
);

class _ToolBackend extends FakeSpeculativeFallbackBackend {
  final List<String> outputs = <String>[];
  int rounds = 0;

  @override
  Future<Map<String, String>> modelMetadata(int modelHandle) async =>
      <String, String>{
        'general.architecture': 'gemma4',
        'tokenizer.chat_template':
            '<|turn>user\n{{ messages[0]["content"] }}<turn|>'
            '{% if add_generation_prompt %}<|turn>model\n{% endif %}',
      };

  @override
  Stream<List<int>> generate(
    int contextHandle,
    String prompt,
    GenerationParams params, {
    List<LlamaContentPart>? parts,
  }) async* {
    rounds++;
    yield utf8.encode(
      outputs.isEmpty ? 'unexpected continuation' : outputs.removeAt(0),
    );
  }
}
