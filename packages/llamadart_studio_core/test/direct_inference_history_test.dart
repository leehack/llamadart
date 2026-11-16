import 'dart:convert';
import 'dart:io';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

import 'studio_test_fakes.dart';

void main() {
  for (final explicitResults in [false, true]) {
    test(
      'reopened tool history reaches the next prompt (explicit=$explicitResults)',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'studio_history_',
        );
        final model = await File(
          '${directory.path}/model.gguf',
        ).writeAsBytes([71, 71, 85, 70]);
        final backend = _HistoryBackend();
        final port = DirectLlamaInferencePort(backend: backend);
        addTearDown(() async {
          await port.dispose();
          await directory.delete(recursive: true);
        });
        const settings = StudioSettings(
          thinkingEnabled: false,
          toolsEnabled: false,
        );
        await port.loadModel(
          assets: ResolvedModelAssets(
            descriptor: StudioModelDescriptor(
              id: 'history',
              name: 'History',
              description: 'Model-free history probe',
              category: StudioModelCategory.chat,
              filename: 'model.gguf',
              sourceUri: model.path,
            ),
            primarySource: ModelSource.path(model.path),
          ),
          settings: settings,
          isWeb: false,
        );
        final kv = InMemoryKeyValueStore();
        final store = KeyValueConversationStore(kv);
        var conversation = StudioConversation.create(id: 'reopened')
            .appendToActiveBranch(
              StudioMessage(
                id: 'user',
                role: StudioRole.user,
                text: 'Inspect settings',
                createdAt: DateTime.utc(2026),
              ),
            )
            .appendToActiveBranch(
              StudioMessage(
                id: 'assistant',
                role: StudioRole.assistant,
                text: 'Settings inspected.',
                thinkingText: 'Inspect the configuration first.',
                createdAt: DateTime.utc(2026),
                toolCalls: const [
                  StudioToolInvocation(
                    id: 'lookup-1',
                    name: 'inspect',
                    argumentsJson:
                        '{"enabled":true,"count":3,"missing":null,"nested":{"items":[1,"two"]}}',
                    resultJson: '{"revision":42,"valid":true}',
                  ),
                  StudioToolInvocation(
                    id: 'lookup-2',
                    name: 'check',
                    argumentsJson: '{}',
                    resultJson: 'null',
                  ),
                  StudioToolInvocation(
                    id: 'interrupted',
                    name: 'incomplete',
                    argumentsJson: '{}',
                    isRunning: true,
                  ),
                ],
              ),
            );
        if (explicitResults) {
          for (final call in conversation.nodes.last.toolCalls.where(
            (c) => c.resultJson != null,
          )) {
            conversation = conversation.appendToActiveBranch(
              StudioMessage(
                id: 'result-${call.id}',
                role: StudioRole.tool,
                text: call.resultJson!,
                toolCalls: [call],
                createdAt: DateTime.utc(2026),
              ),
            );
          }
        }
        await store.save(conversation);
        final reopened = (await KeyValueConversationStore(kv).loadAll()).single;
        await port
            .streamTurn(
              StudioTurnRequest(
                history: [
                  ...reopened.activeBranch,
                  StudioMessage(
                    id: 'followup',
                    role: StudioRole.user,
                    text: 'What was the revision?',
                    createdAt: DateTime.utc(2026),
                  ),
                ],
                settings: settings,
              ),
            )
            .drain<void>();
        final messages = (jsonDecode(backend.prompts.single) as List)
            .cast<Map<String, dynamic>>();
        final calls = [for (final m in messages) ...?m['tool_calls'] as List?];
        final results = messages.where((m) => m['role'] == 'tool').toList();
        expect(calls.map((c) => c['id']), ['lookup-1', 'lookup-2']);
        expect(results.map((r) => r['tool_call_id']), ['lookup-1', 'lookup-2']);
        expect(calls.first['function']['arguments'], {
          'enabled': true,
          'count': 3,
          'missing': null,
          'nested': {
            'items': [1, 'two'],
          },
        });
        expect(results.first['name'], 'inspect');
        expect(jsonDecode(results.first['content'] as String), {
          'revision': 42,
          'valid': true,
        });
        expect(results.last['content'], 'null');
        expect(
          messages.where((m) => m['content'] == 'Settings inspected.'),
          hasLength(1),
        );
        expect(
          messages.any(
            (m) => m['reasoning_content'] == 'Inspect the configuration first.',
          ),
          isTrue,
        );
      },
    );
  }
}

class _HistoryBackend extends FakeSpeculativeFallbackBackend {
  final prompts = <String>[];

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
    prompts.add(prompt);
    yield utf8.encode('Revision 42.');
  }
}
