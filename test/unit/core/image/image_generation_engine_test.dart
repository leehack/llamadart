import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/stable_diffusion/stable_diffusion_runtime_status.dart';
import 'package:llamadart/src/core/image/image_generation_driver.dart';
import 'package:llamadart/src/core/image/image_generation_engine.dart';

const _model = '/models/sdxs.gguf';
const _taesd = '/models/taesd.safetensors';
const _gib = 1 << 30;

void main() {
  late _FakeDriver driver;
  final engines = <ImageGenerationEngine>[];

  Future<ImageGenerationEngine> load(
    ImageGenerationModel model, {
    ImageGenerationOptions options = const ImageGenerationOptions(),
  }) async {
    final engine = await ImageGenerationEngine.load(model, options: options);
    engines.add(engine);
    return engine;
  }

  setUp(() {
    driver = _FakeDriver();
    debugImageGenerationDriverOverride = driver;
  });

  tearDown(() async {
    for (final engine in engines) {
      await engine.dispose();
    }
    engines.clear();
    debugImageGenerationDriverOverride = null;
  });

  group('runtimeCapabilities', () {
    test('reports the devices and the device auto would pick', () {
      final capabilities = ImageGenerationEngine.runtimeCapabilities();

      expect(capabilities.isSupported, isTrue);
      expect(capabilities.deviceNames, ['MTL0', 'BLAS', 'CPU']);
      expect(capabilities.backendName, 'MTL0');
      expect(capabilities.runtimeVersion, 'master-929');
      expect(capabilities.modelVersion, isNull);
      expect(capabilities.maxConcurrentTasks, 1);
    });

    test('reports why the runtime is unavailable', () {
      driver.status = StableDiffusionRuntimeStatus.unavailable(
        LlamaUnsupportedException('stable_diffusion runtime is not bundled'),
      );

      final capabilities = ImageGenerationEngine.runtimeCapabilities();

      expect(capabilities.isSupported, isFalse);
      expect(capabilities.unsupportedReason, contains('not bundled'));
      expect(capabilities.deviceNames, isEmpty);
    });
  });

  group('load', () {
    test('throws the probe reason and loads nothing when the runtime is '
        'unavailable', () async {
      driver.status = StableDiffusionRuntimeStatus.unavailable(
        LlamaUnsupportedException('not published for android-x64'),
      );

      await expectLater(
        load(ImageGenerationModel.sdxs(_model)),
        throwsA(
          isA<LlamaUnsupportedException>().having(
            (error) => error.message,
            'message',
            'not published for android-x64',
          ),
        ),
      );
      expect(driver.started, isEmpty);
    });

    test('passes every file and the device choice to the runtime', () async {
      final engine = await load(
        ImageGenerationModel.sdTurbo(_model, taesdPath: _taesd),
        options: const ImageGenerationOptions(
          device: ImageGenerationDevice.cpu,
          threads: 4,
        ),
      );

      final config = driver.started.single;
      expect(config.files, {'model': _model, 'taesd': _taesd});
      expect(config.backend, 'cpu');
      expect(config.threads, 4);
      expect(engine.capabilities.backendName, 'CPU');
      expect(engine.capabilities.modelVersion, 'SD 2.x');
      expect(engine.capabilities.deviceNames, ['MTL0', 'BLAS', 'CPU']);
      expect(engine.capabilities.supportsCancellation, isTrue);
    });

    test('auto leaves the device to the runtime and reports its GPU', () async {
      final engine = await load(ImageGenerationModel.sdxs(_model));

      expect(driver.started.single.backend, isNull);
      expect(engine.capabilities.backendName, 'MTL0');
    });

    test('gpu selects the first GPU the runtime reports', () async {
      driver.status = _available('Vulkan0\tAMD Radeon\nCPU\tHost\n');

      final engine = await load(
        ImageGenerationModel.sdxs(_model),
        options: const ImageGenerationOptions(
          device: ImageGenerationDevice.gpu,
        ),
      );

      expect(driver.started.single.backend, 'gpu');
      expect(engine.capabilities.backendName, 'Vulkan0');
    });

    test('gpu without a GPU device throws LlamaUnsupportedException', () async {
      driver.status = _available('CPU\tCortex-A78\n');

      await expectLater(
        load(
          ImageGenerationModel.sdxs(_model),
          options: const ImageGenerationOptions(
            device: ImageGenerationDevice.gpu,
          ),
        ),
        throwsA(
          isA<LlamaUnsupportedException>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('ImageGenerationDevice.gpu needs a GPU'),
              contains('reports only CPU'),
              contains('llamadart_stable_diffusion_backends'),
            ),
          ),
        ),
      );
      expect(driver.started, isEmpty);

      final engine = await load(ImageGenerationModel.sdxs(_model));
      expect(engine.capabilities.backendName, 'CPU');
    });

    test('a missing file throws LlamaModelException naming its role', () async {
      driver.sizes.remove(_taesd);

      await expectLater(
        load(ImageGenerationModel.sdTurbo(_model, taesdPath: _taesd)),
        throwsA(
          isA<LlamaModelException>().having(
            (error) => error.message,
            'message',
            allOf(contains('taesd'), contains(_taesd)),
          ),
        ),
      );
      await expectLater(
        load(ImageGenerationModel.sdxs('  ')),
        throwsA(isA<LlamaModelException>()),
      );
      expect(driver.started, isEmpty);
    });

    test('a file set without model or diffusionModel is rejected', () async {
      await expectLater(
        load(
          ImageGenerationModel.custom(
            const ImageGenerationModelFiles(vae: '/models/vae.safetensors'),
          ),
        ),
        throwsA(
          isA<LlamaModelException>().having(
            (error) => error.message,
            'message',
            contains('model or diffusionModel'),
          ),
        ),
      );
    });

    test('negative threads are rejected', () async {
      await expectLater(
        load(
          ImageGenerationModel.sdxs(_model),
          options: const ImageGenerationOptions(threads: -1),
        ),
        throwsA(isA<LlamaImageGenerationException>()),
      );
    });

    test(
      'a load failure propagates and frees the one-operation slot',
      () async {
        driver.startError = LlamaModelException('not an image model');

        await expectLater(
          load(ImageGenerationModel.sdxs(_model)),
          throwsA(isA<LlamaModelException>()),
        );

        driver.startError = null;
        await load(ImageGenerationModel.sdxs(_model));
      },
    );
  });

  group('memory preflight', () {
    test('refuses a model whose estimate exceeds the budget', () async {
      driver.sizes[_model] = 2 * _gib;
      driver.budget = (
        bytes: 2 * _gib,
        source: 'MemAvailable in /proc/meminfo',
      );

      await expectLater(
        load(ImageGenerationModel.sdxs(_model)),
        throwsA(
          isA<LlamaModelException>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('about 2.75 GiB'),
              contains('2.00 GiB of weights'),
              contains('only 2.00 GiB is available'),
              contains('MemAvailable in /proc/meminfo'),
              contains('checkMemory'),
            ),
          ),
        ),
      );
      expect(driver.started, isEmpty);
    });

    test('counts every file toward the estimate', () async {
      driver.sizes[_model] = _gib;
      driver.sizes[_taesd] = _gib;
      final required = estimateImageGenerationMemoryBytes(2 * _gib);
      driver.budget = (bytes: required - 1, source: 'physical memory');

      await expectLater(
        load(ImageGenerationModel.sdTurbo(_model, taesdPath: _taesd)),
        throwsA(isA<LlamaModelException>()),
      );

      driver.budget = (bytes: required, source: 'physical memory');
      await load(ImageGenerationModel.sdTurbo(_model, taesdPath: _taesd));
    });

    test('is skipped without a budget or when checkMemory is false', () async {
      driver.sizes[_model] = 64 * _gib;

      await load(ImageGenerationModel.sdxs(_model));

      driver.budget = (bytes: _gib, source: 'physical memory');
      await load(
        ImageGenerationModel.sdxs(_model),
        options: const ImageGenerationOptions(checkMemory: false),
      );
      expect(driver.started, hasLength(2));
    });

    test('the estimate adds a quarter and 256 MiB to the weights', () {
      expect(estimateImageGenerationMemoryBytes(0), 256 << 20);
      expect(
        estimateImageGenerationMemoryBytes(4 * _gib),
        5 * _gib + (256 << 20),
      );
    });
  });

  group('generate', () {
    test('rejects invalid requests before starting', () async {
      final engine = await load(ImageGenerationModel.sdxs(_model));

      for (final request in [
        const ImageGenerationRequest(prompt: ' '),
        const ImageGenerationRequest(prompt: 'a', width: 500),
        const ImageGenerationRequest(prompt: 'a', height: 56),
        const ImageGenerationRequest(prompt: 'a', width: 2056),
        const ImageGenerationRequest(prompt: 'a', steps: 0),
        const ImageGenerationRequest(prompt: 'a', steps: 151),
        const ImageGenerationRequest(prompt: 'a', guidanceScale: -1),
        const ImageGenerationRequest(prompt: 'a', guidanceScale: double.nan),
        const ImageGenerationRequest(prompt: 'a', seed: -1),
        const ImageGenerationRequest(prompt: 'a', count: 0),
        const ImageGenerationRequest(prompt: 'a', count: 17),
      ]) {
        expect(
          () => engine.generate(request),
          throwsA(isA<LlamaImageGenerationException>()),
        );
      }
      expect(driver.session.requests, isEmpty);

      await engine.generate(const ImageGenerationRequest(prompt: 'a')).done;
    });

    test('rejects invalid custom model defaults before starting', () async {
      for (final defaults in const [
        ImageGenerationDefaults(steps: 0),
        ImageGenerationDefaults(steps: -3),
        ImageGenerationDefaults(steps: 1000),
        ImageGenerationDefaults(guidanceScale: double.nan),
        ImageGenerationDefaults(guidanceScale: -1),
      ]) {
        final engine = await load(
          ImageGenerationModel.custom(
            const ImageGenerationModelFiles(model: _model),
            defaults: defaults,
          ),
        );
        expect(
          () => engine.generate(const ImageGenerationRequest(prompt: 'a')),
          throwsA(isA<LlamaImageGenerationException>()),
          reason: 'steps ${defaults.steps}, guidance ${defaults.guidanceScale}',
        );
        expect(driver.session.requests, isEmpty);

        // A valid request value still overrides an invalid default, and the
        // rejection above released the operation lock.
        await engine
            .generate(
              const ImageGenerationRequest(
                prompt: 'a',
                steps: 2,
                guidanceScale: 1,
              ),
            )
            .done;
        expect(driver.session.requests.single.steps, 2);
        await engine.dispose();
        driver = _FakeDriver();
        debugImageGenerationDriverOverride = driver;
      }
    });

    test('fills unset steps and guidance from the model defaults', () async {
      final sdxs = await load(ImageGenerationModel.sdxs(_model));
      await sdxs.generate(const ImageGenerationRequest(prompt: 'a')).done;
      expect(driver.session.requests.last.steps, 1);
      expect(driver.session.requests.last.guidanceScale, 1);

      await sdxs
          .generate(
            const ImageGenerationRequest(
              prompt: 'a',
              steps: 3,
              guidanceScale: 2.5,
            ),
          )
          .done;
      expect(driver.session.requests.last.steps, 3);
      expect(driver.session.requests.last.guidanceScale, 2.5);

      final custom = await load(
        ImageGenerationModel.custom(
          const ImageGenerationModelFiles(model: _model),
        ),
      );
      await custom.generate(const ImageGenerationRequest(prompt: 'a')).done;
      expect(driver.session.requests.last.steps, 20);
      expect(driver.session.requests.last.guidanceScale, 7);
    });

    test('reports the seed it used', () async {
      final engine = await load(ImageGenerationModel.sdxs(_model));

      final fixed = await engine.generateImage(
        const ImageGenerationRequest(prompt: 'a', seed: 42),
      );
      expect(fixed.seed, 42);
      expect(driver.session.requests.last.seed, 42);

      final random = await engine.generateImage(
        const ImageGenerationRequest(prompt: 'a'),
      );
      expect(random.seed, driver.session.requests.last.seed);
      expect(random.seed, greaterThanOrEqualTo(0));
    });

    test('emits phases in order and one final event', () async {
      final engine = await load(ImageGenerationModel.sdxs(_model));

      final task = engine.generate(
        const ImageGenerationRequest(
          prompt: 'a lighthouse',
          width: 256,
          height: 256,
          steps: 2,
          count: 2,
        ),
      );
      final events = await task.events.toList();

      final progress = events
          .whereType<ImageGenerationProgressEvent>()
          .map((e) => '${e.phase.name} ${e.step}/${e.steps} #${e.imageIndex}')
          .toList();
      expect(progress, [
        'encodingPrompt 0/2 #0',
        'sampling 0/2 #0',
        'sampling 1/2 #0',
        'sampling 2/2 #0',
        'sampling 0/2 #1',
        'sampling 1/2 #1',
        'sampling 2/2 #1',
        'decoding 0/2 #1',
      ]);
      final result = (events.last as ImageGenerationFinalEvent).result;
      expect(result.images, hasLength(2));
      expect(result.images.first.width, 256);
      final completion = await task.done;
      expect(completion.state, ImageGenerationCompletionState.completed);
      expect(completion.result, same(result));
      expect(driver.session.requests.single.prompt, 'a lighthouse');
    });

    test('allows one generation at a time across engines and loads', () async {
      final first = await load(ImageGenerationModel.sdxs(_model));
      final second = await load(ImageGenerationModel.sdxs(_model));
      final gate = driver.session.gate = Completer<void>();

      final running = first.generate(const ImageGenerationRequest(prompt: 'a'));

      for (final start in <void Function()>[
        () => first.generate(const ImageGenerationRequest(prompt: 'b')),
        () => second.generate(const ImageGenerationRequest(prompt: 'c')),
      ]) {
        expect(
          start,
          throwsA(
            isA<LlamaStateException>().having(
              (error) => error.message,
              'message',
              contains('process-wide callback'),
            ),
          ),
        );
      }
      await expectLater(
        load(ImageGenerationModel.sdxs(_model)),
        throwsA(isA<LlamaStateException>()),
      );

      gate.complete();
      expect(
        (await running.done).state,
        ImageGenerationCompletionState.completed,
      );
      driver.session.gate = null;

      final next = await second.generateImage(
        const ImageGenerationRequest(prompt: 'd'),
      );
      expect(next.images, isNotEmpty);
    });

    test('a cancel before the runtime starts is re-applied on its first '
        'progress callback', () async {
      final engine = await load(ImageGenerationModel.sdxs(_model));
      final gate = driver.session.gate = Completer<void>();

      final task = engine.generate(
        const ImageGenerationRequest(prompt: 'a', steps: 4),
      );
      final events = task.events.toList();
      task.cancel();
      expect(driver.session.cancelCalls, 1);

      // The runtime clears the flag when generation starts.
      gate.complete();
      final completion = await task.done;

      expect(completion.state, ImageGenerationCompletionState.cancelled);
      expect(driver.session.cancelCalls, 2);
      expect(driver.session.stepsRun, 0);
      expect(await events, everyElement(isA<ImageGenerationProgressEvent>()));
    });

    test('cancel during sampling stops the runtime', () async {
      final engine = await load(ImageGenerationModel.sdxs(_model));
      final task = engine.generate(
        const ImageGenerationRequest(prompt: 'a', steps: 8),
      );

      final events = <ImageGenerationEvent>[];
      await for (final event in task.events) {
        events.add(event);
        if (event case ImageGenerationProgressEvent(
          phase: ImageGenerationPhase.sampling,
          step: 1,
        )) {
          task.cancel();
          task.cancel();
        }
      }

      expect((await task.done).state, ImageGenerationCompletionState.cancelled);
      expect(driver.session.stepsRun, lessThan(8));
      expect(events.whereType<ImageGenerationFinalEvent>(), isEmpty);
      expect(task.isCancellationRequested, isTrue);
    });

    test('a runtime failure fails the task with LlamaInferenceException and '
        'the engine runs the next request', () async {
      final engine = await load(ImageGenerationModel.sdxs(_model));
      driver.session.failNext = true;

      final task = engine.generate(const ImageGenerationRequest(prompt: 'a'));
      await expectLater(
        task.events.drain<void>(),
        throwsA(isA<LlamaInferenceException>()),
      );
      final completion = await task.done;
      expect(completion.state, ImageGenerationCompletionState.failed);
      expect(
        completion.error,
        isA<LlamaInferenceException>().having(
          (error) => error.message,
          'message',
          contains('The engine can run the next request'),
        ),
      );

      final next = await engine.generateImage(
        const ImageGenerationRequest(prompt: 'b'),
      );
      expect(next.images, hasLength(1));
    });

    test('maps unexpected errors to LlamaInferenceException and keeps typed '
        'ones', () async {
      final engine = await load(ImageGenerationModel.sdxs(_model));

      driver.session.error = StateError('worker bug');
      await expectLater(
        engine.generateImage(const ImageGenerationRequest(prompt: 'a')),
        throwsA(
          isA<LlamaInferenceException>().having(
            (error) => error.details,
            'details',
            isA<StateError>(),
          ),
        ),
      );

      driver.session.error = LlamaStateException('worker stopped');
      await expectLater(
        engine.generateImage(const ImageGenerationRequest(prompt: 'a')),
        throwsA(isA<LlamaStateException>()),
      );
    });

    test('dispose cancels a running generation before freeing the '
        'model', () async {
      final engine = await load(ImageGenerationModel.sdxs(_model));
      final gate = driver.session.gate = Completer<void>();
      final result = engine.generateImage(
        const ImageGenerationRequest(prompt: 'a', steps: 4),
      );
      final resultExpectation = expectLater(
        result,
        throwsA(
          isA<LlamaStateException>().having(
            (error) => error.message,
            'message',
            contains('disposed'),
          ),
        ),
      );

      final disposal = engine.dispose();
      expect(engine.isDisposed, isTrue);
      expect(driver.session.disposed, isFalse);
      gate.complete();
      await disposal;
      await resultExpectation;

      expect(driver.session.disposedAfterGenerate, isTrue);
      expect(driver.session.stepsRun, 0);
      await engine.dispose();
      expect(driver.session.disposeCalls, 1);
      expect(engine.capabilities.isSupported, isFalse);
      expect(
        () => engine.generate(const ImageGenerationRequest(prompt: 'a')),
        throwsA(isA<LlamaStateException>()),
      );
    });
  });
}

