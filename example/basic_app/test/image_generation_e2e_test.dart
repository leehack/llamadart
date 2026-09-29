@Tags(['local-only'])
@Timeout(Duration(minutes: 10))
library;

import 'dart:io';

import 'package:llamadart/llamadart.dart';
import 'package:test/test.dart';

// Real image generation through the stable_diffusion runtime this example
// opts into. Downloads nothing: set LLAMADART_SDXS_MODEL, and optionally
// LLAMADART_SD_TURBO_MODEL, LLAMADART_TAESD and LLAMADART_IMAGE_OUTPUT_DIR.
void main() {
  final sdxsPath = Platform.environment['LLAMADART_SDXS_MODEL'];
  final sdTurboPath = Platform.environment['LLAMADART_SD_TURBO_MODEL'];
  final taesdPath = Platform.environment['LLAMADART_TAESD'];
  final outputDir = Platform.environment['LLAMADART_IMAGE_OUTPUT_DIR'];

  group('SDXS', () {
    late ImageGenerationEngine engine;

    setUpAll(() async {
      engine = await ImageGenerationEngine.load(
        ImageGenerationModel.sdxs(sdxsPath!),
      );
    });

    tearDownAll(() => engine.dispose());

    test(
      'generates a 256x256 image in one step with labelled progress',
      () async {
        final task = engine.generate(
          const ImageGenerationRequest(
            prompt: 'a red fox in autumn leaves',
            width: 256,
            height: 256,
            seed: 42,
          ),
        );
        final events = await task.events.toList();

        final phases = events
            .whereType<ImageGenerationProgressEvent>()
            .map((e) => '${e.phase.name} ${e.step}/${e.steps}')
            .toList();
        expect(phases, [
          'encodingPrompt 0/1',
          'sampling 0/1',
          'sampling 1/1',
          'decoding 0/1',
        ]);
        final result = (events.last as ImageGenerationFinalEvent).result;
        final image = result.images.single;
        expect((image.width, image.height, image.channels), (256, 256, 3));
        expect(image.pixels, hasLength(256 * 256 * 3));
        expect(image.pixels.toSet().length, greaterThan(64));
        expect(result.seed, 42);
        final png = image.toPng();
        expect(png.sublist(1, 4), 'PNG'.codeUnits);
        if (outputDir != null) {
          File('$outputDir/sdxs-256-seed42.png').writeAsBytesSync(png);
        }
        expect(
          engine.capabilities.backendName,
          Platform.isMacOS ? startsWith('MTL') : isNotEmpty,
        );
      },
    );

    test('the same seed reproduces the same pixels', () async {
      Future<List<int>> run(int seed) async => (await engine.generateImage(
        ImageGenerationRequest(
          prompt: 'a lighthouse on a cliff',
          width: 256,
          height: 256,
          seed: seed,
        ),
      )).images.single.pixels;

      final first = await run(7);
      expect(await run(7), first);
      expect(await run(8), isNot(first));
    });

    test('a cancel before sampling and a cancel mid-run both stop, and the '
        'engine keeps working', () async {
      final early = engine.generate(
        const ImageGenerationRequest(prompt: 'a forest', steps: 20),
      )..cancel();
      expect(
        (await early.done).state,
        ImageGenerationCompletionState.cancelled,
      );

      final running = engine.generate(
        const ImageGenerationRequest(prompt: 'a forest', steps: 20),
      );
      var lastSamplingStep = 0;
      await for (final event in running.events) {
        if (event case ImageGenerationProgressEvent(
          phase: ImageGenerationPhase.sampling,
          :final step,
        )) {
          lastSamplingStep = step;
          if (step == 1) {
            running.cancel();
          }
        }
      }
      expect(
        (await running.done).state,
        ImageGenerationCompletionState.cancelled,
      );
      expect(lastSamplingStep, lessThan(20));

      final after = await engine.generateImage(
        const ImageGenerationRequest(
          prompt: 'a forest',
          width: 256,
          height: 256,
          seed: 1,
        ),
      );
      expect(after.images.single.width, 256);
    });

    test('rejects a second generation or load while one runs', () async {
      final running = engine.generate(
        const ImageGenerationRequest(prompt: 'a', width: 256, height: 256),
      );

      expect(
        () => engine.generate(const ImageGenerationRequest(prompt: 'b')),
        throwsA(isA<LlamaStateException>()),
      );
      await expectLater(
        ImageGenerationEngine.load(ImageGenerationModel.sdxs(sdxsPath!)),
        throwsA(isA<LlamaStateException>()),
      );
      expect(
        (await running.done).state,
        ImageGenerationCompletionState.completed,
      );
    });
  }, skip: sdxsPath == null ? 'Set LLAMADART_SDXS_MODEL' : false);

  test('SD-Turbo with TAESD generates in one step', () async {
    final engine = await ImageGenerationEngine.load(
      ImageGenerationModel.sdTurbo(sdTurboPath!, taesdPath: taesdPath),
    );
    addTearDown(engine.dispose);

    final result = await engine.generateImage(
      const ImageGenerationRequest(
        prompt: 'a bowl of ramen, studio photo',
        width: 256,
        height: 256,
        seed: 42,
      ),
    );

    expect(engine.capabilities.modelVersion, contains('2.'));
    expect(result.images.single.pixels.toSet().length, greaterThan(64));
    if (outputDir != null) {
      File(
        '$outputDir/sd-turbo-256-seed42.png',
      ).writeAsBytesSync(result.images.single.toPng());
    }
  }, skip: sdTurboPath == null ? 'Set LLAMADART_SD_TURBO_MODEL' : false);

  test('dispose during a generation cancels it', () async {
    final engine = await ImageGenerationEngine.load(
      ImageGenerationModel.sdxs(sdxsPath!),
    );
    final result = engine.generateImage(
      const ImageGenerationRequest(prompt: 'a castle', steps: 20),
    );

    final cancelled = expectLater(result, throwsA(isA<LlamaStateException>()));

    await engine.dispose();

    await cancelled;
    expect(engine.capabilities.isSupported, isFalse);
  }, skip: sdxsPath == null ? 'Set LLAMADART_SDXS_MODEL' : false);
}
