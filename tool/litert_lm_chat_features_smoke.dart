import 'dart:convert';
import 'dart:io';

import 'package:llamadart/llamadart.dart';

Future<void> main(List<String> args) async {
  final modelPath = args.isNotEmpty
      ? args[0]
      : Platform.environment['LITERT_LM_MODEL'];
  if (modelPath == null || modelPath.trim().isEmpty) {
    stderr.writeln(
      'Usage: dart run tool/litert_lm_chat_features_smoke.dart '
      '<model.litertlm> [cpu|gpu|npu|auto]',
    );
    exitCode = 64;
    return;
  }

  final backend = args.length > 1 ? _parseBackend(args[1]) : _defaultBackend();
  final engine = LlamaEngine(LlamaBackend());
  try {
    await engine.loadModel(
      modelPath,
      modelParams: ModelParams(contextSize: 2048, liteRtLmBackend: backend),
    );

    final thinking = await _runScenario(
      engine: engine,
      messages: const [
        LlamaChatMessage.fromText(
          role: LlamaChatRole.user,
          text: 'Think briefly, then answer with only the number: 2 + 2.',
        ),
      ],
      tools: const [],
      enableThinking: true,
      maxTokens: 96,
    );

    final toolCall = await _runScenario(
      engine: engine,
      messages: const [
        LlamaChatMessage.fromText(
          role: LlamaChatRole.system,
          text: 'You must call get_weather. Return only a tool call.',
        ),
        LlamaChatMessage.fromText(
          role: LlamaChatRole.user,
          text: 'Call get_weather with location Seoul.',
        ),
      ],
      tools: [
        ToolDefinition(
          name: 'get_weather',
          description: 'Returns current weather for a city.',
          parameters: [ToolParam.string('location', description: 'City name')],
          handler: (_) async => 'Sunny',
        ),
      ],
      enableThinking: false,
      maxTokens: 160,
      toolChoice: ToolChoice.required,
    );

    final result = {
      'backendName': await engine.getBackendName(),
      'requestedLiteRtLmBackend': backend.name,
      'thinking': thinking.toJson(),
      'toolCall': toolCall.toJson(),
    };
    print('RESULT litert_lm_chat_features ${jsonEncode(result)}');
  } finally {
    await engine.dispose();
  }
}

Future<_ScenarioResult> _runScenario({
  required LlamaEngine engine,
  required List<LlamaChatMessage> messages,
  required List<ToolDefinition> tools,
  required bool enableThinking,
  required int maxTokens,
  ToolChoice toolChoice = ToolChoice.auto,
}) async {
  final content = StringBuffer();
  final thinking = StringBuffer();
  final toolCalls = <Map<String, Object?>>[];
  var chunks = 0;
  var finishReason = '';

  await for (final chunk in engine.create(
    messages,
    tools: tools.isEmpty ? null : tools,
    toolChoice: toolChoice,
    enableThinking: enableThinking,
    params: GenerationParams(maxTokens: maxTokens, temp: 0.0, seed: 1),
  )) {
    chunks++;
    final choice = chunk.choices.first;
    finishReason = choice.finishReason ?? '';
    final delta = choice.delta;
    if (delta.content != null) {
      content.write(delta.content);
    }
    if (delta.thinking != null) {
      thinking.write(delta.thinking);
    }
    for (final call
        in delta.toolCalls ?? const <LlamaCompletionChunkToolCall>[]) {
      toolCalls.add(call.toJson());
    }
  }

  return _ScenarioResult(
    chunks: chunks,
    finishReason: finishReason,
    content: content.toString(),
    thinking: thinking.toString(),
    toolCalls: toolCalls,
  );
}

LiteRtLmBackendPreference _defaultBackend() {
  if (Platform.isAndroid || Platform.isMacOS) {
    return LiteRtLmBackendPreference.gpu;
  }
  return LiteRtLmBackendPreference.cpu;
}

LiteRtLmBackendPreference _parseBackend(String value) {
  switch (value.trim().toLowerCase()) {
    case 'auto':
      return LiteRtLmBackendPreference.auto;
    case 'cpu':
      return LiteRtLmBackendPreference.cpu;
    case 'gpu':
      return LiteRtLmBackendPreference.gpu;
    case 'npu':
      return LiteRtLmBackendPreference.npu;
    default:
      throw ArgumentError.value(
        value,
        'backend',
        'Expected auto, cpu, gpu, or npu.',
      );
  }
}

class _ScenarioResult {
  const _ScenarioResult({
    required this.chunks,
    required this.finishReason,
    required this.content,
    required this.thinking,
    required this.toolCalls,
  });

  final int chunks;
  final String finishReason;
  final String content;
  final String thinking;
  final List<Map<String, Object?>> toolCalls;

  Map<String, Object?> toJson() => {
    'chunks': chunks,
    'finishReason': finishReason,
    'contentLength': content.length,
    'contentTail': _tail(content),
    'thinkingLength': thinking.length,
    'thinkingTail': _tail(thinking),
    'toolCallCount': toolCalls.length,
    'toolCalls': toolCalls,
  };
}

String _tail(String value) {
  if (value.length <= 240) {
    return value;
  }
  return value.substring(value.length - 240);
}
