import 'dart:convert';
import 'dart:io';

import 'package:llamadart/llamadart.dart';

import 'audio_chat_smoke_support.dart';

Future<void> main(List<String> args) async {
  final modelPath = args.isNotEmpty
      ? args[0]
      : Platform.environment['LITERT_LM_MODEL'];
  if (modelPath == null || modelPath.trim().isEmpty) {
    stderr.writeln(
      'Usage: dart run tool/litert_lm_chat_features_smoke.dart '
      '<model.litertlm> [cpu|gpu|npu|auto] [image-path]\n'
      'Optional env:\n'
      '  LITERT_LM_IMAGE_PATH=<local image file>\n'
      '  LITERT_LM_AUDIO_PATH=<local encoded audio file>\n'
      '  LITERT_LM_AUDIO_EXPECTED_TEXT=<expected answer; required with audio>',
    );
    exitCode = 64;
    return;
  }

  final backend = args.length > 1 ? _parseBackend(args[1]) : _defaultBackend();
  final imagePath = _optionalImagePath(args.length > 2 ? args[2] : null);
  final audioPath = optionalAudioChatSmokePath(
    environmentName: 'LITERT_LM_AUDIO_PATH',
    smokeName: 'LiteRT-LM smoke',
  );
  final audioExpectedText = optionalAudioChatExpectedText(
    audioPath: audioPath,
    environmentName: 'LITERT_LM_AUDIO_EXPECTED_TEXT',
    audioEnvironmentName: 'LITERT_LM_AUDIO_PATH',
  );
  final audioFixture = audioPath == null
      ? null
      : await readAudioChatSmokeFixture(audioPath);
  final engine = LlamaEngine(LlamaBackend());
  try {
    await engine.loadModel(
      modelPath,
      modelParams: ModelParams(contextSize: 2048, liteRtLmBackend: backend),
    );

    final plain = await _runScenario(
      engine: engine,
      messages: const [
        LlamaChatMessage.fromText(
          role: LlamaChatRole.user,
          text: 'Reply with one short sentence saying hello.',
        ),
      ],
      tools: const [],
      enableThinking: false,
      maxTokens: 64,
    );

    final thinking = await _runScenario(
      engine: engine,
      messages: const [
        LlamaChatMessage.fromText(
          role: LlamaChatRole.user,
          text:
              'A farmer has 17 sheep. All but 9 run away. Think step by step, '
              'then state how many sheep remain.',
        ),
      ],
      tools: const [],
      enableThinking: true,
      maxTokens: 256,
    );

    final requiredTemplate = await engine.chatTemplate(
      _requiredToolMessages,
      tools: [_weatherTool],
      toolChoice: ToolChoice.required,
      enableThinking: false,
      includeTokenCount: false,
    );
    final requiredUnsupportedExpected =
        requiredTemplate.format == ChatFormat.hermes.index;
    final toolCall = await _runRequiredToolScenario(
      engine: engine,
      expectUnsupported: requiredUnsupportedExpected,
    );

    final nativeToolHistory = requiredUnsupportedExpected
        ? null
        : await _runScenario(
            engine: engine,
            messages: const [
              LlamaChatMessage.fromText(
                role: LlamaChatRole.system,
                text:
                    'For weather questions, call get_weather with the '
                    'requested city. Do not answer weather questions in text.',
              ),
              LlamaChatMessage.fromText(
                role: LlamaChatRole.user,
                text: 'Remember this city: Seoul.',
              ),
              LlamaChatMessage.fromText(
                role: LlamaChatRole.assistant,
                text: 'I will remember Seoul.',
              ),
              LlamaChatMessage.fromText(
                role: LlamaChatRole.user,
                text:
                    'What is the weather in the remembered city? Use the tool.',
              ),
            ],
            tools: [_weatherTool],
            enableThinking: false,
            maxTokens: 160,
            toolChoice: ToolChoice.auto,
          );

    final nativeMediaRender = imagePath == null
        ? null
        : await _renderNativeMediaPrompt(
            modelPath: modelPath,
            backend: backend,
            imagePath: imagePath,
          );
    final multimodal = imagePath == null
        ? null
        : await _runScenario(
            engine: engine,
            messages: [
              LlamaChatMessage.withContent(
                role: LlamaChatRole.user,
                content: [
                  const LlamaTextContent(
                    'Describe the image in one short sentence.',
                  ),
                  LlamaImageContent(path: imagePath),
                ],
              ),
            ],
            tools: const [],
            enableThinking: false,
            maxTokens: 96,
          );
    final audioChat = audioFixture == null
        ? null
        : await _runScenario(
            engine: engine,
            messages: [
              LlamaChatMessage.withContent(
                role: LlamaChatRole.user,
                content: [
                  LlamaAudioContent(bytes: audioFixture.bytes),
                  const LlamaTextContent(audioChatQuestionPrompt),
                ],
              ),
            ],
            tools: const [],
            enableThinking: false,
            maxTokens: 64,
          );

    final result = {
      'backendName': await engine.getBackendName(),
      'requestedLiteRtLmBackend': backend.name,
      'format': requiredTemplate.format,
      'plain': plain.toJson(),
      'thinking': thinking.toJson(),
      'toolCall': toolCall.toJson(),
      'nativeToolHistory':
          nativeToolHistory?.toJson() ??
          const {
            'status': 'not_applicable',
            'reason':
                'Hermes/Qwen auto tool calls are best-effort and are not '
                'asserted by this smoke',
          },
      if (nativeMediaRender != null)
        'nativeMediaRender': nativeMediaRender.toJson(),
      if (multimodal != null) 'multimodal': multimodal.toJson(),
      if (audioChat != null) ...{
        'audioInput': audioFixture!.toJson(),
        'audioChat': audioChat.toJson(),
      },
    };
    _verifyResult(
      plain: plain,
      thinking: thinking,
      toolCall: toolCall,
      requiredUnsupportedExpected: requiredUnsupportedExpected,
      nativeToolHistory: nativeToolHistory,
      multimodal: multimodal,
      audioChat: audioChat,
      audioExpectedText: audioExpectedText,
    );
    print('RESULT litert_lm_chat_features ${jsonEncode(result)}');
  } finally {
    await engine.dispose();
  }
}

