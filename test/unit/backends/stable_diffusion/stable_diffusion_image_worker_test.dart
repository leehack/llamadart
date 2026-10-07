@TestOn('vm')
library;

import 'dart:async';

import 'package:test/test.dart';

import 'package:llamadart/src/backends/stable_diffusion/stable_diffusion_calls.dart';
import 'package:llamadart/src/backends/stable_diffusion/stable_diffusion_image_worker.dart';
import 'package:llamadart/src/backends/stable_diffusion/stable_diffusion_runtime_io.dart';
import 'package:llamadart/src/core/exceptions.dart';
import 'package:llamadart/src/core/image/generated_image.dart';
import 'package:llamadart/src/core/image/image_generation_driver.dart';
import 'package:llamadart/src/core/image/image_generation_events.dart';
import 'package:llamadart/src/core/image/image_generation_progress.dart';
import 'package:llamadart/src/core/image/image_generation_request.dart';
import 'package:llamadart/src/core/llama_logger.dart';
import 'package:llamadart/src/core/models/config/log_level.dart';

import '../../../support/fake_stable_diffusion_runtime.dart';

const _config = ImageGenerationSessionConfig(
  files: {'model': '/models/sdxs.gguf'},
  backend: null,
  threads: 0,
);

ImageGenerationSessionRequest _request({int steps = 2, int count = 1}) =>
    ImageGenerationSessionRequest(
      prompt: 'a red fox',
      negativePrompt: '',
      width: 8,
      height: 8,
      steps: steps,
      guidanceScale: 1,
      seed: 7,
      count: count,
    );

/// The reports stable-diffusion.cpp makes for [count] images of [steps]
/// steps, then [tiles] tiles of a tiled decode.
List<(int, int)> _upstreamReports({
  required int steps,
  required int count,
  int tiles = 0,
}) => [
  for (var image = 0; image < count; image++)
    for (var step = 0; step <= steps; step++) (step, steps),
  for (var tile = 1; tile <= tiles; tile++) (tile, tiles),
];

const _loadCalls = [
  'sd_ctx_params_init',
  'sd_dart_new_sd_ctx',
  'sd_ctx_supports_image_generation+held',
  'sd_get_model_version_name+held',
];

const _generateCalls = [
  'sd_img_gen_params_init+held',
  'sd_dart_generate_image+held',
  'free_sd_images+held',
];

