import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'package:llamadart/llamadart.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('Native Smoke Test', () {
    testWidgets('Verify native library load and basic inference', (
      tester,
    ) async {
      try {
        // 1. Basic Init Check
        llama_backend_init();

        final sysInfoPtr = llama_print_system_info();
        expect(sysInfoPtr, isNotNull);
        sysInfoPtr.cast<Utf8>().toDartString();

        // 2. Download Tiny Model
        const configuredModelUrl = String.fromEnvironment(
          'LLAMADART_GGUF_MODEL_URL',
        );
        const configuredModelPath = String.fromEnvironment(
          'LLAMADART_GGUF_MODEL',
        );
        const defaultModelUrl =
            'https://huggingface.co/ggml-org/tiny-llamas/resolve/main/stories15M.gguf';
        final modelUrl = configuredModelUrl.isEmpty
            ? defaultModelUrl
            : configuredModelUrl;

        final Directory dataDir;
        if (Platform.isAndroid || Platform.isIOS) {
          dataDir = await getApplicationDocumentsDirectory();
        } else {
          dataDir = Directory(path.join(Directory.current.path, 'models'));
          if (!dataDir.existsSync()) dataDir.createSync(recursive: true);
        }

        final modelPath = configuredModelPath.isNotEmpty
            ? configuredModelPath
            : path.join(dataDir.path, _filenameFromUrl(modelUrl));
        final modelFile = File(modelPath);

        if (configuredModelPath.isEmpty && !modelFile.existsSync()) {
          await _downloadFile(modelUrl, modelFile);
        }

        // 3. Full Inference Pipeline Test
        final backend = LlamaBackend();
        final engine = LlamaEngine(backend);

        final preferredBackend = _backendFromEnvironment();
        await engine.loadModel(
          modelPath,
          modelParams: ModelParams(
            contextSize: 2048,
            preferredBackend: preferredBackend,
            gpuLayers: preferredBackend == GpuBackend.cpu
                ? 0
                : ModelParams.maxGpuLayers,
            numberOfThreads: 4,
            numberOfThreadsBatch: 4,
          ),
        );
        expect(engine.isReady, isTrue);

        final stream = engine.create([
          const LlamaChatMessage.fromText(
            role: LlamaChatRole.user,
            text: 'Hello',
          ),
        ], params: const GenerationParams(maxTokens: 1));
        final tokens = await stream.toList();

        expect(tokens, isNotEmpty);

        await engine.dispose();
        llama_backend_free();
      } catch (e) {
        fail('Smoke test failed: $e');
      }
    });
  });
}

GpuBackend _backendFromEnvironment() {
  const backend = String.fromEnvironment(
    'LLAMADART_GGUF_BACKEND',
    defaultValue: 'auto',
  );
  switch (backend.trim().toLowerCase()) {
    case 'auto':
      return GpuBackend.auto;
    case 'cpu':
      return GpuBackend.cpu;
    case 'metal':
      return GpuBackend.metal;
    default:
      throw ArgumentError.value(
        backend,
        'LLAMADART_GGUF_BACKEND',
        'Expected auto, cpu, or metal.',
      );
  }
}

String _filenameFromUrl(String url) {
  final uri = Uri.parse(url);
  for (final segment in uri.pathSegments.reversed) {
    if (segment.trim().isNotEmpty) {
      return segment;
    }
  }
  return 'test_model.gguf';
}

Future<void> _downloadFile(String url, File output) async {
  final client = http.Client();
  final tempFile = File('${output.path}.tmp');
  try {
    final request = http.Request('GET', Uri.parse(url));
    final response = await client.send(request);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'Failed to download $url: HTTP ${response.statusCode}',
        uri: Uri.parse(url),
      );
    }
    await tempFile.parent.create(recursive: true);
    final sink = tempFile.openWrite();
    try {
      await response.stream.pipe(sink);
    } finally {
      await sink.close();
    }
    if (await output.exists()) {
      await output.delete();
    }
    await tempFile.rename(output.path);
  } finally {
    client.close();
    if (await tempFile.exists()) {
      await tempFile.delete();
    }
  }
}
