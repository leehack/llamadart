import 'dart:io';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

import 'support/studio_structured_qualification.dart';

void main() {
  late Directory directory;
  late StructuredRecordingBackend backend;
  late DirectLlamaInferencePort port;
  var invoked = 0;
  const settings = StudioSettings(
    thinkingEnabled: false,
    toolsEnabled: true,
    enabledBuiltInTools: [],
  );
  ToolDefinition bounded() => ToolDefinition.fromJsonSchema(
    name: 'bounded',
    description: 'Needs nonempty inputs',
    schema: {
      'type': 'object',
      'additionalProperties': false,
      'properties': {
        'items': {
          'type': 'array',
          'minItems': 1,
          'items': {'type': 'string'},
        },
      },
      'required': ['items'],
    },
    handler: (_) async {
      invoked++;
      return 'must not execute';
    },
  );
  ToolDefinition compatible() => ToolDefinition(
    name: 'available',
    description: 'Compatible tool',
    parameters: const [],
    handler: (_) async {
      invoked++;
      return 'valid result';
    },
  );
  setUp(() async {
    invoked = 0;
    directory = await Directory.systemTemp.createTemp('studio_availability_');
    final file = await File(
      '${directory.path}/model.gguf',
    ).writeAsBytes([71, 71, 85, 70]);
    backend = StructuredRecordingBackend(StructuredFixtureBackend());
    port = DirectLlamaInferencePort(backend: backend);
    await port.loadModel(
      assets: ResolvedModelAssets(
        descriptor: StudioModelDescriptor(
          id: 'availability',
          name: 'Qwen XML fixture',
          description: 'Model-free tool admission',
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

  for (final choice in [ToolChoice.auto, ToolChoice.required]) {
    test(
      '$choice retains compatible tools and reports per-tool omissions',
      () async {
        backend.scriptedReplies.addAll([
          ['<tool_call>\n<function=available>\n</function>\n</tool_call>'],
          ['Complete.'],
        ]);
        final events = await port
            .streamTurn(
              StudioTurnRequest(
                history: [
                  StudioMessage(
                    id: 'user',
                    role: StudioRole.user,
                    text: 'Use an available tool.',
                    createdAt: DateTime.utc(2026),
                  ),
                ],
                settings: settings,
                extraTools: [bounded(), compatible()],
                includeBuiltInTools: false,
                toolChoice: choice,
              ),
            )
            .toList();
        final notice = events
            .whereType<StudioToolAvailabilityEvent>()
            .single
            .notices
            .single;
        expect(notice.toolName, 'bounded');
        expect(notice.isUnavailable, isTrue);
        expect(notice.reason, contains('Choose a compatible model'));
        expect(notice.reason, isNot(contains('Canonical JSON Schema')));
        expect(
          events.whereType<StudioTurnCompletedEvent>().single.result.text,
          'Complete.',
        );
        expect(invoked, 1);
        expect(backend.prompts, hasLength(2));
      },
    );
  }
  test(
    'named incompatible tool errors before any model or handler execution',
    () async {
      await expectLater(
        port
            .streamTurn(
              StudioTurnRequest(
                history: [
                  StudioMessage(
                    id: 'user',
                    role: StudioRole.user,
                    text: 'Use bounded.',
                    createdAt: DateTime.utc(2026),
                  ),
                ],
                settings: settings,
                extraTools: [bounded(), compatible()],
                includeBuiltInTools: false,
                requiredToolName: 'bounded',
              ),
            )
            .drain<void>(),
        throwsA(isA<LlamaUnsupportedException>()),
      );
      expect(invoked, 0);
      expect(backend.prompts, isEmpty);
    },
  );
  test('required with no compatible tool errors before generation', () async {
    await expectLater(
      port
          .streamTurn(
            StudioTurnRequest(
              history: [
                StudioMessage(
                  id: 'user',
                  role: StudioRole.user,
                  text: 'Use a tool.',
                  createdAt: DateTime.utc(2026),
                ),
              ],
              settings: settings,
              extraTools: [bounded()],
              includeBuiltInTools: false,
              toolChoice: ToolChoice.required,
            ),
          )
          .drain<void>(),
      throwsA(isA<LlamaUnsupportedException>()),
    );
    expect(invoked, 0);
    expect(backend.prompts, isEmpty);
  });
}
