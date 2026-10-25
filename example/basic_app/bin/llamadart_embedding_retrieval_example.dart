import 'dart:io';

import 'package:llamadart/llamadart.dart';

/// Run with a compatible EG2 GGUF path; this example downloads no model.
Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    stderr.writeln(
      'Usage: dart run bin/llamadart_embedding_retrieval_example.dart <EG2.gguf>',
    );
    exitCode = 64;
    return;
  }
  final engine = await LlamaEngine.load(
    LlamaModel(ModelSource.path(arguments.single)),
    params: const LlamaCppModelParams(
      contextSize: 1024,
      batchSize: 1024,
      microBatchSize: 1024,
      preferredBackend: GpuBackend.cpu,
      gpuLayers: 0,
    ),
  );
  try {
    final embedder = LlamaTextEmbedder(
      engine,
      profile: LlamaEmbeddingProfile.embeddingGemma2,
      dimensions: 256,
    );
    const documents = [
      LlamaEmbeddingText.document(
        'Charged solar particles interact with atmospheric gases.',
        title: 'Aurora',
      ),
      LlamaEmbeddingText.document(
        'A sourdough starter cultures yeast and bacteria in flour and water.',
        title: 'Bread',
      ),
    ];
    final vectors = await embedder.embedBatch(documents);
    final query = await embedder.embed(
      const LlamaEmbeddingText.query('What causes the northern lights?'),
    );
    for (var i = 0; i < documents.length; i++) {
      var score = 0.0;
      for (var d = 0; d < query.length; d++) {
        score += query[d] * vectors[i][d];
      }
      print('${documents[i].title}: ${score.toStringAsFixed(4)}');
    }
  } finally {
    await engine.dispose();
  }
}
