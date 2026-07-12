import 'package:llamadart/llamadart.dart';
import 'package:llamadart_server/src/bootstrap/cli/cli.dart';
import 'package:llamadart_server/src/bootstrap/runtime/engine_initialization.dart';
import 'package:test/test.dart';

void main() {
  test('loads the configured model through a structured ModelSource', () async {
    final config = parseServerCliConfig(
      buildServerCliArgParser().parse(<String>[
        '--model',
        'hf://unsloth/Qwen3.6-27B-GGUF/Qwen3.6-27B-UD-Q4_K_XL.gguf',
        '--context-size',
        '8192',
        '--gpu-layers',
        '42',
      ]),
    );

    ModelSource? loadedSource;
    ModelParams? loadedParams;
    ModelDownloadProgressCallback? progressCallback;

    await loadServerModelSource(
      config,
      loader:
          (
            ModelSource source, {
            required ModelParams modelParams,
            ModelDownloadProgressCallback? onProgress,
          }) async {
            loadedSource = source;
            loadedParams = modelParams;
            progressCallback = onProgress;
          },
    );

    expect(loadedSource, isNotNull);
    expect(loadedSource!.kind, ModelSourceKind.huggingFace);
    expect(loadedSource!.repoId, 'unsloth/Qwen3.6-27B-GGUF');
    expect(loadedSource!.filePath, 'Qwen3.6-27B-UD-Q4_K_XL.gguf');
    expect(loadedParams!.contextSize, 8192);
    expect(loadedParams!.gpuLayers, 42);
    expect(progressCallback, isNotNull);
  });
}