void _verifyResult({
  required _ScenarioResult plain,
  required _ScenarioResult thinking,
  required _RequiredToolScenarioResult toolCall,
  required bool requiredUnsupportedExpected,
  required _ScenarioResult? nativeToolHistory,
  _ScenarioResult? multimodal,
  _ScenarioResult? audioChat,
  String? audioExpectedText,
}) {
  if (plain.content.trim().isEmpty) {
    throw StateError('LiteRT-LM plain chat produced no visible content.');
  }
  if (plain.thinking.trim().isNotEmpty) {
    throw StateError(
      'LiteRT-LM plain chat produced an unexpected thinking delta.',
    );
  }
  if (plain.toolCalls.isNotEmpty) {
    throw StateError('LiteRT-LM plain chat produced an unexpected tool call.');
  }
  if (thinking.thinking.trim().isEmpty) {
    throw StateError('LiteRT-LM thinking scenario produced no thinking delta.');
  }
  if (thinking.content.trim().isEmpty) {
    throw StateError('LiteRT-LM thinking scenario produced no visible answer.');
  }
  if (requiredUnsupportedExpected) {
    if (!toolCall.isUnsupported) {
      throw StateError(
        'Hermes/Qwen required tool choice did not fail explicitly unsupported.',
      );
    }
  } else {
    _verifyWeatherToolCall(
      toolCall.scenario!,
      scenarioName: 'LiteRT-LM required tool scenario',
    );
  }
  if (nativeToolHistory != null) {
    if (nativeToolHistory.content.trim().isNotEmpty) {
      throw StateError(
        'LiteRT-LM native tool/history scenario streamed content: '
        '${nativeToolHistory.content}',
      );
    }
    _verifyWeatherToolCall(
      nativeToolHistory,
      scenarioName: 'LiteRT-LM native tool/history scenario',
    );
  }
  if (multimodal != null && multimodal.content.trim().isEmpty) {
    throw StateError('LiteRT-LM multimodal scenario produced no content.');
  }
  if (audioChat != null) {
    verifyExactAudioChatAnswer(
      scenarioName: 'Gemma 4 audio chat',
      actualText: audioChat.content,
      expectedText: audioExpectedText!,
    );
  }
}

void _verifyWeatherToolCall(
  _ScenarioResult scenario, {
  required String scenarioName,
}) {
  if (scenario.finishReason != 'tool_calls') {
    throw StateError('$scenarioName finished with ${scenario.finishReason}.');
  }
  if (scenario.toolCalls.length != 1) {
    throw StateError(
      '$scenarioName produced ${scenario.toolCalls.length} calls.',
    );
  }
  final function = scenario.toolCalls.first['function'];
  if (function is! Map || function['name'] != 'get_weather') {
    throw StateError('$scenarioName did not call get_weather.');
  }
  final arguments = function['arguments'];
  if (arguments is! String) {
    throw StateError('$scenarioName did not provide JSON string arguments.');
  }
  Object? decoded;
  try {
    decoded = jsonDecode(arguments);
  } catch (_) {
    throw StateError('$scenarioName produced invalid JSON arguments.');
  }
  if (decoded is! Map ||
      decoded.length != 1 ||
      decoded['location'] != 'Seoul') {
    throw StateError('$scenarioName did not pass the expected location.');
  }
}

