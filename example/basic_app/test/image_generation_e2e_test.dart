// ignore_for_file: implementation_imports
@Tags(['local-only'])
@Timeout(Duration(minutes: 10))
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/stable_diffusion/stable_diffusion_image_worker.dart';
import 'package:llamadart/src/backends/stable_diffusion/stable_diffusion_memory.dart';
import 'package:llamadart/src/core/image/image_generation_driver.dart';
import 'package:test/test.dart';

import 'fixtures/image_warmup_comparison.dart';

// Real image generation through the stable_diffusion runtime this example
// opts into. Set LLAMADART_SDXS_MODEL, and optionally
// LLAMADART_SD_TURBO_MODEL, LLAMADART_TAESD, LLAMADART_SDXL_LIGHTNING_MODEL,
// LLAMADART_TAESDXL and LLAMADART_IMAGE_OUTPUT_DIR. Downloads nothing unless
// LLAMADART_IMAGE_HF_CACHE names a model cache directory: then SDXS loads
// from its pinned Hugging Face file through it (683 MB once).
// LLAMADART_IMAGE_SPLIT_MODEL lists a split model's local files, comma
// separated in any order, such as FLUX.1-schnell's transformer, ae, CLIP-L
// and T5-XXL; the engine assigns their roles and generates 4 steps at 512.
// LLAMADART_IMAGE_CHECKPOINT_FORMATS and LLAMADART_TAESD_FORMATS compare
// comma-separated same-weight container variants on the CPU, baseline first.
void main() {
  final sdxsPath = Platform.environment['LLAMADART_SDXS_MODEL'];
  final sdTurboPath = Platform.environment['LLAMADART_SD_TURBO_MODEL'];
  final taesdPath = Platform.environment['LLAMADART_TAESD'];
  final sdxlLightningPath =
      Platform.environment['LLAMADART_SDXL_LIGHTNING_MODEL'];
  final taesdxlPath = Platform.environment['LLAMADART_TAESDXL'];
  final hfCache = Platform.environment['LLAMADART_IMAGE_HF_CACHE'];
  final splitModel = Platform.environment['LLAMADART_IMAGE_SPLIT_MODEL'];
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
      _sdxs(ModelSource.path(sdxsPath!)),
    );
    addTearDown(engine.dispose);
    final backendName = (await engine.capabilities).backendName!;
    final timings = await measureImageWarmUp(
      backendName: backendName,
      warmUp: () => engine.warmUp(width: 256, height: 256, guidanceScale: 1),
      generate: (request) async =>
          (await engine.generateImage(request)).elapsed,
    );
    if (timings == null) {
      print('warm-up on $backendName: CPU validation/no-op; GPU timing N/A');
      return;
    }
    print(
      'warm-up on $backendName: ${timings.warmUp.inMilliseconds} ms; '
      'first uncached image ${timings.first.inMilliseconds} ms; '
      'second uncached ${timings.second.inMilliseconds} ms',
    );
    // Both prompts miss the conditioning cache with the same padded CLIP
    // shape. Without warm-up the first also pays the GPU pipeline compile.
    expect(
      timings.first,
      lessThan(timings.second * 2 + const Duration(milliseconds: 250)),
    );
  }, skip: sdxsPath == null ? 'Set LLAMADART_SDXS_MODEL' : false);

  for (final (role, variable) in [
    (ImageModelRole.checkpoint, 'LLAMADART_IMAGE_CHECKPOINT_FORMATS'),
    (ImageModelRole.taesd, 'LLAMADART_TAESD_FORMATS'),
  ]) {
    test('${role.name} containers preserve CPU pixels', () async {
      final paths = Platform.environment[variable]?.split(',');
      if (paths == null || taesdPath == null || sdTurboPath == null) {
        markTestSkipped(
          'Set $variable, LLAMADART_SD_TURBO_MODEL and LLAMADART_TAESD',
        );
        return;
      }
      expect(paths.length, greaterThanOrEqualTo(2));
      List<int>? baseline;
      for (final (index, path) in paths.indexed) {
        final checkpoint = role == ImageModelRole.checkpoint;
        final engine = await ImageGenerationEngine.load(
          ImageGenerationModel(
            ModelSource.path(checkpoint ? path.trim() : sdTurboPath),
            role: checkpoint && index > 0 ? role : null,
            components: [
              ImageModelComponent(
                ModelSource.path(checkpoint ? taesdPath : path.trim()),
                role: ImageModelRole.taesd,
              ),
            ],
          ),
          params: const ImageModelParams(device: ComputeDevice.cpu, threads: 4),
        );
        try {
          expect((await engine.capabilities).backendName, 'CPU');
          final result = await engine.generateImage(
            const ImageGenerationRequest(
              prompt: 'a red apple on a wooden table',
              width: 128,
              height: 128,
              steps: 1,
              guidanceScale: 1,
              seed: 42,
            ),
          );
          final image = result.images.single;
          expect((image.width, image.height, image.channels), (128, 128, 3));
          if (baseline == null) {
            expect(image.pixels.toSet().length, greaterThan(64));
            baseline = image.pixels;
          } else {
            expect(
              image.pixels,
              baseline,
              reason: '$variable candidate $index',
            );
          }
        } finally {
          await engine.dispose();
        }
      }
    });
  }

  test('a rejected split checkpoint names the roles it lacks', () async {
    // SDXS is a single-file checkpoint; given the diffusionModel role it has
    // no VAE or text encoder, so the runtime rejects it.
    await expectLater(
      ImageGenerationEngine.load(
        ImageGenerationModel(
          ModelSource.path(sdxsPath!),
          role: ImageModelRole.diffusionModel,
        ),
      ),
      throwsA(
        isA<LlamaModelException>()
            .having(
              (error) => error.message,
              'message',
              allOf(
                contains('need a vae or taesd file'),
                contains('need their text encoders'),
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

  test('a load the runtime rejects carries the reason the runtime logged, '
      'with files named by role', () async {
    final directory = await Directory.systemTemp.createTemp('llamadart-img-');
    addTearDown(() => directory.delete(recursive: true));
    // The header and the first tensors: the roles are detected, and the
    // runtime finds tensors past the end of the file.
    final truncated = File('${directory.path}/truncated.gguf');
    final source = await File(sdxsPath!).open();
    try {
      await truncated.writeAsBytes(await source.read(64 << 20));
    } finally {
      await source.close();
    }
    final missing = '${directory.path}/missing.gguf';

    Future<String> reasonOf(Future<Object?> load) async {
      try {
        await load;
      } on LlamaModelException catch (error) {
        expect('$error', isNot(contains(directory.path)));
        expect('$error', isNot(contains(sdxsPath)));
        return RegExp(
          r'The runtime reported: "(.*)"\.',
        ).firstMatch(error.message)!.group(1)!;
      }
      fail('The load succeeded.');
    }

    final reasons = {
      'truncated file': await reasonOf(
        ImageGenerationEngine.load(_sdxs(ModelSource.path(truncated.path))),
      ),
      // The engine refuses a missing file itself, so this one goes straight
      // to the worker.
      'missing file': await reasonOf(
        StableDiffusionImageWorker.start(
          ImageGenerationSessionConfig(
            files: {'model': missing},
            backend: null,
            threads: 0,
          ),
        ),
      ),
      'wrong role': await reasonOf(
        ImageGenerationEngine.load(
          ImageGenerationModel(
            ModelSource.path(sdxsPath),
            role: ImageModelRole.diffusionModel,
          ),
        ),
      ),
    };

    print('IMAGE_LOAD_FAILURE_REASONS $reasons');
    expect(reasons['truncated file'], contains('<checkpoint file>'));
    expect(reasons['missing file'], contains('<checkpoint file>'));
    expect(reasons.values.toSet(), hasLength(3));

    // The engine still loads afterwards.
    final engine = await ImageGenerationEngine.load(
      _sdxs(ModelSource.path(sdxsPath)),
    );
    await engine.dispose();
  }, skip: sdxsPath == null ? 'Set LLAMADART_SDXS_MODEL' : false);

  test('the runtime\'s messages reach the log handler at the configured '
      'levels, by level and without paths, and none do by default', () async {
    Future<List<LlamaLogRecord>> recordsAt(LlamaLogLevel level) async {
      final records = <LlamaLogRecord>[];
      await LlamaLogging.configure(level: level, handler: records.add);
      try {
        final engine = await ImageGenerationEngine.load(
          _sdxs(ModelSource.path(sdxsPath!)),
        );
        final loaded = records.length;
        await engine.generateImage(
          const ImageGenerationRequest(
            prompt: 'a red fox in autumn leaves',
            width: 256,
            height: 256,
            steps: 1,
            guidanceScale: 1,
            seed: 42,
          ),
        );
        final generated = records.length;
        await engine.dispose();
        print(
          'IMAGE_LOG ${level.name}: ${records.length} records ($loaded after '
          'the load, ${generated - loaded} after the generation, '
          '${records.length - generated} at dispose); by level '
          '${{for (final l in LlamaLogLevel.values) l.name: records.where((r) => r.level == l).length}}',
        );
      } finally {
        await LlamaLogging.configure();
      }
      return records;
    }

    final silent = await recordsAt(LlamaLogLevel.none);
    final info = await recordsAt(LlamaLogLevel.info);
    final debug = await recordsAt(LlamaLogLevel.debug);
    final error = await recordsAt(LlamaLogLevel.error);

    expect(silent, isEmpty);
    expect(error, isEmpty);
    expect(info, isNotEmpty);
    for (final record in info.take(6)) {
      print('IMAGE_LOG_RECORD [${record.level.name}] ${record.message}');
    }
    expect(
      info.map((record) => record.level),
      everyElement(isIn([LlamaLogLevel.info, LlamaLogLevel.warn])),
    );
    expect(debug.length, greaterThan(info.length));
    expect(debug.map((record) => record.level), contains(LlamaLogLevel.debug));
    for (final record in debug) {
      expect(record.message, startsWith('stable_diffusion: '));
      expect(record.message, isNot(contains(sdxsPath!)));
    }
    expect(
      debug.map((record) => record.message),
      contains(contains('<checkpoint file>')),
    );
  }, skip: sdxsPath == null ? 'Set LLAMADART_SDXS_MODEL' : false);

  test('the GPU memory the runtime reports for Metal is the working set '
      'the memory check reads itself', () async {
    final memory = (await Isolate.run(readStableDiffusionGpuMemory))!.single;
    final workingSet = readStableDiffusionMemoryBudget(
      device: ImageGenerationComputeDevice.metal,
    )!;

    print(
      'IMAGE_GPU_MEMORY ${memory.name}: total ${memory.totalBytes}, free '
      '${memory.freeBytes}, integrated ${memory.integrated}; '
      '${workingSet.source}: ${workingSet.bytes}',
    );
    expect(memory.name, startsWith('MTL'));
    expect(memory.integrated, isFalse);
    expect(memory.freeBytes, inInclusiveRange(1, memory.totalBytes));
    expect(workingSet.source, "Metal's recommended GPU working set");
    expect(memory.totalBytes, workingSet.bytes);
  }, skip: Platform.isMacOS ? false : 'macOS only');

  group('SDXS', () {
    late ImageGenerationEngine engine;

    setUpAll(() async {
      engine = await ImageGenerationEngine.load(
        _sdxs(ModelSource.path(sdxsPath!)),
      );
    });

    tearDownAll(() => engine.dispose());

    test(
      'generates a 256x256 image in one step with labelled progress',
      () async {
        final task = await engine.generate(
          const ImageGenerationRequest(
            prompt: 'a red fox in autumn leaves',
            width: 256,
            height: 256,
            steps: 1,
            guidanceScale: 1,
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
          (await engine.capabilities).backendName,
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
          steps: 1,
          guidanceScale: 1,
          seed: seed,
        ),
      )).images.single.pixels;

      final first = await run(7);
      expect(await run(7), first);
      expect(await run(8), isNot(first));
    });

    test('a cancel before sampling and a cancel mid-run both stop, and the '
        'engine keeps working', () async {
      final early = await engine.generate(
        const ImageGenerationRequest(prompt: 'a forest', steps: 20),
      );
      early.cancel();
      expect(
        (await early.done).state,
        ImageGenerationCompletionState.cancelled,
      );

      final running = await engine.generate(
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
          steps: 1,
          guidanceScale: 1,
          seed: 1,
        ),
      );
      expect(after.images.single.width, 256);
    });

    test('rejects a second generation or load while one runs', () async {
      final running = await engine.generate(
        const ImageGenerationRequest(prompt: 'a', width: 256, height: 256),
      );

      await expectLater(
        engine.generate(const ImageGenerationRequest(prompt: 'b')),
        throwsA(isA<LlamaStateException>()),
      );
      await expectLater(
        ImageGenerationEngine.load(_sdxs(ModelSource.path(sdxsPath!))),
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
      ImageGenerationModel(
        ModelSource.path(sdTurboPath),
        components: [
          if (taesdPath != null)
            ImageModelComponent.auto(ModelSource.path(taesdPath)),
        ],
      ),
    );
    addTearDown(engine.dispose);

    final result = await engine.generateImage(
      const ImageGenerationRequest(
        prompt: 'a bowl of ramen, studio photo',
        width: 256,
        height: 256,
        steps: 1,
        guidanceScale: 1,
        seed: 42,
      ),
    );

    expect((await engine.capabilities).modelVersion, contains('2.'));
    expect(result.images.single.pixels.toSet().length, greaterThan(64));
    if (outputDir != null) {
      File(
        '$outputDir/sd-turbo-256-seed42.png',
      ).writeAsBytesSync(result.images.single.toPng());
    }
  });

  test('VAE tiling decodes SD-Turbo\'s full VAE in tiles with a smaller '
      'compute buffer on each device, and an untiled request after it is '
      'unchanged', () async {
    // A skip: argument would not apply: the scenario passes --run-skipped.
    if (sdTurboPath == null) {
      markTestSkipped('Set LLAMADART_SD_TURBO_MODEL');
      return;
    }
    final records = <LlamaLogRecord>[];
    await LlamaLogging.configure(
      level: LlamaLogLevel.debug,
      handler: records.add,
    );
    addTearDown(LlamaLogging.configure);

    double? logged(List<String> log, String pattern) {
      final values = [
        for (final line in log)
          if (RegExp(pattern).firstMatch(line) case final match?)
            double.parse(match.group(1)!),
      ];
      return values.isEmpty ? null : values.reduce(max);
    }

    final measured = <String>{};
    for (final device in [ComputeDevice.auto, ComputeDevice.cpu]) {
      final engine = await ImageGenerationEngine.load(
        ImageGenerationModel(ModelSource.path(sdTurboPath)),
        params: ImageModelParams(device: device),
      );
      try {
        final backendName = (await engine.capabilities).backendName!;
        if (!measured.add(backendName)) {
          continue;
        }

        Future<({GeneratedImage image, List<String> log})> run(
          ImageVaeTiling? tiling,
        ) async {
          final start = records.length;
          final result = await engine.generateImage(
            ImageGenerationRequest(
              prompt: 'a lighthouse at dusk',
              width: 512,
              height: 512,
              steps: 1,
              guidanceScale: 1,
              seed: 42,
              vaeTiling: tiling,
            ),
          );
          return (
            image: result.images.single,
            log: [for (final r in records.skip(start)) r.message],
          );
        }

        final untiled = await run(null);
        final tiled = await run(const ImageVaeTiling());
        final again = await run(null);

        const buffer = r'vae compute buffer size: ([\d.]+) MB';
        const decode = r'decode_first_stage completed, taking ([\d.]+)s';
        final untiledMb = logged(untiled.log, buffer);
        final tiledMb = logged(tiled.log, buffer);
        final a = untiled.image.pixels;
        final b = tiled.image.pixels;
        var sum = 0;
        var largest = 0;
        for (var i = 0; i < a.length; i++) {
          final d = (a[i] - b[i]).abs();
          sum += d;
          largest = max(largest, d);
        }
        print(
          'VAE_TILING $backendName 512x512 tile 256 overlap 0.5: VAE compute '
          'buffer $untiledMb MB untiled, $tiledMb MB tiled; decode '
          '${logged(untiled.log, decode)} s untiled, '
          '${logged(tiled.log, decode)} s tiled; pixel difference mean '
          '${(sum / a.length).toStringAsFixed(2)}, max $largest of 255',
        );
        if (outputDir != null) {
          final name = backendName.toLowerCase();
          File(
            '$outputDir/sd-turbo-512-$name-vae-untiled.png',
          ).writeAsBytesSync(untiled.image.toPng());
          File(
            '$outputDir/sd-turbo-512-$name-vae-tiled-256.png',
          ).writeAsBytesSync(tiled.image.toPng());
        }

        expect(
          tiled.log,
          contains(contains('VAE decode tile size: 256x256 pixels')),
        );
        for (final log in [untiled.log, again.log]) {
          expect(log, isNot(contains(contains('VAE decode tile size'))));
        }
        expect(untiledMb, isNotNull);
        expect(tiledMb, lessThan(untiledMb! / 2));
        expect((tiled.image.width, tiled.image.height), (512, 512));
        // Tiles blend where they overlap, so pixels differ slightly.
        expect(sum / a.length, lessThan(4));
        expect(again.image.pixels, a);
      } finally {
        await engine.dispose();
      }
    }
  });

  test('SDXL-Lightning warms up and generates at 1024x1024', () async {
    // A skip: argument would not apply: the scenario passes --run-skipped.
    if (sdxlLightningPath == null) {
      markTestSkipped('Set LLAMADART_SDXL_LIGHTNING_MODEL');
      return;
    }
    final engine = await ImageGenerationEngine.load(
      ImageGenerationModel(
        ModelSource.path(sdxlLightningPath),
        components: [
          if (taesdxlPath != null)
            ImageModelComponent.auto(ModelSource.path(taesdxlPath)),
        ],
      ),
    );
    addTearDown(engine.dispose);

    final warmUp = Stopwatch()..start();
    await engine.warmUp(width: 1024, height: 1024, guidanceScale: 1);
    warmUp.stop();
    final result = await engine.generateImage(
      const ImageGenerationRequest(
        prompt: 'a lighthouse at dusk',
        width: 1024,
        height: 1024,
        steps: 4,
        guidanceScale: 1,
        sampler: ImageGenerationSampler.euler,
        scheduler: ImageGenerationScheduler.sgmUniform,
        seed: 42,
      ),
    );

    final image = result.images.single;
    print(
      'SDXL-Lightning on ${(await engine.capabilities).backendName}: warm-up '
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
  });

  test(
    'SDXS loads from its pinned Hugging Face file through the model cache, then '
    'reuses it',
    () async {
      // A skip: argument would not apply: the scenario passes --run-skipped.
      if (hfCache == null) {
        markTestSkipped('Set LLAMADART_IMAGE_HF_CACHE');
        return;
      }
      final downloads = DefaultModelDownloadManager(
        defaultCacheDirectory: hfCache,
      );
      const total = 682847200;

      Future<List<ModelDownloadProgress>> loadAndGenerate() async {
        final events = <ModelDownloadProgress>[];
        final timer = Stopwatch()..start();
        final engine = await ImageGenerationEngine.load(
          ImageGenerationModel(_pinnedSdxs),
          store: ModelFileStore(downloadManager: downloads),
          onProgress: events.add,
        );
        final loaded = timer.elapsedMilliseconds;
        try {
          final result = await engine.generateImage(
            const ImageGenerationRequest(
              prompt: 'a red fox in autumn leaves',
              width: 256,
              height: 256,
              steps: 1,
              guidanceScale: 1,
              seed: 42,
            ),
          );
          expect(result.images.single.pixels.toSet().length, greaterThan(64));
          print(
            'SDXS from Hugging Face: ${events.length} progress events, loaded in '
            '$loaded ms, image ${result.elapsed.inMilliseconds} ms',
          );
        } finally {
          await engine.dispose();
        }
        return events;
      }

      final first = await loadAndGenerate();
      expect(first.last.receivedBytes, total);
      expect(first.last.totalBytes, total);

      final cached = await loadAndGenerate();
      expect(cached.map((event) => event.receivedBytes), [total]);
      final entry = await downloads.get(_pinnedSdxs.cacheKey);
      expect(entry?.bytes, total);
    },
  );

  test('a split model loads from files in any order', () async {
    // A skip: argument would not apply: the scenario passes --run-skipped.
    if (splitModel == null) {
      markTestSkipped('Set LLAMADART_IMAGE_SPLIT_MODEL');
      return;
    }
    final [main, ...components] = [
      for (final path in splitModel.split(',')) ModelSource.path(path.trim()),
    ];
    final timer = Stopwatch()..start();
    final engine = await ImageGenerationEngine.load(
      ImageGenerationModel(
        main,
        components: [
          for (final source in components) ImageModelComponent.auto(source),
        ],
      ),
    );
    addTearDown(engine.dispose);
    final loaded = timer.elapsedMilliseconds;

    final result = await engine.generateImage(
      const ImageGenerationRequest(
        prompt: 'a red fox in autumn leaves',
        steps: 4,
        guidanceScale: 1,
        seed: 42,
      ),
    );

    print(
      'Split model ${(await engine.capabilities).modelVersion}: roles '
      '${engine.roles.map((role, source) => MapEntry(role.name, source.fileName))}, '
      'loaded in $loaded ms, image ${result.elapsed.inMilliseconds} ms',
    );
    expect(
      engine.roles.keys,
      contains(anyOf(ImageModelRole.diffusionModel, ImageModelRole.checkpoint)),
    );
    expect(engine.roles, hasLength(components.length + 1));
    expect(result.images.single.pixels.toSet().length, greaterThan(64));
    if (outputDir != null) {
      File(
        '$outputDir/split-model-seed42.png',
      ).writeAsBytesSync(result.images.single.toPng());
    }
  });

  test('dispose during a generation cancels it', () async {
    final engine = await ImageGenerationEngine.load(
      _sdxs(ModelSource.path(sdxsPath!)),
    );
    final result = engine.generateImage(
      const ImageGenerationRequest(prompt: 'a castle', steps: 20),
    );

    final cancelled = expectLater(result, throwsA(isA<LlamaStateException>()));

    await engine.dispose();

    await cancelled;
    expect((await engine.capabilities).isSupported, isFalse);
  }, skip: sdxsPath == null ? 'Set LLAMADART_SDXS_MODEL' : false);
}

final _pinnedSdxs = ModelSource.huggingFace(
  repoId: 'concedo/sdxs-512-tinySDdistilled-GGUF',
  revision: '3144d898d61492f8382ffcabec055733fc5b2a0e',
  filePath: 'sdxs-512-tinySDdistilled_Q8_0.gguf',
);

ImageGenerationModel _sdxs(ModelSource model) => ImageGenerationModel(model);

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
