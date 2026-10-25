import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:llamadart/llamadart.dart';
import 'package:test/test.dart';

/// Exercises the actual context cache, independently of sampling settings.
Future<void> compareImageConditioningCache({
  required ImageGenerationModel model,
  required ComputeDevice device,
  required String label,
}) async {
  const prompts = ['a red fox', 'a blue boat', 'a green forest'];
  const sequence = [0, 0, 1, 1, 2, 0, 0];
  final baseline = <String, Uint8List>{};
  final records = <LlamaLogRecord>[];
  await LlamaLogging.configure(level: LlamaLogLevel.info, handler: records.add);
  try {
    for (final capacity in [0, null, 1]) {
      Future<ImageGenerationEngine> load() => ImageGenerationEngine.load(
        model,
        params: capacity == null
            ? ImageModelParams(
                device: device,
                flashAttention: false,
                vaeDirectConvolution: false,
              )
            : ImageConditioningCacheParams(
                capacity: capacity,
                device: device,
                flashAttention: false,
                vaeDirectConvolution: false,
              ),
      );
      final engine = await load();
      final backend = (await engine.capabilities).backendName;
      var hits = 0;
      ImageGenerationRequest request(String prompt, {int steps = 1}) =>
          ImageGenerationRequest(
            prompt: prompt,
            width: 256,
            height: 256,
            steps: steps,
            guidanceScale: 1,
            seed: 42,
          );
      Future<void> generate(String prompt, {required bool hit}) async {
        records.clear();
        final result = await engine.generateImage(request(prompt));
        final pixels = result.images.single.pixels;
        expect(
          (result.images.single.width, result.images.single.height),
          (256, 256),
        );
        expect(pixels.toSet().length, greaterThan(32));
        final cacheHits = records
            .where(
              (record) => record.message.contains('conditioning cache hit'),
            )
            .length;
        expect(
          cacheHits,
          hit ? 1 : 0,
          reason: '$label $backend capacity=$capacity $prompt',
        );
        hits += cacheHits;
        print(
          'CONDITIONING_PIXELS $label backend=$backend capacity=$capacity '
          'prompt=${prompts.indexOf(prompt)} sha256=${sha256.convert(pixels)}',
        );
        if (baseline[prompt] case final expected?) {
          expect(
            pixels,
            expected,
            reason: '$label $backend capacity=$capacity $prompt',
          );
        } else {
          expect(capacity, 0);
          baseline[prompt] = Uint8List.fromList(pixels);
        }
      }

      try {
        for (final (index, promptIndex) in sequence.indexed) {
          final hit =
              capacity != 0 &&
              (index == 1 ||
                  index == 3 ||
                  index == 6 ||
                  (capacity == null && index == 5));
          await generate(prompts[promptIndex], hit: hit);
        }
        // A fresh prompt ensures cancellation also exercises a cache miss.
        final cancelled = await engine.generate(
          request('a yellow bird', steps: 20),
        );
        var lastStep = -1;
        await for (final event in cancelled.events) {
          if (event case ImageGenerationProgressEvent(
            phase: ImageGenerationPhase.sampling,
            :final step,
          ) when step > 0) {
            lastStep = step;
            cancelled.cancel();
          }
        }
        expect(
          (await cancelled.done).state,
          ImageGenerationCompletionState.cancelled,
        );
        expect(lastStep, inInclusiveRange(1, 19));
        // Cancellation may retain valid conditioning; it must not alter images.
        await generate(prompts.first, hit: capacity == null);
        print(
          'CONDITIONING_CACHE $label backend=$backend capacity=$capacity '
          'sequenceHits=$hits exactPixels=PASS eviction=PASS cancelReuse=PASS',
        );
      } finally {
        await engine.dispose();
      }
      final reloaded = await load();
      try {
        records.clear();
        final image = (await reloaded.generateImage(
          request(prompts.first),
        )).images.single;
        expect(image.pixels, baseline[prompts.first]);
        expect(
          records.where(
            (record) => record.message.contains('conditioning cache hit'),
          ),
          isEmpty,
        );
        print(
          'CONDITIONING_CACHE $label backend=$backend capacity=$capacity reload=PASS',
        );
      } finally {
        await reloaded.dispose();
      }
    }
  } finally {
    await LlamaLogging.configure();
  }
}
