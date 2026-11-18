import 'dart:convert';
import 'dart:io';

import 'package:llamadart/backend.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

import 'studio_test_fakes.dart';

void main() {
  late Directory directory;
  late DirectLlamaInferencePort port;
  late _FallbackBackend backend;
  const settings = StudioSettings(
    thinkingEnabled: false,
    toolsEnabled: true,
    enabledBuiltInTools: [],
  );
  var invoked = 0;
  List<ToolDefinition> tools() => [
    for (final name in ['first', 'second', 'third'])
      ToolDefinition(
        name: name,
        description: 'Fixture tool',
        parameters: const [],
        handler: (_) async {
          invoked++;
          return 'result';
        },
      ),
  ];
  Future<void> load({
    required bool toolSupport,
    int rejectedPrompts = 0,
  }) async {
    backend = _FallbackBackend(toolSupport, rejectedPrompts);
    port = DirectLlamaInferencePort(backend: backend);
    await port.loadModel(
      assets: ResolvedModelAssets(
        descriptor: StudioModelDescriptor(
          id: 'fallback',
          name: 'Fallback fixture',
          description: 'Scripted capability and context failures',
          category: StudioModelCategory.chat,
          filename: 'model.gguf',
          sourceUri: '${directory.path}/model.gguf',
        ),
        primarySource: ModelSource.path('${directory.path}/model.gguf'),
      ),
      settings: settings,
      isWeb: false,
    );
  }

  StudioTurnRequest request({
    ToolChoice choice = ToolChoice.auto,
    String? name,
  }) => StudioTurnRequest(
    history: [
      StudioMessage(
        id: 'user',
        role: StudioRole.user,
        text: 'Use tools if available.',
        createdAt: DateTime.utc(2026),
      ),
    ],
    settings: settings,
    extraTools: tools(),
    includeBuiltInTools: false,
    toolChoice: choice,
    requiredToolName: name,
  );
  setUp(() async {
    invoked = 0;
    directory = await Directory.systemTemp.createTemp('studio_fallback_');
    await File('${directory.path}/model.gguf').writeAsBytes([71, 71, 85, 70]);
  });
  tearDown(() async {
    await port.dispose();
    await directory.delete(recursive: true);
  });

  test('runtime without tools reports every automatic omission', () async {
    await load(toolSupport: false);
    final events = await port.streamTurn(request()).toList();
    final notices = events
        .whereType<StudioToolAvailabilityEvent>()
        .single
        .notices;
    expect(notices.map((n) => n.toolName), ['first', 'second', 'third']);
    expect(
      notices.every((n) => n.isUnavailable && n.reason.contains('runtime')),
      isTrue,
    );
    expect(events.whereType<StudioTurnCompletedEvent>(), hasLength(1));
    expect(invoked, 0);
    expect(backend.prompts, 1);
  });
  for (final name in <String?>[null, 'second']) {
    test(
      'unsupported runtime refuses required tool ($name) before generation',
      () async {
        await load(toolSupport: false);
        await expectLater(
          port
              .streamTurn(request(choice: ToolChoice.required, name: name))
              .drain<void>(),
          throwsA(isA<LlamaUnsupportedException>()),
        );
        expect(backend.prompts, 0);
        expect(invoked, 0);
      },
    );
  }
  test('context retries keep cumulative per-tool omission notices', () async {
    await load(toolSupport: true, rejectedPrompts: 2);
    final events = await port.streamTurn(request()).toList();
    final updates = events.whereType<StudioToolAvailabilityEvent>().toList();
    expect(updates, hasLength(2));
    expect(updates.last.notices.map((n) => n.toolName).toSet(), {
      'first',
      'second',
      'third',
    });
    expect(
      updates.last.notices.every((n) => n.reason.contains('context limit')),
      isTrue,
    );
    expect(events.whereType<StudioTurnCompletedEvent>(), hasLength(1));
    expect(backend.prompts, 3);
    expect(invoked, 0);
  });
  for (final name in <String?>[null, 'second']) {
    test(
      'context exhaustion refuses required tool ($name) without plain-text fallback',
      () async {
        await load(toolSupport: true, rejectedPrompts: 10);
        await expectLater(
          port
              .streamTurn(request(choice: ToolChoice.required, name: name))
              .drain<void>(),
          throwsA(isA<LlamaUnsupportedException>()),
        );
        expect(backend.prompts, name == null ? 2 : 1);
        expect(invoked, 0);
      },
    );
  }
}

class _FallbackBackend extends FakeSpeculativeFallbackBackend
    implements BackendChatScope {
  _FallbackBackend(this.supportsToolCalling, this.rejectedPrompts);
  @override
  final bool supportsToolCalling;
  @override
  bool get supportsMultiTurnChat => true;
  int rejectedPrompts;
  int prompts = 0;
  @override
  Future<Map<String, String>> modelMetadata(int modelHandle) async => {
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
  }) async* {
    prompts++;
    if (rejectedPrompts-- > 0) throw LlamaInferenceException('prompt too long');
    yield utf8.encode('No tool was called.');
  }
}
