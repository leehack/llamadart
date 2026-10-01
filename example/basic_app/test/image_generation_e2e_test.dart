@Tags(['local-only'])
@Timeout(Duration(minutes: 10))
library;

import 'dart:async';
import 'dart:io';

import 'package:llamadart/llamadart.dart';
import 'package:test/test.dart';

// Real image generation through the stable_diffusion runtime this example
// opts into. Downloads nothing: set LLAMADART_SDXS_MODEL, and optionally
// LLAMADART_SD_TURBO_MODEL, LLAMADART_TAESD, LLAMADART_SDXL_LIGHTNING_MODEL,
// LLAMADART_TAESDXL and LLAMADART_IMAGE_OUTPUT_DIR.
void main() {
  final sdxsPath = Platform.environment['LLAMADART_SDXS_MODEL'];
  final sdTurboPath = Platform.environment['LLAMADART_SD_TURBO_MODEL'];
  final taesdPath = Platform.environment['LLAMADART_TAESD'];
  final sdxlLightningPath =
      Platform.environment['LLAMADART_SDXL_LIGHTNING_MODEL'];
  final taesdxlPath = Platform.environment['LLAMADART_TAESDXL'];
  final outputDir = Platform.environment['LLAMADART_IMAGE_OUTPUT_DIR'];
  if (outputDir != null) {
    Directory(outputDir).createSync(recursive: true);
  }

  // Runs first, so this is the process's first runtime probe.
  test('checkRuntime keeps the calling isolate responsive', () async {
    final longestGap = await _longestEventLoopGap(
      ImageGenerationEngine.checkRuntime,
    );

    print(
      'checkRuntime: ${longestGap.elapsed.inMilliseconds} ms; longest event '
      'loop gap ${longestGap.gap.inMilliseconds} ms',
    );
    expect(longestGap.result.isSupported, isTrue);
    // A probe on this isolate would stall it for the whole probe: about 16 s
    // on an M4 Max run with MTL_SHADER_CACHE_SIZE=0 (no Metal shader cache).
    // With the cache warm the probe takes about 0.45 s, too close to the
    // pause of up to 0.5 s when a garbage collection here waits for the probe
    // isolate to load the library, so only the cold case is caught.
    expect(longestGap.gap, lessThan(const Duration(seconds: 2)));
  });

  // Runs before any generation, so the process has not compiled any GPU
  // pipeline yet.
  test('after warmUp the first image is about as fast as a warm one', () async {
    final engine = await ImageGenerationEngine.load(
      ImageGenerationModel.sdxs(sdxsPath!),
    );
    addTearDown(engine.dispose);
    const request = ImageGenerationRequest(
      prompt: 'a red fox in autumn leaves',
      width: 256,
      height: 256,
      seed: 42,
    );

    final warmUp = Stopwatch()..start();
    await engine.warmUp(width: 256, height: 256);
    warmUp.stop();
    final first = (await engine.generateImage(request)).elapsed;
    final second = (await engine.generateImage(request)).elapsed;

    print(
      'warm-up on ${engine.capabilities.backendName}: '
      '${warmUp.elapsedMilliseconds} ms; first image '
      '${first.inMilliseconds} ms; second ${second.inMilliseconds} ms',
    );
    // Without a warm-up the first image pays the pipeline compile: 0.6 s
    // against 0.12 s on an M4 Max run with MTL_SHADER_CACHE_SIZE=0 (no
    // Metal shader cache), and 12 to 45 s on a cold Vulkan driver cache.
    expect(first, lessThan(second * 2 + const Duration(milliseconds: 250)));
  }, skip: sdxsPath == null ? 'Set LLAMADART_SDXS_MODEL' : false);

  test('a rejected split checkpoint names the roles it lacks', () async {
    // SDXS is a single-file checkpoint; as diffusionModel alone it has no VAE
    // or text encoder, so the runtime rejects it.
    await expectLater(
      ImageGenerationEngine.load(
        ImageGenerationModel.custom(
          ImageGenerationModelFiles(diffusionModel: sdxsPath!),
        ),
      ),
      throwsA(
        isA<LlamaModelException>()
            .having(
              (error) => error.message,
              'message',
              allOf(
                contains('needs a vae or taesd file'),
                contains('needs its text encoders'),
              ),
            )
            .having(
              (error) => error.details,
              'details',
              'files: diffusionModel',
            )
            .having((error) => '$error', 'toString', isNot(contains(sdxsPath))),
      ),
    );
  }, skip: sdxsPath == null ? 'Set LLAMADART_SDXS_MODEL' : false);

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
    // A skip: argument would not apply: the scenario passes --run-skipped.
    if (sdTurboPath == null) {
      markTestSkipped('Set LLAMADART_SD_TURBO_MODEL');
      return;
    }
    final engine = await ImageGenerationEngine.load(
      ImageGenerationModel.sdTurbo(sdTurboPath, taesdPath: taesdPath),
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
  });

  test(
    'SDXL-Lightning warms up and generates at 1024x1024 by default',
    () async {
      // A skip: argument would not apply: the scenario passes --run-skipped.
      if (sdxlLightningPath == null) {
        markTestSkipped('Set LLAMADART_SDXL_LIGHTNING_MODEL');
        return;
      }
      final engine = await ImageGenerationEngine.load(
        ImageGenerationModel.sdxlLightning(
          sdxlLightningPath,
          taesdPath: taesdxlPath,
        ),
      );
      addTearDown(engine.dispose);

      final warmUp = Stopwatch()..start();
      await engine.warmUp();
      warmUp.stop();
      final result = await engine.generateImage(
        const ImageGenerationRequest(prompt: 'a lighthouse at dusk', seed: 42),
      );

      final image = result.images.single;
      print(
        'SDXL-Lightning on ${engine.capabilities.backendName}: warm-up '
        '${warmUp.elapsedMilliseconds} ms; ${image.width}x${image.height} '
        'image ${result.elapsed.inMilliseconds} ms',
      );
      expect((image.width, image.height), (1024, 1024));
      expect(image.pixels.toSet().length, greaterThan(64));
      if (outputDir != null) {
        File(
          '$outputDir/sdxl-lightning-default-seed42.png',
        ).writeAsBytesSync(image.toPng());
      }
    },
  );

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

/// Runs [body] while a 10 ms periodic timer measures the longest time the
/// event loop went without running it.
Future<({T result, Duration elapsed, Duration gap})> _longestEventLoopGap<T>(
  Future<T> Function() body,
) async {
  var longest = Duration.zero;
  final sinceTick = Stopwatch()..start();
  void tick() {
    if (sinceTick.elapsed > longest) {
      longest = sinceTick.elapsed;
    }
    sinceTick.reset();
  }

  final timer = Timer.periodic(const Duration(milliseconds: 10), (_) => tick());
  final elapsed = Stopwatch()..start();
  try {
    final result = await body();
    // Counts a stall at the end, whose overdue tick would not run before the
    // timer is cancelled.
    tick();
    return (result: result, elapsed: elapsed.elapsed, gap: longest);
  } finally {
    timer.cancel();
  }
}
