import 'dart:io';

import 'package:llamadart/llamadart.dart';

/// Usage: dart run bin/llamadart_litert_embedding_example.dart model.litertlm image.png
Future<void> main(List<String> arguments) async {
  final [modelPath, imagePath] = arguments;
  final image = await File(imagePath).readAsBytes();
  final engine = LlamaEngine(LlamaBackend());
  try {
    await engine.setModel(
      LlamaModel(ModelSource.path(modelPath)),
      params: const LiteRtLmModelParams(
        embeddingEngine: true,
        device: ComputeDevice.cpu,
        contextSize: 1024,
      ),
    );
    final vector = await engine.embedContent(
      LlamaEmbeddingInput([
        const LlamaTextContent('A picture: '),
        LlamaImageContent(bytes: image),
      ]),
    );
    print('Pooled embedding: ${vector.length} components');
  } finally {
    await engine.dispose();
  }
}