Future<_RequiredToolScenarioResult> _runRequiredToolScenario({
  required LlamaEngine engine,
  required bool expectUnsupported,
}) async {
  try {
    final scenario = await _runScenario(
      engine: engine,
      messages: _requiredToolMessages,
      tools: [_weatherTool],
      enableThinking: false,
      maxTokens: 160,
      toolChoice: ToolChoice.required,
    );
    if (expectUnsupported) {
      throw StateError(
        'Hermes/Qwen required tool choice reached generation instead of '
        'failing explicitly unsupported.',
      );
    }
    return _RequiredToolScenarioResult.success(scenario);
  } on LlamaUnsupportedException catch (error) {
    if (!expectUnsupported) {
      rethrow;
    }
    if (!error.message.contains('ToolChoice.required') ||
        !error.message.contains('Hermes/Qwen') ||
        !error.message.contains('grammar-constrained decoding')) {
      throw StateError(
        'Hermes/Qwen required tool choice produced a non-actionable '
        'unsupported error.',
      );
    }
    return _RequiredToolScenarioResult.unsupported(error.message);
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

Future<_NativeMediaRenderResult> _renderNativeMediaPrompt({
  required String modelPath,
  required LiteRtLmBackendPreference backend,
  required String imagePath,
}) async {
  final client = LiteRtLmRuntimeClient();
  try {
    await client.initialize(
      modelPath: modelPath,
      backend: _runtimeBackendName(backend),
      maxTokens: 2048,
      outputTokens: 32,
      maxNumImages: 1,
      speculativeDecoding: false,
    );
    client.createConversation(temperature: 0, topK: 1, topP: 1, seed: 1);
    final rendered = client.renderMessageToString({
      'role': 'user',
      'content': [
        {'type': 'text', 'text': 'Describe the image in one short sentence.'},
        {'type': 'image', 'path': imagePath},
      ],
    });
    final marker = _firstMediaMarker(rendered);
    if (marker == null) {
      throw StateError(
        'Native Gemma 4 render did not include an image marker. Rendered tail: '
        '${_tail(rendered)}',
      );
    }
    return _NativeMediaRenderResult(
      marker: marker,
      renderedLength: rendered.length,
      renderedTail: _tail(rendered),
    );
  } finally {
    client.dispose();
  }
}

String _runtimeBackendName(LiteRtLmBackendPreference backend) {
  final nativeName = backend.nativeName;
  if (nativeName != null) {
    return nativeName;
  }
  return Platform.isAndroid || Platform.isMacOS ? 'gpu' : 'cpu';
}

String? _firstMediaMarker(String rendered) {
  for (final marker in const [
    '<|image|>',
    '<start_of_image>',
    '<image_soft_token>',
  ]) {
    if (rendered.contains(marker)) {
      return marker;
    }
  }
  return null;
}

LiteRtLmBackendPreference _defaultBackend() {
  if (Platform.isAndroid || Platform.isMacOS) {
    return LiteRtLmBackendPreference.gpu;
  }
  return LiteRtLmBackendPreference.cpu;
}

String? _optionalImagePath(String? argValue) {
  final value = argValue ?? Platform.environment['LITERT_LM_IMAGE_PATH'];
  if (value == null || value.trim().isEmpty) {
    return null;
  }
  final image = File(value);
  if (!image.existsSync()) {
    throw ArgumentError('LiteRT-LM smoke image does not exist: $value');
  }
  return image.path;
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

class _RequiredToolScenarioResult {
  const _RequiredToolScenarioResult.success(this.scenario)
    : unsupportedMessage = null;

  const _RequiredToolScenarioResult.unsupported(this.unsupportedMessage)
    : scenario = null;

  final _ScenarioResult? scenario;
  final String? unsupportedMessage;

  bool get isUnsupported => unsupportedMessage != null;

  Map<String, Object?> toJson() =>
      scenario?.toJson() ??
      {'status': 'unsupported', 'message': unsupportedMessage};
}

class _NativeMediaRenderResult {
  const _NativeMediaRenderResult({
    required this.marker,
    required this.renderedLength,
    required this.renderedTail,
  });

  final String marker;
  final int renderedLength;
  final String renderedTail;

  Map<String, Object?> toJson() => {
    'marker': marker,
    'renderedLength': renderedLength,
    'renderedTail': renderedTail,
  };
}

String _tail(String value) {
  if (value.length <= 240) {
    return value;
  }
  return value.substring(value.length - 240);
}

const List<LlamaChatMessage> _requiredToolMessages = [
  LlamaChatMessage.fromText(
    role: LlamaChatRole.system,
    text: 'You must call get_weather. Return only a tool call.',
  ),
  LlamaChatMessage.fromText(
    role: LlamaChatRole.user,
    text: 'Call get_weather with location Seoul.',
  ),
];

final ToolDefinition _weatherTool = ToolDefinition(
  name: 'get_weather',
  description: 'Returns current weather for a city.',
  parameters: [ToolParam.string('location', description: 'City name')],
  handler: (_) async => 'Sunny',
);
