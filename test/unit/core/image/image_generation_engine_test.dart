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

  group('checkRuntime', () {
    void expectSameCapabilities(
      ImageGenerationCapabilities actual,
      ImageGenerationCapabilities expected,
    ) {
      expect(actual.isSupported, expected.isSupported);
      expect(actual.unsupportedReason, expected.unsupportedReason);
      expect(actual.backendName, expected.backendName);
      expect(actual.deviceNames, expected.deviceNames);
      expect(actual.runtimeVersion, expected.runtimeVersion);
      expect(actual.modelVersion, expected.modelVersion);
      expect(actual.supportsCancellation, expected.supportsCancellation);
      expect(actual.maxConcurrentTasks, expected.maxConcurrentTasks);
    }

    test('reports what runtimeCapabilities reports, probing in the '
        'background', () async {
      final capabilities = await ImageGenerationEngine.checkRuntime();

      expect(driver.backgroundProbes, 1);
      expect(driver.syncProbes, 0);
      expect(capabilities.backendName, 'MTL0');
      expectSameCapabilities(
        capabilities,
        ImageGenerationEngine.runtimeCapabilities(),
      );
    });

    test('reports why the runtime is unavailable, like '
        'runtimeCapabilities', () async {
      driver.status = StableDiffusionRuntimeStatus.unavailable(
        LlamaUnsupportedException('stable_diffusion runtime is not bundled'),
      );

      final capabilities = await ImageGenerationEngine.checkRuntime();

      expect(capabilities.isSupported, isFalse);
      expect(capabilities.unsupportedReason, contains('not bundled'));
      expectSameCapabilities(
        capabilities,
        ImageGenerationEngine.runtimeCapabilities(),
      );
    });

    test('checks started while a probe runs share it, and a later check '
        'probes again', () async {
      final gate = driver.probeGate = Completer<void>();

      final first = ImageGenerationEngine.checkRuntime();
      final second = ImageGenerationEngine.checkRuntime();
      await pumpEventQueue();
      expect(driver.backgroundProbes, 1);
      gate.complete();
      expect((await first).backendName, 'MTL0');
      expect((await second).backendName, 'MTL0');

      driver.status = _available('CPU\tHost\n');
      expect((await ImageGenerationEngine.checkRuntime()).backendName, 'CPU');
      expect(driver.backgroundProbes, 2);
    });

    test('a failed probe fails every check that shared it, and the next '
        'check probes again', () async {
      final gate = driver.probeGate = Completer<void>();
      driver.probeError = StateError('probe isolate failed');

      final first = ImageGenerationEngine.checkRuntime();
      final second = ImageGenerationEngine.checkRuntime();
      gate.complete();
      await expectLater(first, throwsA(same(driver.probeError)));
      await expectLater(second, throwsA(same(driver.probeError)));
      expect(driver.backgroundProbes, 1);

      driver
        ..probeGate = null
        ..probeError = null;
      expect((await ImageGenerationEngine.checkRuntime()).isSupported, isTrue);
      expect(driver.backgroundProbes, 2);
    });
  });

  group('load', () {
    test('probes the runtime in the background and shares a running '
        'checkRuntime probe', () async {
      final gate = driver.probeGate = Completer<void>();

      final check = ImageGenerationEngine.checkRuntime();
      final loading = load(ImageGenerationModel.sdxs(_model));
      await pumpEventQueue();
      expect(driver.started, isEmpty);
      gate.complete();
      await check;
      final engine = await loading;

      expect(driver.backgroundProbes, 1);
      expect(driver.syncProbes, 0);
      expect(engine.capabilities.deviceNames, ['MTL0', 'BLAS', 'CPU']);
    });

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

    test('passes the llm text encoder to the runtime', () async {
      const llm = '/models/qwen3-4b.gguf';
      driver.sizes[llm] = _gib;

      await load(
        ImageGenerationModel.custom(
          const ImageGenerationModelFiles(
            diffusionModel: _model,
            vae: _taesd,
            llm: llm,
          ),
        ),
      );

      expect(driver.started.single.files, {
        'diffusionModel': _model,
        'vae': _taesd,
        'llm': llm,
      });
    });

    test('a missing llm file throws LlamaModelException naming its role', () {
      expect(
        load(
          ImageGenerationModel.custom(
            const ImageGenerationModelFiles(
              diffusionModel: _model,
              llm: '/models/missing.gguf',
            ),
          ),
        ),
        throwsA(
          isA<LlamaModelException>().having(
            (error) => error.message,
            'message',
            allOf(contains('llm'), contains('/models/missing.gguf')),
          ),
        ),
      );
    });

    group('automatic attention and VAE settings', () {
      Future<ImageGenerationSessionConfig> startedWith(
        String devices,
        ImageGenerationModel model, {
        ImageGenerationOptions options = const ImageGenerationOptions(),
      }) async {
        driver
          ..status = _available(devices)
          ..started.clear();
        await load(model, options: options);
        return driver.started.single;
      }

      final sdTurbo = ImageGenerationModel.sdTurbo(_model);
      const metal = 'MTL0\tApple M4\nBLAS\tAccelerate\nCPU\tApple M4\n';
      const vulkan = 'Vulkan0\tNVIDIA L4\nCPU\tHost\n';
      const cpu = 'CPU\tCortex-A78\n';

      test('Metal uses flash attention and keeps the unfolded VAE', () async {
        final config = await startedWith(metal, sdTurbo);

        expect(config.flashAttention, isTrue);
        expect(config.vaeDirectConvolution, isFalse);
      });

      test('Vulkan uses direct VAE convolutions and leaves flash attention '
          'off', () async {
        final config = await startedWith(vulkan, sdTurbo);

        expect(config.flashAttention, isFalse);
        expect(config.vaeDirectConvolution, isTrue);
      });

      test('the CPU uses both', () async {
        final config = await startedWith(cpu, sdTurbo);

        expect(config.flashAttention, isTrue);
        expect(config.vaeDirectConvolution, isTrue);
      });

      test('the device auto picks decides, so cpu on a Mac uses direct VAE '
          'convolutions', () async {
        final config = await startedWith(
          metal,
          sdTurbo,
          options: const ImageGenerationOptions(
            device: ImageGenerationDevice.cpu,
          ),
        );

        expect(config.flashAttention, isTrue);
        expect(config.vaeDirectConvolution, isTrue);
      });

      test('a tiny autoencoder keeps the unfolded VAE', () async {
        for (final model in [
          ImageGenerationModel.sdTurbo(_model, taesdPath: _taesd),
          ImageGenerationModel.sdxs(_model),
        ]) {
          final config = await startedWith(vulkan, model);
          expect(
            config.vaeDirectConvolution,
            isFalse,
            reason: model.family.name,
          );
        }
      });

      test('explicit options override the automatic choice', () async {
        final onMetal = await startedWith(
          metal,
          sdTurbo,
          options: const ImageGenerationOptions(
            flashAttention: false,
            vaeDirectConvolution: true,
          ),
        );
        expect(onMetal.flashAttention, isFalse);
        expect(onMetal.vaeDirectConvolution, isTrue);

        final onVulkan = await startedWith(
          vulkan,
          ImageGenerationModel.sdxs(_model),
          options: const ImageGenerationOptions(
            flashAttention: true,
            vaeDirectConvolution: true,
          ),
        );
        expect(onVulkan.flashAttention, isTrue);
        expect(onVulkan.vaeDirectConvolution, isTrue);
      });
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
              contains('about 3.00 GiB'),
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

    test('the estimate adds a quarter and 512 MiB to the weights', () {
      expect(estimateImageGenerationMemoryBytes(0), 512 << 20);
      expect(
        estimateImageGenerationMemoryBytes(4 * _gib),
        5 * _gib + (512 << 20),
      );
    });

    test('asks for the budget of the device the model loads on', () async {
      for (final (devices, device, expected) in [
        (
          'MTL0\tApple M4\nCPU\tApple M4\n',
          ImageGenerationDevice.auto,
          ImageGenerationComputeDevice.metal,
        ),
        (
          'MTL0\tApple M4\nCPU\tApple M4\n',
          ImageGenerationDevice.cpu,
          ImageGenerationComputeDevice.cpu,
        ),
        (
          'Vulkan0\tNVIDIA L4\nCPU\tHost\n',
          ImageGenerationDevice.auto,
          ImageGenerationComputeDevice.otherGpu,
        ),
        (
          'CPU\tCortex-A78\n',
          ImageGenerationDevice.auto,
          ImageGenerationComputeDevice.cpu,
        ),
      ]) {
        driver
          ..status = _available(devices)
          ..budgetDevices.clear();
        await load(
          ImageGenerationModel.sdxs(_model),
          options: ImageGenerationOptions(device: device),
        );
        expect(driver.budgetDevices, [expected], reason: devices);
      }
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

    test('fills an unset size from the model defaults, and a request '
        'overrides each side', () async {
      final presets = <ImageGenerationModel>[
        ImageGenerationModel.sdxs(_model),
        ImageGenerationModel.sdTurbo(_model, taesdPath: _taesd),
        ImageGenerationModel.sdxlLightning(_model, taesdPath: _taesd),
        ImageGenerationModel.flux1Schnell(
          diffusionModelPath: _model,
          clipLPath: _taesd,
          t5xxlPath: _taesd,
          taesdPath: _taesd,
        ),
        ImageGenerationModel.sd35LargeTurbo(
          diffusionModelPath: _model,
          clipLPath: _taesd,
          clipGPath: _taesd,
          t5xxlPath: _taesd,
          taesdPath: _taesd,
        ),
        ImageGenerationModel.zImageTurbo(
          diffusionModelPath: _model,
          llmPath: _taesd,
          vaePath: _taesd,
        ),
        ImageGenerationModel.custom(
          const ImageGenerationModelFiles(model: _model),
        ),
        ImageGenerationModel.custom(
          const ImageGenerationModelFiles(model: _model),
          defaults: const ImageGenerationDefaults(width: 1024, height: 768),
        ),
      ];
      final sizes = <(ImageGenerationModelFamily, int, int)>[];
      for (final model in presets) {
        final engine = await load(model);
        await engine.generate(const ImageGenerationRequest(prompt: 'a')).done;
        final sent = driver.session.requests.last;
        sizes.add((model.family, sent.width, sent.height));
        await engine.dispose();
      }
      expect(sizes, [
        (ImageGenerationModelFamily.sdxs, 512, 512),
        (ImageGenerationModelFamily.sdTurbo, 512, 512),
        (ImageGenerationModelFamily.sdxlLightning, 1024, 1024),
        (ImageGenerationModelFamily.flux1Schnell, 1024, 1024),
        (ImageGenerationModelFamily.sd35LargeTurbo, 1024, 1024),
        (ImageGenerationModelFamily.zImageTurbo, 1024, 1024),
        (ImageGenerationModelFamily.custom, 512, 512),
        (ImageGenerationModelFamily.custom, 1024, 768),
      ]);

      final lightning = await load(
        ImageGenerationModel.sdxlLightning(_model, taesdPath: _taesd),
      );
      for (final request in const [
        ImageGenerationRequest(prompt: 'a', width: 512, height: 512),
        ImageGenerationRequest(prompt: 'a', width: 768),
        ImageGenerationRequest(prompt: 'a', height: 640),
      ]) {
        await lightning.generate(request).done;
      }
      expect(
        driver.session.requests.reversed
            .take(3)
            .toList()
            .reversed
            .map((r) => (r.width, r.height)),
        [(512, 512), (768, 1024), (1024, 640)],
      );
    });

    test('rejects an invalid size from the model defaults', () async {
      for (final (defaults, field) in const [
        (ImageGenerationDefaults(width: 500), 'width'),
        (ImageGenerationDefaults(height: 4096), 'height'),
      ]) {
        final engine = await load(
          ImageGenerationModel.custom(
            const ImageGenerationModelFiles(model: _model),
            defaults: defaults,
          ),
        );
        expect(
          () => engine.generate(const ImageGenerationRequest(prompt: 'a')),
          throwsA(
            isA<LlamaImageGenerationException>().having(
              (error) => error.message,
              'message',
              startsWith(field),
            ),
          ),
        );
        // A valid request size still overrides an invalid default.
        await engine
            .generate(
              const ImageGenerationRequest(
                prompt: 'a',
                width: 256,
                height: 256,
              ),
            )
            .done;
        expect(driver.session.requests.last.width, 256);
        await engine.dispose();
      }
    });

    test('fills unset sampler, scheduler and flow shift from the model '
        'defaults, and a request overrides them', () async {
      final engine = await load(
        ImageGenerationModel.custom(
          const ImageGenerationModelFiles(model: _model),
          defaults: const ImageGenerationDefaults(
            steps: 4,
            guidanceScale: 1,
            sampler: ImageGenerationSampler.euler,
            scheduler: ImageGenerationScheduler.sgmUniform,
            flowShift: 3,
          ),
        ),
      );

      await engine.generate(const ImageGenerationRequest(prompt: 'a')).done;
      var sent = driver.session.requests.last;
      expect(sent.sampler, ImageGenerationSampler.euler);
      expect(sent.scheduler, ImageGenerationScheduler.sgmUniform);
      expect(sent.flowShift, 3);

      await engine
          .generate(
            const ImageGenerationRequest(
              prompt: 'a',
              sampler: ImageGenerationSampler.dpmpp2m,
              scheduler: ImageGenerationScheduler.karras,
              flowShift: 1.5,
            ),
          )
          .done;
      sent = driver.session.requests.last;
      expect(sent.sampler, ImageGenerationSampler.dpmpp2m);
      expect(sent.scheduler, ImageGenerationScheduler.karras);
      expect(sent.flowShift, 1.5);

      final sdxs = await load(ImageGenerationModel.sdxs(_model));
      await sdxs.generate(const ImageGenerationRequest(prompt: 'a')).done;
      sent = driver.session.requests.last;
      expect(sent.sampler, isNull);
      expect(sent.scheduler, isNull);
      expect(sent.flowShift, isNull);
    });

    test('rejects an invalid flow shift from the model defaults', () async {
      final engine = await load(
        ImageGenerationModel.custom(
          const ImageGenerationModelFiles(model: _model),
          defaults: const ImageGenerationDefaults(flowShift: 0),
        ),
      );

      expect(
        () => engine.generate(const ImageGenerationRequest(prompt: 'a')),
        throwsA(
          isA<LlamaImageGenerationException>().having(
            (error) => error.message,
            'message',
            contains('flowShift'),
          ),
        ),
      );
      expect(driver.session.requests, isEmpty);
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

  group('warmUp', () {
    test('runs one discarded single-step generation at the given size with '
        'the model guidance', () async {
      final sdxs = await load(ImageGenerationModel.sdxs(_model));
      await sdxs.warmUp();
      await sdxs.warmUp(width: 256, height: 384);

      expect(
        driver.session.requests.map(
          (r) => (r.width, r.height, r.steps, r.guidanceScale, r.count),
        ),
        [(512, 512, 1, 1.0, 1), (256, 384, 1, 1.0, 1)],
      );

      final custom = await load(
        ImageGenerationModel.custom(
          const ImageGenerationModelFiles(model: _model),
        ),
      );
      await custom.warmUp();
      expect(driver.session.requests.last.steps, 1);
      expect(driver.session.requests.last.guidanceScale, 7);
    });

    test('defaults to the model size, and a given side overrides it', () async {
      final lightning = await load(
        ImageGenerationModel.sdxlLightning(_model, taesdPath: _taesd),
      );
      await lightning.warmUp();
      await lightning.warmUp(width: 512, height: 512);
      await lightning.warmUp(height: 768);

      expect(driver.session.requests.map((r) => (r.width, r.height, r.steps)), [
        (1024, 1024, 1),
        (512, 512, 1),
        (1024, 768, 1),
      ]);
    });

    test('runs nothing on the CPU but still checks the size and the engine '
        'state', () async {
      driver.status = _available('CPU\tCortex-A78\n');
      final engine = await load(ImageGenerationModel.sdxs(_model));

      await engine.warmUp();
      expect(driver.session.requests, isEmpty);

      await expectLater(
        engine.warmUp(width: 500),
        throwsA(isA<LlamaImageGenerationException>()),
      );

      final gate = driver.session.gate = Completer<void>();
      final running = engine.generate(
        const ImageGenerationRequest(prompt: 'a'),
      );
      await expectLater(engine.warmUp(), throwsA(isA<LlamaStateException>()));
      gate.complete();
      await running.done;

      await engine.dispose();
      await expectLater(engine.warmUp(), throwsA(isA<LlamaStateException>()));
    });

    test('rejects an invalid size before running anything', () async {
      final engine = await load(ImageGenerationModel.sdxs(_model));

      for (final (width, height) in [(500, 512), (512, 56), (4096, 512)]) {
        await expectLater(
          engine.warmUp(width: width, height: height),
          throwsA(isA<LlamaImageGenerationException>()),
        );
      }
      expect(driver.session.requests, isEmpty);
    });

    test('holds the one-operation slot until it finishes', () async {
      final engine = await load(ImageGenerationModel.sdxs(_model));
      final gate = driver.session.gate = Completer<void>();

      final warmUp = engine.warmUp();

      expect(
        () => engine.generate(const ImageGenerationRequest(prompt: 'a')),
        throwsA(isA<LlamaStateException>()),
      );
      await expectLater(
        load(ImageGenerationModel.sdxs(_model)),
        throwsA(isA<LlamaStateException>()),
      );
      await expectLater(engine.warmUp(), throwsA(isA<LlamaStateException>()));

      gate.complete();
      await warmUp;
      driver.session.gate = null;

      final result = await engine.generateImage(
        const ImageGenerationRequest(prompt: 'b'),
      );
      expect(result.images, hasLength(1));
      expect(driver.session.requests, hasLength(2));
    });

    test('throws LlamaStateException while a generation runs', () async {
      final engine = await load(ImageGenerationModel.sdxs(_model));
      final gate = driver.session.gate = Completer<void>();
      final running = engine.generate(
        const ImageGenerationRequest(prompt: 'a'),
      );

      await expectLater(engine.warmUp(), throwsA(isA<LlamaStateException>()));

      gate.complete();
      expect(
        (await running.done).state,
        ImageGenerationCompletionState.completed,
      );
      expect(driver.session.requests, hasLength(1));
    });

    test('dispose cancels a running warm-up, which completes normally, and '
        'later warm-ups throw', () async {
      final engine = await load(ImageGenerationModel.sdxs(_model));
      final gate = driver.session.gate = Completer<void>();

      final warmUp = engine.warmUp();
      final disposal = engine.dispose();
      gate.complete();
      await disposal;
      await warmUp;

      expect(driver.session.stepsRun, 0);
      expect(driver.session.disposedAfterGenerate, isTrue);
      await expectLater(
        engine.warmUp(),
        throwsA(
          isA<LlamaStateException>().having(
            (error) => error.message,
            'message',
            contains('disposed'),
          ),
        ),
      );
    });

    test('throws a runtime failure and leaves the engine usable', () async {
      final engine = await load(ImageGenerationModel.sdxs(_model));

      driver.session.failNext = true;
      await expectLater(
        engine.warmUp(),
        throwsA(isA<LlamaInferenceException>()),
      );

      driver.session.error = StateError('worker bug');
      await expectLater(
        engine.warmUp(),
        throwsA(
          isA<LlamaInferenceException>().having(
            (error) => error.details,
            'details',
            isA<StateError>(),
          ),
        ),
      );

      await engine.warmUp();
      final next = await engine.generateImage(
        const ImageGenerationRequest(prompt: 'b'),
      );
      expect(next.images, hasLength(1));
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
  Completer<void>? probeGate;
  Object? probeError;
  int syncProbes = 0;
  int backgroundProbes = 0;

  @override
  StableDiffusionRuntimeStatus probe() {
    syncProbes++;
    return status;
  }

  @override
  Future<StableDiffusionRuntimeStatus> probeInBackground() async {
    backgroundProbes++;
    await probeGate?.future;
    final error = probeError;
    if (error != null) {
      throw error;
    }
    return status;
  }

  @override
  int? fileSize(String path) => sizes[path];

  final List<ImageGenerationComputeDevice> budgetDevices = [];

  @override
  ImageGenerationMemoryBudget? memoryBudget(
    ImageGenerationComputeDevice device,
  ) {
    budgetDevices.add(device);
    return budget;
  }

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
