@Tags(['local-only', 'e2e'])
@Timeout(Duration(minutes: 20))
/// Local-only chat app E2E for the LiteRT-LM ChatService path.
///
/// This requires a local `.litertlm` file. Run it manually with:
///
/// ```bash
/// cd example/chat_app
/// flutter test --run-skipped -t local-only \
///   integration_test/litert_lm_chat_service_e2e_test.dart -d macos \
///   --dart-define=LITERT_LM_MODEL_URL=http://127.0.0.1:8765/model.litertlm
/// ```
library;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:path/path.dart' as p;

import 'package:llamadart_chat_example/models/chat_settings.dart';
import 'package:llamadart_chat_example/models/downloadable_model.dart';
import 'package:llamadart_chat_example/services/chat_service.dart';
import 'package:llamadart_chat_example/services/model_service_base.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('loads LiteRT-LM model through ChatService and chats', (
    tester,
  ) async {
    const modelPath = String.fromEnvironment('LITERT_LM_MODEL');
    const modelUrl = String.fromEnvironment('LITERT_LM_MODEL_URL');
    if (modelPath.isEmpty && modelUrl.isEmpty) {
      markTestSkipped(
        'Set --dart-define=LITERT_LM_MODEL_URL=http://.../model.litertlm '
        'or --dart-define=LITERT_LM_MODEL=/path/model.litertlm',
      );
      return;
    }

    final resolvedModelPath = modelUrl.isNotEmpty
        ? await _downloadModelFromUrl(modelUrl)
        : modelPath;
    final chatService = ChatService();
    try {
      await chatService.init(
        ChatSettings(
          modelPath: resolvedModelPath,
          preferredBackend: _preferredBackendFromEnvironment(),
          gpuLayers: ModelParams.maxGpuLayers,
          contextSize: 2048,
          maxTokens: 16,
          nativeLogLevel: LlamaLogLevel.warn,
        ),
      );

      expect(chatService.engine.isReady, isTrue);
      expect(await chatService.engine.getBackendName(), contains('LiteRT-LM'));

      final thinkingSession = ChatSession(
        chatService.engine,
        maxContextTokens: 2048,
      );
      final thinkingChunks = await thinkingSession
          .create(
            [
              LlamaTextContent(
                'A farmer has 17 sheep. All but 9 run away. Think step by '
                'step, then state how many sheep remain.',
              ),
            ],
            params: const GenerationParams(maxTokens: 256, temp: 0, seed: 1),
            enableThinking: true,
          )
          .toList();
      final thinkingText = thinkingChunks.map((chunk) {
        return chunk.choices.first.delta.thinking ?? '';
      }).join();

      expect(thinkingText.trim(), isNotEmpty);

      final toolSession = ChatSession(
        chatService.engine,
        maxContextTokens: 2048,
        systemPrompt: 'You must call get_weather. Return only a tool call.',
      );
      final toolChunks = await toolSession
          .create(
            [LlamaTextContent('Call get_weather with location Seoul.')],
            tools: [
              ToolDefinition(
                name: 'get_weather',
                description: 'Returns current weather for a city.',
                parameters: [
                  ToolParam.string('location', description: 'City name'),
                ],
                handler: (_) async => 'Sunny',
              ),
            ],
            toolChoice: ToolChoice.required,
            params: const GenerationParams(maxTokens: 160, temp: 0, seed: 1),
            enableThinking: false,
          )
          .toList();

      final toolCalls = [
        for (final chunk in toolChunks) ...?chunk.choices.first.delta.toolCalls,
      ];
      expect(toolChunks.last.choices.first.finishReason, equals('tool_calls'));
      expect(toolCalls, hasLength(1));
      expect(toolCalls.first.function?.name, equals('get_weather'));
      expect(
        toolCalls.first.function?.arguments,
        contains('"location":"Seoul"'),
      );
    } finally {
      await chatService.dispose();
    }
  });
}

GpuBackend _preferredBackendFromEnvironment() {
  const backend = String.fromEnvironment(
    'LITERT_LM_E2E_BACKEND',
    defaultValue: 'auto',
  );
  switch (backend.trim().toLowerCase()) {
    case 'auto':
      return GpuBackend.auto;
    case 'cpu':
      return GpuBackend.cpu;
    case 'gpu':
      return GpuBackend.vulkan;
    default:
      throw ArgumentError.value(
        backend,
        'LITERT_LM_E2E_BACKEND',
        'Expected auto, cpu, or gpu.',
      );
  }
}

Future<String> _downloadModelFromUrl(String url) async {
  final service = ModelService();
  final modelsDir = await service.getModelsDirectory();
  final filename = _filenameFromUrl(url);
  final model = DownloadableModel(
    name: 'LiteRT-LM E2E',
    description: 'LiteRT-LM E2E test model',
    url: url,
    filename: filename,
    sizeBytes: 0,
  );
  final downloaded = await service.getDownloadedModels([model]);
  if (downloaded.contains(model.filename)) {
    return p.join(modelsDir, filename);
  }

  Object? downloadError;
  var completed = false;
  await service.downloadModel(
    model: model,
    modelsDir: modelsDir,
    cancelToken: CancelToken(),
    onProgress: (_) {},
    onSuccess: (_) => completed = true,
    onError: (error) => downloadError = error,
  );

  if (downloadError != null) {
    throw downloadError!;
  }
  if (!completed) {
    throw StateError('LiteRT-LM E2E model download did not complete.');
  }
  return p.join(modelsDir, filename);
}

String _filenameFromUrl(String url) {
  final uri = Uri.parse(url);
  for (final segment in uri.pathSegments.reversed) {
    if (segment.trim().isNotEmpty) {
      return segment;
    }
  }
  return 'litert_lm_e2e.litertlm';
}
