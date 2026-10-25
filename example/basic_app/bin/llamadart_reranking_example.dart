import 'dart:io';

import 'package:llamadart/llamadart.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    stderr.writeln(
      'Usage: dart run bin/llamadart_reranking_example.dart <reranker.gguf>',
    );
    exitCode = 64;
    return;
  }
  final reranker = await LlamaReranker.load(
    LlamaModel(ModelSource.path(arguments.single)),
    params: const LlamaCppModelParams(
      gpuLayers: 0,
      preferredBackend: GpuBackend.cpu,
      contextSize: 2048,
      batchSize: 2048,
      microBatchSize: 2048,
      maxParallelSequences: 4,
    ),
  );
  try {
    final support = await reranker.capabilities;
    if (!support.isSupported) {
      throw LlamaUnsupportedException(support.unsupportedReason!);
    }
    const documents = [
      'Paris is the capital of France.',
      'Rome is the capital of Italy.',
      'A banana is a yellow fruit.',
    ];
    final results = await reranker.rerank(
      'What is the capital of France?',
      documents,
    );
    for (final result in results) {
      stdout.writeln('${result.score}: ${documents[result.index]}');
    }
  } finally {
    await reranker.dispose();
  }
}
