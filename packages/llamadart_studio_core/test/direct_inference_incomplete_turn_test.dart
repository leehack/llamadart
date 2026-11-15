import 'dart:convert';
import 'dart:io';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/backend.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

import 'studio_test_fakes.dart';

const _settings = StudioSettings(thinkingEnabled: false);
const _readCall = '<|tool_call>call:read{"path":"release.txt"}<tool_call|>';

void main() {
  late Directory directory;
  late _ScriptedBackend backend;
  late DirectLlamaInferencePort port;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('studio_incomplete_');
    final file = await File(
      '${directory.path}/model.gguf',
    ).writeAsBytes(<int>[0x47, 0x47, 0x55, 0x46]);
    backend = _ScriptedBackend();
    port = DirectLlamaInferencePort(backend: backend);
    await port.loadModel(
      assets: ResolvedModelAssets(
        descriptor: StudioModelDescriptor(
          id: 'test',
          name: 'Test',
          description: 'Scripted tool-calling model',
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

  ToolDefinition readTool({bool fails = false}) => ToolDefinition(
    name: 'read',
    description: 'Reads the release token',
    parameters: <ToolParam>[ToolParam.string('path', required: true)],
    handler: (_) async {
      if (fails) throw LlamaArgumentException('Invalid file path.');
      return 'MONTREAL-4827';
    },
  );

  test(
    'tool round exhaustion reports failure and retains streamed errors',
    () async {
      backend.outputs.addAll(<({String text, bool limited})>[
        for (var i = 0; i < 3; i++) (text: _readCall, limited: false),
      ]);
      final events = <StudioTurnEvent>[];
      await expectLater(
        port.streamTurn(_request(readTool(fails: true), 2)).forEach(events.add),
        throwsA(
          isA<LlamaInferenceException>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('tool round limit'),
              contains('simplify the prompt'),
              contains('Review the tool results'),
            ),
          ),
        ),
      );
      expect(backend.rounds, 3);
      final results = events.whereType<StudioToolInvocationEvent>().where(
        (event) => !event.invocation.isRunning,
      );
      expect(results, hasLength(2));
      expect(results.every((event) => event.invocation.isError), isTrue);
      expect(results.last.invocation.resultJson, contains('Invalid file path'));
      expect(events.whereType<StudioTurnCompletedEvent>(), isEmpty);
      expect(port.isBusy, isFalse);
    },
  );

  test(
    'successful tool followed by empty reply reports failure with its result',
    () async {
      backend.outputs.addAll(<({String text, bool limited})>[
        (text: _readCall, limited: false),
        (text: '', limited: false),
      ]);
      final events = <StudioTurnEvent>[];
      await expectLater(
        port.streamTurn(_request(readTool())).forEach(events.add),
        throwsA(
          isA<LlamaInferenceException>().having(
            (error) => error.message,
            'message',
            contains('no visible answer'),
          ),
        ),
      );
      final result = events
          .whereType<StudioToolInvocationEvent>()
          .last
          .invocation;
      expect(result.isError, isFalse);
      expect(result.resultJson, contains('MONTREAL-4827'));
      expect(events.whereType<StudioTurnCompletedEvent>(), isEmpty);
      expect(port.isBusy, isFalse);
    },
  );

  test('empty response without tools reports an actionable failure', () async {
    backend.outputs.add((text: '', limited: false));
    await expectLater(
      port.streamTurn(_request()).toList(),
      throwsA(
        isA<LlamaInferenceException>().having(
          (error) => error.message,
          'message',
          allOf(contains('no visible answer'), contains('retry')),
        ),
      ),
    );
  });

  test(
    'incomplete token-limited tool call recommends increasing output limit',
    () async {
      backend.outputs.add((
        text: '<|tool_call>call:read{"path":',
        limited: true,
      ));
      final events = <StudioTurnEvent>[];
      await expectLater(
        port.streamTurn(_request(readTool())).forEach(events.add),
        throwsA(
          isA<LlamaInferenceException>().having(
            (error) => error.message,
            'message',
            contains('Increase the output token limit'),
          ),
        ),
      );
      expect(backend.reportedLimit, BackendGenerationLimit.maxTokens);
      expect(events.whereType<StudioToolInvocationEvent>(), isEmpty);
      expect(events.whereType<StudioTurnCompletedEvent>(), isEmpty);
    },
  );

  for (final prefix in <String>['', 'partial answer']) {
    test(
      'cancelled ${prefix.isEmpty ? 'empty' : 'partial'} turn remains completed',
      () async {
        backend.outputs.add((text: '$prefix$_readCall', limited: false));
        final events = <StudioTurnEvent>[];
        await for (final event in port.streamTurn(_request(readTool()))) {
          events.add(event);
          if (event is StudioToolInvocationEvent &&
              event.invocation.isRunning) {
            port.cancelGeneration();
          }
        }
        final result = events
            .whereType<StudioTurnCompletedEvent>()
            .single
            .result;
        expect(result.text, prefix);
        expect(result.toolInvocations.single.isError, isTrue);
        expect(result.toolInvocations.single.resultJson, contains('cancelled'));
        expect(backend.rounds, 1);
      },
    );
  }

  test('valid tool completion still returns the model answer', () async {
    backend.outputs.addAll(<({String text, bool limited})>[
      (text: _readCall, limited: false),
      (text: 'The token is MONTREAL-4827.', limited: false),
    ]);
    final events = await port.streamTurn(_request(readTool())).toList();
    final result = events.whereType<StudioTurnCompletedEvent>().single.result;
    expect(result.text, 'The token is MONTREAL-4827.');
    expect(result.toolInvocations.single.isError, isFalse);
    expect(result.toolInvocations.single.resultJson, contains('MONTREAL-4827'));
    expect(backend.rounds, 2);
  });
}

StudioTurnRequest _request([ToolDefinition? tool, int maxToolRounds = 5]) =>
    StudioTurnRequest(
      history: <StudioMessage>[
        StudioMessage(
          id: 'user',
          role: StudioRole.user,
          text: 'Read the release token.',
          createdAt: DateTime.utc(2026),
        ),
      ],
      settings: _settings,
      includeBuiltInTools: false,
      extraTools: tool == null
          ? const <ToolDefinition>[]
          : <ToolDefinition>[tool],
      maxToolRounds: maxToolRounds,
    );

class _ScriptedBackend extends FakeSpeculativeFallbackBackend
    implements BackendGenerationLimitReporting {
  final List<({String text, bool limited})> outputs =
      <({String text, bool limited})>[];
  final Expando<BackendGenerationLimit> _limits =
      Expando<BackendGenerationLimit>();
  int rounds = 0;
  BackendGenerationLimit? reportedLimit;

  @override
  Future<Map<String, String>> modelMetadata(
    int modelHandle,
  ) async => <String, String>{
    'general.architecture': 'gemma4',
    'tokenizer.chat_template':
        '<|turn>user\n{{ messages[0]["content"] }}<turn|>{% if add_generation_prompt %}<|turn>model\n{% endif %}',
  };

  @override
  Stream<List<int>> generate(
    int contextHandle,
    String prompt,
    GenerationParams params, {
    List<LlamaContentPart>? parts,
  }) {
    final output = outputs.removeAt(0);
    late final Stream<List<int>> generation;
    Stream<List<int>> generateOutput() async* {
      rounds++;
      await Future<void>.delayed(const Duration(milliseconds: 1));
      yield utf8.encode(output.text);
      if (output.limited) {
        _limits[generation] = BackendGenerationLimit.maxTokens;
      }
    }

    generation = generateOutput();
    return generation;
  }

  @override
  BackendGenerationLimit? generationLimitOf(Stream<List<int>> generation) =>
      reportedLimit = _limits[generation];
}