// Real generation needs the opt-in runtime, which the root package does not
// bundle; example/basic_app/test/image_generation_e2e_test.dart covers it.
// The tests below run the worker's two isolates on a recording stand-in.
void main() {
  test(
    'a worker whose runtime is missing fails its start and exits',
    () async {
      await expectLater(
        StableDiffusionImageWorker.start(_config),
        throwsA(isA<LlamaUnsupportedException>()),
      );
    },
    skip: probeStableDiffusionRuntime().isAvailable
        ? 'the stable_diffusion runtime is bundled here'
        : false,
  );

  group('on a recording runtime', () {
    late FakeStableDiffusionRuntime runtime;
    late ManualProgressTimers timers;
    final workers = <StableDiffusionImageWorker>[];

    Future<StableDiffusionImageWorker> start() async {
      final worker = await StableDiffusionImageWorker.start(
        _config,
        resolveCalls: runtime.resolver,
        progressTimer: timers.start,
      );
      workers.add(worker);
      return worker;
    }

    /// A started worker, with the calls of its load forgotten.
    Future<StableDiffusionImageWorker> loaded() async {
      final worker = await start();
      await runtime.flush();
      runtime.clearCalls();
      return worker;
    }

    setUp(() {
      runtime = FakeStableDiffusionRuntime();
      timers = ManualProgressTimers();
    });

    tearDown(() async {
      for (final worker in workers) {
        await worker.dispose();
      }
      workers.clear();
      runtime.close();
    });

    test('a load enables the recorder before the worker creates its tracked '
        'context, and holds the context for its exit-free', () async {
      final worker = await start();
      await runtime.flush();

      expect(runtime.calls('caller'), ['sd_dart_progress_enable']);
      expect(runtime.calls('worker'), _loadCalls);
      expect(worker.modelVersion, 'SD 2.x');
    });

    test('a generation marks its start, reads the reports after the reply '
        'and stops its timer', () async {
      runtime.loadReports = 3;
      final worker = await loaded();
      final progress = <(int, int)>[];

      final images = await worker.generate(
        _request(),
        (step, steps) => progress.add((step, steps)),
      );
      await runtime.flush();

      expect(runtime.calls('caller'), [
        'sd_dart_progress_read:mark',
        'sd_dart_progress_read',
      ]);
      expect(runtime.calls('worker'), _generateCalls);
      expect(progress, [(0, 2), (1, 2), (2, 2)]);
      expect(timers.intervals, [const Duration(milliseconds: 50)]);
      expect(timers.active, 0);
      final GeneratedImage image = images!.single;
      expect((image.width, image.height, image.channels), (8, 8, 3));
      expect(image.pixels, List.filled(8 * 8 * 3, 1));
    });

    test('a poll during a generation delivers the reports so far, and the '
        'events of a batch of three match the unpolled stream', () async {
      final worker = await loaded();
      runtime.pauseAfter = 7;
      const steps = 4;
      const count = 3;
      final tracker = ImageGenerationProgressTracker(
        steps: steps,
        imageCount: count,
      );
      final events = <String>[];
      final generation = worker.generate(
        _request(steps: steps, count: count),
        (step, total) =>
            events.addAll(tracker.onNativeProgress(step, total).map(_describe)),
      );
      await runtime.pausedIn(generation);

      expect(events, isEmpty);
      timers.poll();
      expect(events, [
        'sampling 0/4 image 0/3',
        'sampling 1/4 image 0/3',
        'sampling 2/4 image 0/3',
        'sampling 3/4 image 0/3',
        'sampling 4/4 image 0/3',
        'sampling 0/4 image 1/3',
        'sampling 1/4 image 1/3',
      ]);
      runtime.resume();
      final images = await generation;
      await runtime.flush();

      final reference = ImageGenerationProgressTracker(
        steps: steps,
        imageCount: count,
      );
      expect(events, [
        for (final (step, total) in _upstreamReports(
          steps: steps,
          count: count,
        ))
          ...reference.onNativeProgress(step, total).map(_describe),
      ]);
      expect(events, hasLength(16));
      expect(events.last, 'decoding 0/3 image 2/3');
      expect(runtime.calls('caller'), [
        'sd_dart_progress_read:mark',
        'sd_dart_progress_read',
        'sd_dart_progress_read',
      ]);
      expect([for (final image in images!) image.pixels.first], [1, 2, 3]);
    });

    test('a second generation reads only its own reports', () async {
      final worker = await loaded();
      final first = <(int, int)>[];
      final second = <(int, int)>[];

      await worker.generate(_request(steps: 3), (a, b) => first.add((a, b)));
      await worker.generate(
        _request(steps: 1, count: 2),
        (a, b) => second.add((a, b)),
      );

      expect(first, _upstreamReports(steps: 3, count: 1));
      expect(second, _upstreamReports(steps: 1, count: 2));
    });

    test('reads until it holds the newest report when there are more than '
        'one read returns', () async {
      final worker = await loaded();
      runtime.decodeReports = 200;
      final progress = <(int, int)>[];

      await worker.generate(
        _request(steps: 4, count: 3),
        (step, steps) => progress.add((step, steps)),
      );
      await runtime.flush();

      expect(progress, _upstreamReports(steps: 4, count: 3, tiles: 200));
      // 215 reports, 64 a read.
      expect(runtime.calls('caller'), [
        'sd_dart_progress_read:mark',
        for (var read = 0; read < 4; read++) 'sd_dart_progress_read',
      ]);
    });

    test('one poll stops after 64 reads of a runtime that reports faster '
        'than it is read', () async {
      final worker = await loaded();
      runtime.pauseAfter = 0;
      var delivered = 0;
      final generation = worker.generate(_request(), (_, _) => delivered++);
      await runtime.pausedIn(generation);
      runtime.reportsPerRead = 100;

      timers.poll();
      await runtime.flush();

      expect(runtime.calls('caller'), [
        'sd_dart_progress_read:mark',
        for (var read = 0; read < 64; read++) 'sd_dart_progress_read',
      ]);
      expect(delivered, 64 * 64);
      runtime.reportsPerRead = 0;
      runtime.resume();
      await generation;
    });

    test('delivers the reports the runtime still has, in order, when it '
        'dropped older ones, and warns once', () async {
      runtime.close();
      runtime = FakeStableDiffusionRuntime(history: 8);
      final warnings = <String>[];
      final logger = LlamaLogger.instance;
      final level = logger.level;
      logger
        ..setLevel(LlamaLogLevel.warn)
        ..setHandler((record) => warnings.add(record.message));
      addTearDown(() {
        logger
          ..setLevel(level)
          ..setHandler(null);
      });
      final worker = await loaded();
      runtime.pauseAfter = 3;
      final progress = <(int, int)>[];
      final generation = worker.generate(
        _request(steps: 9, count: 2),
        (step, steps) => progress.add((step, steps)),
      );
      await runtime.pausedIn(generation);
      timers.poll();
      expect(progress, [(0, 9), (1, 9), (2, 9)]);

      runtime.resume();
      await generation;

      // 20 reports; the 17 after the poll leave the newest 8.
      final all = _upstreamReports(steps: 9, count: 2);
      expect(progress, [...all.take(3), ...all.skip(12)]);
      expect(warnings, hasLength(1));
      expect(warnings.single, contains('dropped 9 image-generation'));

      warnings.clear();
      progress.clear();
      runtime.pauseAfter = -1;
      await worker.generate(
        _request(steps: 2),
        (step, steps) => progress.add((step, steps)),
      );
      expect(progress, _upstreamReports(steps: 2, count: 1));
      expect(warnings, isEmpty);
    });

    test('the largest request cannot record more reports than the runtime '
        'keeps', () {
      expect(
        ImageGenerationRequest.maxCount * (ImageGenerationRequest.maxSteps + 1),
        lessThanOrEqualTo(StableDiffusionCalls.progressHistory),
      );
    });

    test('a cancel that the starting generation cleared is applied again by '
        'the next poll', () async {
      final worker = await loaded();
      runtime
        ..holdStart = true
        ..pauseAfter = 0;
      final progress = <(int, int)>[];
      final generation = worker.generate(
        _request(steps: 4),
        (step, steps) => progress.add((step, steps)),
      );
      worker.cancel();
      expect(runtime.cancelPending, isTrue);
      runtime.holdStart = false;
      await runtime.pausedIn(generation);
      expect(runtime.cancelPending, isFalse);

      timers.poll();
      expect(runtime.cancelPending, isTrue);
      runtime.resume();

      expect(await generation, isNull);
      await runtime.flush();
      expect(runtime.calls('caller'), [
        'sd_dart_progress_read:mark',
        'sd_dart_cancel_generation',
        'sd_dart_cancel_generation',
        'sd_dart_progress_read',
        'sd_dart_progress_read',
      ]);
      expect(runtime.calls('worker'), [
        'sd_img_gen_params_init+held',
        'sd_dart_generate_image+held',
      ]);
      expect(progress, [(0, 4)]);
    });

    test('a cancel during a generation stops it before the next step, and '
        'the next generation is not cancelled', () async {
      final worker = await loaded();
      runtime.pauseAfter = 2;
      final progress = <(int, int)>[];
      final generation = worker.generate(
        _request(steps: 4),
        (step, steps) => progress.add((step, steps)),
      );
      await runtime.pausedIn(generation);
      timers.poll();
      worker.cancel();
      runtime.resume();

      expect(await generation, isNull);
      await runtime.flush();
      expect(runtime.calls('caller'), [
        'sd_dart_progress_read:mark',
        'sd_dart_progress_read',
        'sd_dart_cancel_generation',
        'sd_dart_progress_read',
      ]);
      expect(progress, [(0, 4), (1, 4)]);

      runtime.clearCalls();
      runtime.pauseAfter = 1;
      final next = worker.generate(_request(), (_, _) {});
      await runtime.pausedIn(next);
      timers.poll();
      runtime.resume();
      expect(await next, hasLength(1));
      await runtime.flush();
      expect(runtime.calls('caller'), [
        'sd_dart_progress_read:mark',
        'sd_dart_progress_read',
        'sd_dart_progress_read',
      ]);
    });

    test('a cancel with no generation running is not applied to the next '
        'one', () async {
      final worker = await loaded();
      worker.cancel();
      runtime.pauseAfter = 0;
      final generation = worker.generate(_request(), (_, _) {});
      await runtime.pausedIn(generation);
      timers.poll();
      runtime.resume();

      expect(await generation, hasLength(1));
      await runtime.flush();
      expect(runtime.calls('caller'), [
        'sd_dart_cancel_generation',
        'sd_dart_progress_read:mark',
        'sd_dart_progress_read',
        'sd_dart_progress_read',
      ]);
    });

    test(
      'the default timer delivers progress while the generation runs',
      () async {
        final worker = await StableDiffusionImageWorker.start(
          _config,
          resolveCalls: runtime.resolver,
        );
        workers.add(worker);
        runtime.pauseAfter = 2;
        final progress = <(int, int)>[];
        final polled = Completer<void>();
        final generation = worker.generate(_request(steps: 4), (step, steps) {
          progress.add((step, steps));
          if (progress.length == 2) polled.complete();
        });
        await runtime.pausedIn(generation);

        await polled.future.timeout(const Duration(seconds: 10));
        expect(progress, [(0, 4), (1, 4)]);
        runtime.resume();
        await generation;
        expect(progress, _upstreamReports(steps: 4, count: 1));
      },
    );

    test('dispose frees the context through the exit-free after releasing '
        'its hold, and a later cancel calls nothing', () async {
      final worker = await loaded();

      await worker.dispose();
      worker.cancel();
      await runtime.flush();

      expect(runtime.calls('worker'), ['sd_dart_exit_free']);
      expect(runtime.calls('caller'), isEmpty);
    });

    test('a failed load creates nothing to free', () async {
      runtime.rejectLoad = true;

      await expectLater(start(), throwsA(isA<LlamaModelException>()));
      await runtime.flush();

      expect(runtime.calls('caller'), ['sd_dart_progress_enable']);
      expect(runtime.calls('worker'), [
        'sd_ctx_params_init',
        'sd_dart_new_sd_ctx',
      ]);
    });

    test('a model that cannot generate images is freed through the '
        'exit-free', () async {
      runtime.videoOnly = true;

      await expectLater(
        start(),
        throwsA(
          isA<LlamaModelException>().having(
            (error) => error.message,
            'message',
            contains('does not support image generation'),
          ),
        ),
      );
      await runtime.flush();

      expect(runtime.calls('worker'), [
        'sd_ctx_params_init',
        'sd_dart_new_sd_ctx',
        'sd_ctx_supports_image_generation+held',
        'sd_dart_exit_free',
      ]);
    });

    test('a runtime without the sd_dart_ functions is unsupported, and '
        'nothing is called on it', () async {
      await expectLater(
        StableDiffusionImageWorker.start(_config, resolveCalls: () => null),
        throwsA(
          isA<LlamaUnsupportedException>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('sd_dart_progress_read'),
              contains('sd_dart_new_sd_ctx'),
              contains('stable-diffusion-native v0.2.0-1 or later'),
            ),
          ),
        ),
      );

      runtime.missingInWorker = true;
      await expectLater(start(), throwsA(isA<LlamaUnsupportedException>()));
      await runtime.flush();
      expect(runtime.calls('caller'), ['sd_dart_progress_enable']);
      expect(runtime.calls('worker'), isEmpty);
    });

    test('a worker that dies in a generation fails it, stops its timer and '
        'stays safe to cancel and dispose', () async {
      final worker = await loaded();
      runtime.throwInGenerate = true;

      await expectLater(
        worker.generate(_request(), (_, _) {}),
        throwsA(isA<LlamaStateException>()),
      );
      expect(timers.active, 0);
      await expectLater(
        worker.generate(_request(), (_, _) {}),
        throwsA(isA<LlamaStateException>()),
      );
      worker.cancel();
      await worker.dispose();
      await runtime.flush();

      expect(runtime.calls('worker'), [
        'sd_img_gen_params_init+held',
        'sd_dart_generate_image+held',
      ]);
      expect(runtime.calls('caller'), [
        'sd_dart_progress_read:mark',
        'sd_dart_cancel_generation',
      ]);
    });
  });

  group('stableDiffusionModelLoadFailure', () {
    test('names a missing VAE when a diffusionModel has none', () {
      final error = stableDiffusionModelLoadFailure({
        'diffusionModel': '/m/sd3.5_medium-Q8_0.gguf',
        'clipL': '/m/clip_l.gguf',
        'clipG': '/m/clip_g.gguf',
        't5xxl': '/m/t5xxl.gguf',
      });

      expect(error.message, contains('need a vae or taesd file'));
      expect(error.message, contains('is an ImageModelRole.checkpoint'));
      expect(error.message, isNot(contains('text encoders')));
      expect(error.details, 'files: diffusionModel, clipL, clipG, t5xxl');
      expect('$error', isNot(contains('/m/')));
    });

    test('names missing text encoders when a diffusionModel has none', () {
      final error = stableDiffusionModelLoadFailure({
        'diffusionModel': '/m/z_image_turbo-Q4_K.gguf',
        'vae': '/m/ae.safetensors',
      });

      expect(error.message, contains('llm for Z-Image and Qwen-Image'));
      expect(error.message, isNot(contains('vae or taesd')));
      expect(error.details, 'files: diffusionModel, vae');
    });

    test('each text encoder, llm included, counts as one', () {
      for (final role in ['clipL', 'clipG', 't5xxl', 'llm']) {
        final error = stableDiffusionModelLoadFailure({
          'diffusionModel': '/m/diffusion.gguf',
          'vae': '/m/vae.safetensors',
          role: '/m/encoder.gguf',
        });

        expect(error.message, isNot(contains('text encoders')), reason: role);
        expect(error.message, contains('enough memory'), reason: role);
      }
    });

    test('a taesd file stands in for the VAE', () {
      final error = stableDiffusionModelLoadFailure({
        'diffusionModel': '/m/flux1-schnell-Q4_0.gguf',
        'taesd': '/m/taef1.safetensors',
        'clipL': '/m/clip_l.gguf',
        't5xxl': '/m/t5xxl.gguf',
      });

      expect(error.message, isNot(contains('vae or taesd')));
      expect(error.message, contains('enough memory'));
    });

    test('a single-file checkpoint gets the general advice', () {
      final error = stableDiffusionModelLoadFailure({
        'model': '/m/sd_turbo.gguf',
      });

      expect(
        error.message,
        contains('ImageModelRole.checkpoint for a single file'),
      );
      expect(error.message, contains('enough memory'));
      expect(error.message, contains('does not report its reason'));
      expect(error.details, 'files: checkpoint');
    });
  });
}

String _describe(ImageGenerationProgressEvent event) =>
    '${event.phase.name} ${event.step}/${event.steps} '
    'image ${event.imageIndex}/${event.imageCount}';
