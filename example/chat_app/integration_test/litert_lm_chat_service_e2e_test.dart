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
          preferredBackend: GpuBackend.cpu,
          gpuLayers: 0,
          contextSize: 1024,
          maxTokens: 16,
          nativeLogLevel: LlamaLogLevel.warn,
        ),
      );

      expect(chatService.engine.isReady, isTrue);
      expect(await chatService.engine.getBackendName(), contains('LiteRT-LM'));

      final session = ChatSession(chatService.engine, maxContextTokens: 1024);
      final chunks = await session
          .create(
            [LlamaTextContent('What is 2+2? Answer only with the number.')],
            params: const GenerationParams(maxTokens: 16, seed: 1),
            enableThinking: false,
          )
          .toList();
      final text = chunks.map((chunk) {
        final delta = chunk.choices.first.delta;
        return delta.content ?? delta.thinking ?? '';
      }).join();

      expect(text.trim(), isNotEmpty);
    } finally {
      await chatService.dispose();
    }
  });
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

  await service.deleteModel(modelsDir, model);
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