StableDiffusionRuntimeStatus _available(String devices) =>
    StableDiffusionRuntimeStatus.available(
      version: 'master-929',
      commit: '3f8527a',
      devices: parseStableDiffusionDeviceList(devices),
    );

final class _FakeDriver implements ImageGenerationDriver {
  StableDiffusionRuntimeStatus status = _available(
    'MTL0\tApple M4\nBLAS\tAccelerate\nCPU\tApple M4\n',
  );
  final Map<String, int> sizes = {_model: 651 << 20, _taesd: 9 << 20};
  ImageGenerationMemoryBudget? budget;
  Object? startError;
  final List<ImageGenerationSessionConfig> started = [];
  _FakeSession session = _FakeSession();

  @override
  StableDiffusionRuntimeStatus probe() => status;

  @override
  int? fileSize(String path) => sizes[path];

  @override
  ImageGenerationMemoryBudget? memoryBudget() => budget;

  @override
  Future<ImageGenerationSession> start(
    ImageGenerationSessionConfig config,
  ) async {
    final error = startError;
    if (error != null) {
      throw error;
    }
    started.add(config);
    return session;
  }
}

/// Behaves like stable-diffusion.cpp: a generation clears the cancel flag
/// when it starts, reports `0/steps` then each step, and checks the flag
/// before every step and before decoding.
final class _FakeSession implements ImageGenerationSession {
  final List<ImageGenerationSessionRequest> requests = [];
  Completer<void>? gate;
  bool failNext = false;
  Object? error;
  bool _cancelFlag = false;
  bool _generating = false;
  int cancelCalls = 0;
  int stepsRun = 0;
  int disposeCalls = 0;
  bool disposed = false;
  bool disposedAfterGenerate = false;

