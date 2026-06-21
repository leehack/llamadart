import 'dart:convert';

import 'package:llamadart/src/backends/backend.dart';
import 'package:llamadart/src/core/engine/chat_completion_request_planner.dart';
import 'package:llamadart/src/core/exceptions.dart';
import 'package:llamadart/src/core/models/chat/chat_message.dart';
import 'package:llamadart/src/core/models/chat/chat_role.dart';
import 'package:llamadart/src/core/models/chat/chat_template_result.dart';
import 'package:llamadart/src/core/models/chat/content_part.dart';
import 'package:llamadart/src/core/models/config/log_level.dart';
import 'package:llamadart/src/core/models/inference/generation_params.dart';
import 'package:llamadart/src/core/models/inference/model_params.dart';
import 'package:llamadart/src/core/models/inference/tool_choice.dart';
import 'package:llamadart/src/core/models/tools/tool_definition.dart';
import 'package:llamadart/src/core/models/tools/tool_param.dart';
import 'package:test/test.dart';

void main() {
  group('ChatCompletionRequestPlanner', () {
    test('merges template grammar, stop sequences, and preserved tokens', () {
      final backend = _NativeChatBackend();
      final plan = ChatCompletionRequestPlanner.build(
        backend: backend,
        templateResult: const LlamaChatTemplateResult(
          prompt: 'prompt',
          grammar: 'template ::= "ok"',
          grammarLazy: true,
          additionalStops: ['</s>'],
          preservedTokens: ['<tool>'],
          grammarTriggers: [GrammarTrigger(type: 0, value: '<tool>')],
        ),
        messages: const [
          LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hello'),
        ],
        params: const GenerationParams(
          stopSequences: ['STOP'],
          grammar: 'caller ::= "ignored"',
          preservedTokens: ['<caller>'],
        ),
        tools: [_weatherTool],
        toolChoice: ToolChoice.auto,
        parallelToolCalls: false,
      );

      expect(plan.generationParams.stopSequences, ['</s>', 'STOP']);
      expect(plan.generationParams.grammar, 'template ::= "ok"');
      expect(plan.generationParams.grammarLazy, isTrue);
      expect(plan.generationParams.grammarTriggers.single.value, '<tool>');
      expect(plan.generationParams.preservedTokens, ['<tool>', '<caller>']);
      expect(plan.nativeChatBackend, same(backend));
      expect(plan.parseToolCallsEnabled, isTrue);
    });

    test('rejects strict response format when backend cannot use grammar', () {
      expect(
        () => ChatCompletionRequestPlanner.build(
          backend: _NoGrammarBackend(),
          templateResult: const LlamaChatTemplateResult(
            prompt: 'prompt',
            grammar: 'root ::= "ok"',
          ),
          messages: const [
            LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hello'),
          ],
          toolChoice: ToolChoice.auto,
          parallelToolCalls: false,
          responseFormat: const {'type': 'json_object'},
        ),
        throwsA(isA<LlamaUnsupportedException>()),
      );
    });

    test(
      'falls back to rendered prompt when native chat cannot satisfy policy',
      () {
        final plan = ChatCompletionRequestPlanner.build(
          backend: _NativeChatBackend(),
          templateResult: const LlamaChatTemplateResult(prompt: 'prompt'),
          messages: const [
            LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hello'),
          ],
          tools: [_weatherTool],
          toolChoice: ToolChoice.required,
          parallelToolCalls: false,
        );

        expect(plan.usesNativeChatGeneration, isFalse);
        expect(plan.parseToolCallsEnabled, isTrue);
      },
    );
  });
}

final ToolDefinition _weatherTool = ToolDefinition(
  name: 'get_weather',
  description: 'Returns current weather for a city.',
  parameters: [ToolParam.string('location', description: 'City name')],
  handler: (_) async => 'Sunny',
);

class _NoGrammarBackend extends _BaseBackend
    implements BackendGrammarConstraintsSupport {
  @override
  bool get supportsGrammarConstraints => false;
}

class _NativeChatBackend extends _BaseBackend
    implements BackendGrammarConstraintsSupport, BackendNativeChatGeneration {
  @override
  bool get supportsGrammarConstraints => true;

  @override
  bool get supportsNativeChatGeneration => true;

  @override
  Stream<List<int>> generateChat(
    int contextHandle,
    List<LlamaChatMessage> messages,
    GenerationParams params, {
    List<ToolDefinition>? tools,
    ToolChoice toolChoice = ToolChoice.auto,
    bool parallelToolCalls = false,
    bool enableThinking = true,
    Map<String, dynamic>? chatTemplateKwargs,
    String? sourceLangCode,
    String? targetLangCode,
    DateTime? templateNow,
  }) async* {
    yield utf8.encode('ok');
  }
}

class _BaseBackend implements LlamaBackend {
  @override
  bool get isReady => true;

  @override
  bool get supportsUrlLoading => false;

  @override
  Future<void> clearLoraAdapters(int contextHandle) async {}

  @override
  void cancelGeneration() {}

  @override
  Future<int> contextCreate(int modelHandle, ModelParams params) async => 1;

  @override
  Future<void> contextFree(int contextHandle) async {}

  @override
  Future<String> detokenize(
    int modelHandle,
    List<int> tokens, {
    bool special = false,
  }) async => '';

  @override
  Future<void> dispose() async {}

  @override
  Stream<List<int>> generate(
    int contextHandle,
    String prompt,
    GenerationParams params, {
    List<LlamaContentPart>? parts,
  }) async* {}

  @override
  Future<String> getBackendName() async => 'test';

  @override
  Future<int> getContextSize(int contextHandle) async => 2048;

  @override
  Future<({int free, int total})> getVramInfo() async => (free: 0, total: 0);

  @override
  Future<bool> isGpuSupported() async => false;

  @override
  Future<int?> multimodalContextCreate(
    int modelHandle,
    String mmProjPath,
  ) async => null;

  @override
  Future<void> multimodalContextFree(int mmContextHandle) async {}

  @override
  Future<void> modelFree(int modelHandle) async {}

  @override
  Future<int> modelLoad(String path, ModelParams params) async => 1;

  @override
  Future<int> modelLoadFromUrl(
    String url,
    ModelParams params, {
    Function(double progress)? onProgress,
  }) async => 1;

  @override
  Future<Map<String, String>> modelMetadata(int modelHandle) async => const {};

  @override
  Future<void> removeLoraAdapter(int contextHandle, String path) async {}

  @override
  Future<void> setLogLevel(LlamaLogLevel level) async {}

  @override
  Future<void> setLoraAdapter(
    int contextHandle,
    String path,
    double scale,
  ) async {}

  @override
  Future<bool> supportsAudio(int mmContextHandle) async => false;

  @override
  Future<bool> supportsVision(int mmContextHandle) async => false;

  @override
  Future<List<int>> tokenize(
    int modelHandle,
    String text, {
    bool addSpecial = true,
  }) async => const [];

  @override
  Future<String> applyChatTemplate(
    int modelHandle,
    List<Map<String, dynamic>> messages, {
    String? customTemplate,
    bool addAssistant = true,
  }) async => '';
}
