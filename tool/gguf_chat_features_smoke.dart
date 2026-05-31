import 'dart:convert';
import 'dart:io';

import 'package:llamadart/llamadart.dart';

Future<void> main(List<String> args) async {
  final modelPath = args.isNotEmpty
      ? args[0]
      : Platform.environment['GGUF_MODEL'];
  if (modelPath == null || modelPath.trim().isEmpty) {
    stderr.writeln(
      'Usage: dart run tool/gguf_chat_features_smoke.dart '
      '<model.gguf> [auto|cpu|metal|vulkan|cuda|opencl|hip|blas]',
    );
    exitCode = 64;
    return;
  }

  final backend = args.length > 1 ? _parseBackend(args[1]) : GpuBackend.auto;
  final engine = LlamaEngine(LlamaBackend());
  try {
    engine.setLogLevel(LlamaLogLevel.warn);
    await engine.loadModel(
      modelPath,
      modelParams: ModelParams(
        contextSize: 2048,
        preferredBackend: backend,
        gpuLayers: backend == GpuBackend.cpu ? 0 : ModelParams.maxGpuLayers,
        numberOfThreads: 4,
        numberOfThreadsBatch: 4,
      ),
    );

    final template = await engine.chatTemplate(
      const [
        LlamaChatMessage.fromText(
          role: LlamaChatRole.user,
          text: 'Reply with one word.',
        ),
      ],
      addAssistant: true,
      enableThinking: false,
    );

    final noThinking = await _runScenario(
      engine: engine,
      messages: const [
        LlamaChatMessage.fromText(
          role: LlamaChatRole.system,
          text: 'Answer directly. Do not include reasoning tags.',
        ),
        LlamaChatMessage.fromText(
          role: LlamaChatRole.user,
          text: 'What is 2 + 2? Reply with only the number.',
        ),
      ],
      tools: const [],
      enableThinking: false,
      maxTokens: 64,
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

    _verifyNoThinking(noThinking);
    _verifyNoThinking(toolCall);
    _verifyToolCall(toolCall);

    final result = {
      'backendName': await engine.getBackendName(),
      'requestedBackend': backend.name,
      'format': template.format,
      'noThinking': noThinking.toJson(),
      'toolCall': toolCall.toJson(),
    };
    print('RESULT gguf_chat_features ${jsonEncode(result)}');
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
    finishReason = choice.finishReason ?? finishReason;
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

void _verifyNoThinking(_ScenarioResult result) {
  if (result.content.trim().isEmpty && result.toolCalls.isEmpty) {
    throw StateError('Scenario produced no content or tool calls.');
  }
  if (result.thinking.trim().isNotEmpty) {
    throw StateError('Thinking delta leaked while enableThinking=false.');
  }

  final leakedMarkers = const [
    '<think>',
    '</think>',
    '<|channel>thought',
    '<channel|>',
  ].where(result.content.contains).toList(growable: false);
  if (leakedMarkers.isNotEmpty) {
    throw StateError('Thinking markers leaked in content: $leakedMarkers');
  }
}

void _verifyToolCall(_ScenarioResult result) {
  if (result.finishReason != 'tool_calls') {
    throw StateError(
      'Tool scenario finished with ${result.finishReason}; '
      'content=${_tail(result.content)}',
    );
  }
  if (result.content.trim().isNotEmpty) {
    throw StateError('Tool scenario leaked content: ${_tail(result.content)}');
  }
  if (result.toolCalls.length != 1) {
    throw StateError('Expected 1 tool call, got ${result.toolCalls.length}.');
  }

  final function = result.toolCalls.first['function'];
  if (function is! Map || function['name'] != 'get_weather') {
    throw StateError(
      'Tool scenario did not call get_weather: ${result.toolCalls.first}',
    );
  }
  final arguments = function['arguments'];
  if (arguments is! String) {
    throw StateError('Tool call has no string arguments: $function');
  }
  final decoded = jsonDecode(arguments);
  if (decoded is! Map || decoded['location'] != 'Seoul') {
    throw StateError('Unexpected tool arguments: $arguments');
  }
}

GpuBackend _parseBackend(String value) {
  switch (value.trim().toLowerCase()) {
    case 'auto':
      return GpuBackend.auto;
    case 'cpu':
      return GpuBackend.cpu;
    case 'metal':
      return GpuBackend.metal;
    case 'vulkan':
    case 'vk':
      return GpuBackend.vulkan;
    case 'cuda':
      return GpuBackend.cuda;
    case 'opencl':
    case 'open-cl':
    case 'ocl':
      return GpuBackend.opencl;
    case 'hip':
      return GpuBackend.hip;
    case 'blas':
      return GpuBackend.blas;
    default:
      throw ArgumentError.value(
        value,
        'backend',
        'Expected auto, cpu, metal, vulkan, cuda, opencl, hip, or blas.',
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