  @override
  String get modelVersion => 'SD 2.x';

  @override
  Future<List<GeneratedImage>?> generate(
    ImageGenerationSessionRequest request,
    void Function(int step, int steps) onProgress,
  ) async {
    requests.add(request);
    _generating = true;
    stepsRun = 0;
    try {
      await gate?.future;
      _cancelFlag = false;
      final failure = error;
      if (failure != null) {
        error = null;
        throw failure;
      }
      for (var image = 0; image < request.count; image++) {
        onProgress(0, request.steps);
        for (var step = 1; step <= request.steps; step++) {
          await Future<void>.delayed(Duration.zero);
          if (_cancelFlag) {
            return null;
          }
          stepsRun++;
          onProgress(step, request.steps);
        }
      }
      await Future<void>.delayed(Duration.zero);
      if (_cancelFlag || failNext) {
        failNext = false;
        return null;
      }
      return [
        for (var i = 0; i < request.count; i++)
          GeneratedImage(
            width: request.width,
            height: request.height,
            channels: 3,
            pixels: Uint8List(request.width * request.height * 3),
          ),
      ];
    } finally {
      _generating = false;
    }
  }

  @override
  void cancel() {
    cancelCalls++;
    _cancelFlag = true;
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
    disposed = true;
    disposedAfterGenerate = !_generating;
  }
}
