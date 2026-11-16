import 'dart:convert';
import 'dart:io';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

import 'studio_test_fakes.dart';

void main() {
  test(
    'new multi-round Chat turns reopen with their exact protocol order',
    () async {
      final directory = await Directory.systemTemp.createTemp('studio_rounds_');
      final file = await File(
        '${directory.path}/model.gguf',
      ).writeAsBytes([71, 71, 85, 70]);
      final backend = _RoundBackend()
        ..outputs.addAll([
          'First inspection <|tool_call>call:inspect{"step":1}<tool_call|>',
          'Second inspection <|tool_call>call:inspect{"step":2}<tool_call|>',
          'Final answer.',
          'Followup answer.',
        ]);
      final port = DirectLlamaInferencePort(backend: backend);
      final kv = InMemoryKeyValueStore();
      final shell = StudioShellController(keyValueStore: kv);
      await shell.initialize();
      const settings = StudioSettings(
        thinkingEnabled: false,
        toolsEnabled: true,
        enableMcpInChat: true,
        enabledBuiltInTools: [],
      );
      await shell.updateSettings((_) => settings);
      final store = KeyValueConversationStore(kv);
      final tools = _RoundTools();
      addTearDown(tools.dispose);
      final chat = ChatWorkspaceController(
        conversationStore: store,
        inferencePort: port,
        shellController: shell,
        mcpManager: tools,
      );
      addTearDown(() async {
        await chat.dispose();
        await shell.dispose();
        await port.dispose();
        await directory.delete(recursive: true);
      });
      await port.loadModel(
        assets: ResolvedModelAssets(
          descriptor: StudioModelDescriptor(
            id: 'rounds',
            name: 'Rounds',
            description: 'Scripted ordered turns',
            category: StudioModelCategory.chat,
            filename: 'model.gguf',
            sourceUri: file.path,
          ),
          primarySource: ModelSource.path(file.path),
        ),
        settings: settings,
        isWeb: false,
      );
      await chat.initialize();
      await chat.sendMessage('Inspect both steps.');
      expect(chat.state.lastTurnError, isNull);
      final saved = (await KeyValueConversationStore(kv).loadAll()).single;
      final recorded = saved.activeBranch.last;
      expect(recorded.transcript.map((m) => m.role), [
        StudioRole.assistant,
        StudioRole.tool,
        StudioRole.assistant,
        StudioRole.tool,
        StudioRole.assistant,
      ]);
      expect(recorded.toolCalls, hasLength(2));
      await chat.dispose();
      final reopened = ChatWorkspaceController(
        conversationStore: KeyValueConversationStore(kv),
        inferencePort: port,
        shellController: shell,
        mcpManager: tools,
      );
      addTearDown(reopened.dispose);
      await reopened.initialize();
      await reopened.sendMessage('Followup');
      expect(reopened.state.lastTurnError, isNull);
      final messages = (jsonDecode(backend.prompts.last) as List)
          .cast<Map<String, dynamic>>()
          .where((m) => m['role'] != 'system')
          .toList();
      expect(messages.map((m) => m['role']), [
        'user',
        'assistant',
        'tool',
        'assistant',
        'tool',
        'assistant',
        'user',
      ]);
      expect(messages[1]['content'], contains('First inspection'));
      expect(messages[3]['content'], contains('Second inspection'));
      expect(messages[5]['content'], 'Final answer.');
      expect(messages[1]['tool_calls'], hasLength(1));
      expect(messages[3]['tool_calls'], hasLength(1));
      expect(
        (messages[1]['tool_calls'] as List).single['id'],
        messages[2]['tool_call_id'],
      );
      expect(
        (messages[3]['tool_calls'] as List).single['id'],
        messages[4]['tool_call_id'],
      );
      expect(jsonDecode(messages[2]['content'] as String), {'step': 1});
      expect(jsonDecode(messages[4]['content'] as String), {'step': 2});
    },
  );
}

class _RoundTools extends McpManager {
  _RoundTools() : super(keyValueStore: InMemoryKeyValueStore());
  @override
  List<ToolDefinition> buildActiveToolDefinitions() => [
    ToolDefinition(
      name: 'inspect',
      description: 'Inspect one step',
      parameters: [ToolParam.integer('step', required: true)],
      handler: (params) async => params.raw,
    ),
  ];
}

class _RoundBackend extends FakeSpeculativeFallbackBackend {
  final outputs = <String>[];
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
    yield utf8.encode(outputs.removeAt(0));
  }
}
