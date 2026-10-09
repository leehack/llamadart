@TestOn('vm')
@Tags(['local-only', 'e2e'])
@Timeout(Duration(minutes: 20))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';
import 'package:test/test.dart';

/// An image whose projector decodes it non-causally against a context whose
/// micro-batch is smaller than the image, as in issue #958.
///
/// Set `MULTIMODAL_MICRO_BATCH_MODEL` to a chat GGUF whose projector is
/// non-causal (Gemma 3, or a Gemma 4 model other than E2B and E4B) and
/// `MULTIMODAL_MICRO_BATCH_MMPROJ` to that projector.
/// `MULTIMODAL_MICRO_BATCH_BACKEND` is a `GpuBackend` name and defaults to
/// `cpu`.
void main() {
  final modelPath = Platform.environment['MULTIMODAL_MICRO_BATCH_MODEL'] ?? '';
  final mmprojPath =
      Platform.environment['MULTIMODAL_MICRO_BATCH_MMPROJ'] ?? '';
  final backend = GpuBackend.values.byName(
    Platform.environment['MULTIMODAL_MICRO_BATCH_BACKEND'] ?? 'cpu',
  );
  final skip = modelPath.isEmpty || mmprojPath.isEmpty
      ? 'Set MULTIMODAL_MICRO_BATCH_MODEL and MULTIMODAL_MICRO_BATCH_MMPROJ '
            'to a model with a non-causal projector.'
      : null;

  Future<LlamaEngine> load({int batchSize = 0, int microBatchSize = 0}) =>
      LlamaEngine.load(
        LlamaModel(
          ModelSource.path(modelPath),
          projector: ModelSource.path(mmprojPath),
        ),
        params: ModelParams(
          contextSize: 4096,
          gpuLayers: backend == GpuBackend.cpu ? 0 : ModelParams.maxGpuLayers,
          preferredBackend: backend,
          batchSize: batchSize,
          microBatchSize: microBatchSize,
        ),
      );

  Future<String> colorOf(LlamaEngine engine, Uint8List image) async {
    final reply = await engine.complete(
      [
        LlamaChatMessage.withContent(
          role: LlamaChatRole.user,
          content: [
            LlamaImageContent(bytes: image),
            const LlamaTextContent(
              'What single color fills this image? Answer with one word.',
            ),
          ],
        ),
      ],
      params: const GenerationParams(maxTokens: 8, temp: 0, seed: 1),
      enableThinking: false,
    );
    return reply.text.trim().toLowerCase();
  }

  void report(String name, Map<String, Object?> result) {
    // ignore: avoid_print
    print(
      'MULTIMODAL_MICRO_BATCH ${jsonEncode({'case': name, 'backend': backend.name, ...result})}',
    );
  }

  /// The token count and micro-batch a rejected image's error names.
  (int imageTokens, int microBatch) limits(LlamaInferenceException error) {
    final match = RegExp(
      r'image input has (\d+) tokens, .* at most (\d+) tokens',
    ).firstMatch(error.message);
    expect(match, isNotNull, reason: error.message);
    return (int.parse(match!.group(1)!), int.parse(match.group(2)!));
  }

  test('an image that fits the default micro-batch is answered', () async {
    final engine = await load();
    addTearDown(engine.dispose);

    final answer = await colorOf(engine, _redBitmap(336));

    report('default', {'answer': answer});
    expect(answer, contains('red'));
  }, skip: skip);

  for (final (name, batchSize) in [('', 0), (' and equal batch', 32)]) {
    test('an image above an explicit micro-batch$name is a typed error and '
        'the engine keeps working', () async {
      final engine = await load(batchSize: batchSize, microBatchSize: 32);
      addTearDown(engine.dispose);

      Object? error;
      String? answer;
      try {
        answer = await colorOf(engine, _redBitmap(336));
      } on LlamaException catch (caught) {
        error = caught;
      }
      report('microBatchSize 32, batchSize $batchSize', {
        'answer': answer,
        'error': error?.toString(),
      });

      expect(error, isA<LlamaInferenceException>());
      final (imageTokens, microBatch) = limits(
        error! as LlamaInferenceException,
      );
      expect(microBatch, 32);
      expect(imageTokens, greaterThan(32));
      expect(error.toString(), contains('ModelParams.microBatchSize'));
      final text = await engine.complete(const [
        LlamaChatMessage.fromText(
          role: LlamaChatRole.user,
          text: 'Reply with the word ready.',
        ),
      ], params: const GenerationParams(maxTokens: 8, temp: 0, seed: 1));
      expect('${text.thinking}${text.text}', isNotEmpty);
    }, skip: skip);
  }

  test('an image above the default micro-batch is a typed error, and the '
      'micro-batch the error names answers it', () async {
    final image = _redBitmap(2016);
    final engine = await load();
    addTearDown(engine.dispose);

    Object? error;
    String? answer;
    try {
      answer = await colorOf(engine, image);
    } on LlamaException catch (caught) {
      error = caught;
    }
    report('default micro-batch, large image', {
      'answer': answer,
      'error': error?.toString(),
    });
    expect(error, isA<LlamaInferenceException>());
    final (imageTokens, microBatch) = limits(error! as LlamaInferenceException);
    expect(microBatch, ModelParams.defaultMicroBatchSize);
    expect(imageTokens, greaterThan(microBatch));
    await engine.dispose();

    final roomy = await load(batchSize: 2048, microBatchSize: imageTokens);
    addTearDown(roomy.dispose);
    final roomyAnswer = await colorOf(roomy, image);

    report('microBatchSize $imageTokens, large image', {'answer': roomyAnswer});
    expect(roomyAnswer, contains('red'));
  }, skip: skip);
}

/// A [side] by [side] 24-bit BMP filled with red.
Uint8List _redBitmap(int side) {
  final rowBytes = (side * 3 + 3) & ~3;
  final bytes = Uint8List(54 + rowBytes * side);
  final header = ByteData.sublistView(bytes);
  header.setUint8(0, 0x42);
  header.setUint8(1, 0x4d);
  header.setUint32(2, bytes.length, Endian.little);
  header.setUint32(10, 54, Endian.little);
  header.setUint32(14, 40, Endian.little);
  header.setInt32(18, side, Endian.little);
  header.setInt32(22, side, Endian.little);
  header.setUint16(26, 1, Endian.little);
  header.setUint16(28, 24, Endian.little);
  header.setUint32(34, rowBytes * side, Endian.little);
  for (var row = 0; row < side; row++) {
    final start = 54 + row * rowBytes;
    for (var column = 0; column < side; column++) {
      bytes[start + column * 3 + 2] = 0xff;
    }
  }
  return bytes;
}
