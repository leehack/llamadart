import 'package:llamadart/llamadart.dart';

import 'example_bank.dart';
import 'intents.dart';
import 'sources.dart';

/// EmbeddingGemma 300M, Q8_0, 334 MB, under the Gemma Terms of Use.
final ModelSource defaultEmbeddingModel = ModelSource.huggingFace(
  repoId: 'ggml-org/embeddinggemma-300M-GGUF',
  revision: '0f741b5a6585bd53aeb15cd1372c56f2a0f65e12',
  filePath: 'embeddinggemma-300M-Q8_0.gguf',
);

/// EmbeddingGemma's prompt for classification.
String embeddingPrompt(String text) => 'task: classification | query: $text';

/// Default gate for [ExampleBank] readings, chosen on `evalCases` with
/// `bin/bench.dart`.
const double embeddingEnter = 0.3;

/// Loads [model] (by default [defaultEmbeddingModel]) through [downloads],
/// and fills an [ExampleBank] with [intentDescriptions], [seedExamples] and
/// [corrections].
Future<IntentSource> loadEmbeddingSource({
  ModelSource? model,
  ModelDownloadManager? downloads,
  bool cpu = false,
  Iterable<(CommandIntent, String)> corrections = const [],
  LoadStatus? onStatus,
}) async {
  model ??= defaultEmbeddingModel;
  final engine = LlamaEngine(LlamaBackend(), modelDownloadManager: downloads);
  try {
    onStatus?.call('Loading ${model.fileName}', null);
    await engine.loadModelSource(
      model,
      modelParams: ModelParams(
        contextSize: 512,
        preferredBackend: cpu ? GpuBackend.cpu : GpuBackend.auto,
        gpuLayers: cpu ? 0 : ModelParams.maxGpuLayers,
      ),
      onProgress: (p) => onStatus?.call(
        'Downloading ${model!.fileName}: ${(p.receivedBytes / 1e6).round()}'
        '${p.totalBytes == null ? '' : ' of ${(p.totalBytes! / 1e6).round()}'}'
        ' MB',
        p.fraction,
      ),
    );
    onStatus?.call('Embedding the examples', null);
    final bank = ExampleBank(
      (texts) => engine.embedBatch([for (final t in texts) embeddingPrompt(t)]),
    );
    await bank.addAll([
      for (final e in intentDescriptions.entries) (e.key, e.value),
      ...seedExamples,
      ...corrections,
    ]);
    return IntentSource(
      reader: bank.read,
      enter: embeddingEnter,
      label: await engine.getBackendName(),
      minWords: 2,
      learn: bank.add,
      dispose: engine.dispose,
    );
  } catch (_) {
    await engine.dispose();
    rethrow;
  }
}
