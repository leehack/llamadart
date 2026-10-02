import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/stable_diffusion/stable_diffusion_runtime_status.dart';
import 'package:llamadart/src/core/image/image_generation_driver.dart';
import 'package:llamadart/src/core/image/image_generation_engine.dart';

import '../../../support/image_model_headers.dart';

const _model = '/models/sd-turbo.gguf';
const _taesd = '/models/taesd.safetensors';
const _flux = '/models/flux1-schnell.gguf';
const _ae = '/models/ae.safetensors';
const _clipL = '/models/clip_l.gguf';
const _t5xxl = '/models/t5xxl.gguf';
const _gib = 1 << 30;

ModelSource _local(String path) => ModelSource.path(path);

final _remote = ModelSource.parse('hf://owner/sdxs@0123abc/sdxs.gguf');
final _remoteTaesd = ModelSource.parse(
  'hf://owner/taesd@0123abc/taesd.safetensors',
);

/// A checkpoint (by default the local SD-Turbo fixture), plus [taesd].
ImageGenerationModel _sdxs([ModelSource? model, ModelSource? taesd]) =>
    ImageGenerationModel(
      model ?? _local(_model),
      components: [if (taesd != null) ImageModelComponent.auto(taesd)],
    );

/// FLUX.1-schnell's four local files, main file first, components in
/// [order] of `ae`, CLIP-L and T5-XXL.
ImageGenerationModel _fluxModel([List<int> order = const [0, 1, 2]]) {
  const parts = [_ae, _clipL, _t5xxl];
  return ImageGenerationModel(
    _local(_flux),
    components: [
      for (final index in order) ImageModelComponent.auto(_local(parts[index])),
    ],
  );
}

void main() {
  late _FakeDriver driver;
  final engines = <ImageGenerationEngine>[];

  late _FakeDownloads downloads;

  Future<ImageGenerationEngine> load(
    ImageGenerationModel model, {
    ImageModelParams params = const ImageModelParams(),
    ModelLoadOptions download = ModelLoadOptions.defaults,
    ModelDownloadProgressCallback? onProgress,
    ModelResolver? resolver,
  }) async {
    final engine = await ImageGenerationEngine.load(
      model,
      params: params,
      download: download,
      onProgress: onProgress,
      store: ModelFileStore(resolver: resolver, downloadManager: downloads),
    );
    engines.add(engine);
    return engine;
  }

  setUp(() {
    driver = _FakeDriver();
    downloads = _FakeDownloads(driver);
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
      final loading = load(_sdxs());
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
        load(_sdxs()),
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
        _sdxs(_local(_model), _local(_taesd)),
        params: const ImageModelParams(device: ComputeDevice.cpu, threads: 4),
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
      final engine = await load(_sdxs());

      expect(driver.started.single.backend, isNull);
      expect(engine.capabilities.backendName, 'MTL0');
    });

    test('assigns split files their roles from their headers, in any '
        'order', () async {
      for (final order in const [
        [0, 1, 2],
        [2, 0, 1],
        [1, 2, 0],
      ]) {
        final engine = await load(_fluxModel(order));
        await engine.dispose();

        expect(driver.started.last.files, {
          'diffusionModel': _flux,
          'vae': _ae,
          'clipL': _clipL,
          't5xxl': _t5xxl,
        }, reason: '$order');
        expect(
          engine.roles.map((role, source) => MapEntry(role, source.path)),
          {
            ImageModelRole.diffusionModel: _flux,
            ImageModelRole.vae: _ae,
            ImageModelRole.clipL: _clipL,
            ImageModelRole.t5xxl: _t5xxl,
          },
        );
      }
    });

    test('takes the role a component sets, and the main file role', () async {
      const ckpt = '/models/model.ckpt';
      driver
        ..sizes[ckpt] = _gib
        ..headers[ckpt] = ImageModelHeaders.pickle;

      await load(
        ImageGenerationModel(
          _local(_taesd),
          components: [
            ImageModelComponent(_local(ckpt), role: ImageModelRole.checkpoint),
          ],
        ),
      );
      expect(driver.started.last.files, {'model': ckpt, 'taesd': _taesd});

      await engines.removeLast().dispose();
      await load(
        ImageGenerationModel(_local(ckpt), role: ImageModelRole.checkpoint),
      );
      expect(driver.started.last.files, {'model': ckpt});
    });

    test('a file the header check cannot classify throws naming its '
        'position', () async {
      const ckpt = '/models/model.ckpt';
      driver
        ..sizes[ckpt] = _gib
        ..headers[ckpt] = ImageModelHeaders.pickle;

      await expectLater(
        load(_sdxs(_local(_model), _local(ckpt))),
        throwsA(
          isA<LlamaModelException>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('component 1'),
              contains('ImageModelComponent(source, role: ...)'),
              isNot(contains(ckpt)),
            ),
          ),
        ),
      );
      expect(driver.started, isEmpty);
    });

    group('automatic attention and VAE settings', () {
      Future<ImageGenerationSessionConfig> startedWith(
        String devices,
        ImageGenerationModel model, {
        ImageModelParams params = const ImageModelParams(),
      }) async {
        driver
          ..status = _available(devices)
          ..started.clear();
        await load(model, params: params);
        return driver.started.single;
      }

      final checkpoint = _sdxs();
      const metal = 'MTL0\tApple M4\nBLAS\tAccelerate\nCPU\tApple M4\n';
      const vulkan = 'Vulkan0\tNVIDIA L4\nCPU\tHost\n';
      const cpu = 'CPU\tCortex-A78\n';

      test('Metal uses flash attention and keeps the unfolded VAE', () async {
        final config = await startedWith(metal, checkpoint);

        expect(config.flashAttention, isTrue);
        expect(config.vaeDirectConvolution, isFalse);
      });

      test('Vulkan uses direct VAE convolutions and leaves flash attention '
          'off', () async {
        final config = await startedWith(vulkan, checkpoint);

        expect(config.flashAttention, isFalse);
        expect(config.vaeDirectConvolution, isTrue);
      });

      test('the CPU uses both', () async {
        final config = await startedWith(cpu, checkpoint);

        expect(config.flashAttention, isTrue);
        expect(config.vaeDirectConvolution, isTrue);
      });

      test('the device auto picks decides, so cpu on a Mac uses direct VAE '
          'convolutions', () async {
        final config = await startedWith(
          metal,
          checkpoint,
          params: const ImageModelParams(device: ComputeDevice.cpu),
        );

        expect(config.flashAttention, isTrue);
        expect(config.vaeDirectConvolution, isTrue);
      });

      test('a taesd file keeps the unfolded VAE on every device; a single '
          'checkpoint uses direct convolutions off Metal', () async {
        final withTaesd = _sdxs(_local(_model), _local(_taesd));
        for (final devices in [metal, vulkan, cpu]) {
          final config = await startedWith(devices, withTaesd);
          expect(config.vaeDirectConvolution, isFalse, reason: devices);
        }
        expect(
          (await startedWith(cpu, checkpoint)).vaeDirectConvolution,
          isTrue,
        );
        expect(
          (await startedWith(
            cpu,
            checkpoint,
            params: const ImageModelParams(vaeDirectConvolution: false),
          )).vaeDirectConvolution,
          isFalse,
        );
      });

      test('a checkpoint whose header shows an embedded tiny autoencoder '
          'keeps the unfolded VAE', () async {
        const sdxs = '/models/sdxs.gguf';
        driver
          ..sizes[sdxs] = 651 << 20
          ..headers[sdxs] = ImageModelHeaders.sdxsCheckpoint;

        for (final devices in [metal, vulkan, cpu]) {
          final config = await startedWith(
            devices,
            ImageGenerationModel(_local(sdxs)),
          );
          expect(config.vaeDirectConvolution, isFalse, reason: devices);
        }
      });

      test('explicit params override the automatic choice', () async {
        final onMetal = await startedWith(
          metal,
          checkpoint,
          params: const ImageModelParams(
            flashAttention: false,
            vaeDirectConvolution: true,
          ),
        );
        expect(onMetal.flashAttention, isFalse);
        expect(onMetal.vaeDirectConvolution, isTrue);

        final onVulkan = await startedWith(
          vulkan,
          _sdxs(),
          params: const ImageModelParams(
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
        _sdxs(),
        params: const ImageModelParams(device: ComputeDevice.gpu),
      );

      expect(driver.started.single.backend, 'gpu');
      expect(engine.capabilities.backendName, 'Vulkan0');
    });

    test('gpu without a GPU device throws LlamaUnsupportedException', () async {
      driver.status = _available('CPU\tCortex-A78\n');

      await expectLater(
        load(
          _sdxs(),
          params: const ImageModelParams(device: ComputeDevice.gpu),
        ),
        throwsA(
          isA<LlamaUnsupportedException>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('ComputeDevice.gpu needs a GPU'),
              contains('reports only CPU'),
              contains('llamadart_stable_diffusion_backends'),
            ),
          ),
        ),
      );
      expect(driver.started, isEmpty);

      final engine = await load(_sdxs());
      expect(engine.capabilities.backendName, 'CPU');
    });

    test('a missing file throws LlamaModelException naming its position, '
        'not its path', () async {
      driver.sizes.remove(_taesd);

      await expectLater(
        load(_sdxs(_local(_model), _local(_taesd))),
        throwsA(
          isA<LlamaModelException>().having(
            (error) => error.message,
            'message',
            allOf(contains('component 1'), isNot(contains(_taesd))),
          ),
        ),
      );
      await expectLater(
        load(_sdxs(_local('  '))),
        throwsA(isA<LlamaModelException>()),
      );
      expect(driver.started, isEmpty);
    });

    test('a set without diffusion weights is rejected', () async {
      await expectLater(
        load(
          ImageGenerationModel(
            _local(_ae),
            components: [ImageModelComponent.auto(_local(_clipL))],
          ),
        ),
        throwsA(
          isA<LlamaModelException>().having(
            (error) => error.message,
            'message',
            contains('None of the image model files holds diffusion weights'),
          ),
        ),
      );
      expect(driver.started, isEmpty);
    });

    test('ComputeDevice.npu is unsupported', () async {
      await expectLater(
        load(
          _sdxs(),
          params: const ImageModelParams(device: ComputeDevice.npu),
        ),
        throwsA(
          isA<LlamaUnsupportedException>().having(
            (error) => error.message,
            'message',
            contains('no NPU backend'),
          ),
        ),
      );
      expect(downloads.calls, isEmpty);
    });

    test('negative threads are rejected', () async {
      await expectLater(
        load(_sdxs(), params: const ImageModelParams(threads: -1)),
        throwsA(isA<LlamaImageGenerationException>()),
      );
    });

    test(
      'a load failure propagates and frees the one-operation slot',
      () async {
        driver.startError = LlamaModelException('not an image model');

        await expectLater(load(_sdxs()), throwsA(isA<LlamaModelException>()));

        driver.startError = null;
        await load(_sdxs());
      },
    );

    test('a cancel during the native load frees what it loaded and leaves '
        'nothing loaded', () async {
      final cancelToken = ModelDownloadCancelToken();
      final gate = driver.startGate = Completer<void>();

      final loading = load(
        _fluxModel(),
        download: ModelLoadOptions(cancelToken: cancelToken),
      );
      await pumpEventQueue();
      expect(driver.started, hasLength(1));
      cancelToken.cancel();
      gate.complete();

      await expectLater(
        loading,
        throwsA(
          isA<LlamaStateException>().having(
            (error) => error.message,
            'message',
            'Image model loading was cancelled.',
          ),
        ),
      );
      expect(driver.session.disposeCalls, 1);

      driver.startGate = null;
      final engine = await load(_sdxs());
      expect(engine.capabilities.isSupported, isTrue);
    });

    test('a cancel during header classification starts nothing', () async {
      final cancelToken = ModelDownloadCancelToken();
      final gate = driver.readGate = Completer<void>();

      final loading = load(
        _fluxModel(),
        download: ModelLoadOptions(cancelToken: cancelToken),
      );
      await pumpEventQueue();
      cancelToken.cancel();
      gate.complete();

      await expectLater(loading, throwsA(isA<LlamaStateException>()));
      expect(driver.started, isEmpty);
      expect(driver.session.disposeCalls, 0);
    });

    test('a runtime failure leaves nothing loaded, and the next load starts '
        'from scratch', () async {
      driver.startError = LlamaModelException('not an image model');

      await expectLater(
        load(_fluxModel()),
        throwsA(isA<LlamaModelException>()),
      );
      expect(driver.started, isEmpty);

      driver.startError = null;
      final engine = await load(_sdxs());
      expect(driver.started.single.files, {'model': _model});
      expect(engine.capabilities.isSupported, isTrue);
    });

    test('passes each role to the runtime under its runtime name', () async {
      const sd35 = '/models/sd35.gguf';
      const clipG = '/models/clip_g.gguf';
      const taesd3 = '/models/taesd3.safetensors';
      const zImage = '/models/z_image.gguf';
      const qwen = '/models/qwen3.gguf';
      driver
        ..sizes.addAll({
          sd35: _gib,
          clipG: _gib,
          taesd3: 1 << 20,
          zImage: _gib,
          qwen: _gib,
        })
        ..headers.addAll({
          sd35: ImageModelHeaders.sd35Diffusion,
          clipG: ImageModelHeaders.clipG,
          taesd3: ImageModelHeaders.taef1,
          zImage: ImageModelHeaders.zImageDiffusion,
          qwen: ImageModelHeaders.qwen3Llm,
        });
      ImageGenerationModel split(String main, List<String> components) =>
          ImageGenerationModel(
            _local(main),
            components: [
              for (final path in components)
                ImageModelComponent.auto(_local(path)),
            ],
          );

      for (final (model, files) in [
        (
          _sdxs(_local(_model), _local(_taesd)),
          {'model': _model, 'taesd': _taesd},
        ),
        (
          split(sd35, [clipG, _t5xxl, taesd3, _clipL]),
          {
            'diffusionModel': sd35,
            'taesd': taesd3,
            'clipL': _clipL,
            'clipG': clipG,
            't5xxl': _t5xxl,
          },
        ),
        (
          split(qwen, [_ae, zImage]),
          {'diffusionModel': zImage, 'vae': _ae, 'llm': qwen},
        ),
      ]) {
        final engine = await load(model);
        await engine.dispose();
        expect(driver.started.last.files, files);
      }
    });

    test('dispose is idempotent', () async {
      final engine = await load(_sdxs());

      final first = engine.dispose();
      final second = engine.dispose();
      expect(second, same(first));
      await first;
      await engine.dispose();

      expect(engine.isDisposed, isTrue);
      expect(driver.session.disposeCalls, 1);
      expect(engine.capabilities.isSupported, isFalse);
    });
  });

  group('model sources', () {
    test('resolves every file through the manager, then assigns roles to '
        'the local copies', () async {
      final flux = ModelSource.parse('hf://owner/flux@0123abc/flux.gguf');
      final ae = ModelSource.url(
        Uri.parse('https://example.com/ae.safetensors'),
      );
      final t5xxl = ModelSource.parse('hf://owner/t5@0123abc/t5xxl.gguf');
      downloads.remoteHeaders
        ..['flux.gguf'] = ImageModelHeaders.fluxDiffusion
        ..['ae.safetensors'] = ImageModelHeaders.fluxVae
        ..['t5xxl.gguf'] = ImageModelHeaders.t5xxl;

      final engine = await load(
        ImageGenerationModel(
          t5xxl,
          components: [
            ImageModelComponent.auto(_local(_clipL)),
            ImageModelComponent.auto(flux),
            ImageModelComponent.auto(ae),
          ],
        ),
      );

      expect(
        [for (final (source, _) in downloads.calls) source.canonicalKey],
        [
          for (final source in [t5xxl, _local(_clipL), flux, ae])
            source.canonicalKey,
        ],
      );
      expect(driver.started.single.files, {
        'diffusionModel': _FakeDownloads.cachePath(flux),
        'vae': _FakeDownloads.cachePath(ae),
        'clipL': _clipL,
        't5xxl': _FakeDownloads.cachePath(t5xxl),
      });
      expect(engine.roles[ImageModelRole.diffusionModel], flux);
      expect(
        downloads.calls.first.$1.resolvedUri.toString(),
        'https://huggingface.co/owner/t5/resolve/0123abc/t5xxl.gguf'
        '?download=true',
      );
    });

    test('a non-component file fails after its download, starts nothing, '
        'and keeps the download cached', () async {
      final lora = ModelSource.parse(
        'hf://owner/lora@0123abc/lora.safetensors',
      );
      downloads.remoteHeaders['lora.safetensors'] = ImageModelHeaders.lora;

      await expectLater(
        load(_sdxs(_local(_model), lora)),
        throwsA(
          isA<LlamaModelException>().having(
            (error) => error.message,
            'message',
            allOf(
              startsWith('Component 1 is a LoRA adapter'),
              isNot(contains('lora.safetensors')),
            ),
          ),
        ),
      );
      expect(driver.started, isEmpty);
      expect(downloads.cached, contains(lora.canonicalKey));
    });

    test('remote-only options reach only remote files', () async {
      const cacheDirectory = '/models/cache';

      await load(
        _sdxs(_remote, _local(_taesd)),
        download: ModelLoadOptions(
          bearerToken: 'hf_secret',
          cacheDirectory: cacheDirectory,
        ),
      );

      final [(remote, remoteOptions), (local, localOptions)] = downloads.calls;
      expect(remote.isRemote, isTrue);
      expect(remoteOptions.bearerToken, 'hf_secret');
      expect(remoteOptions.cacheDirectory, cacheDirectory);
      expect(local.isLocal, isTrue);
      expect(localOptions.bearerToken, isNull);
      expect(localOptions.cacheDirectory, isNull);
    });

    test('reports progress across files, counting cached ones as '
        'received', () async {
      downloads.remoteSizes
        ..['sdxs.gguf'] = 8192
        ..['taesd.safetensors'] = 1024;
      downloads.cached.add(_remote.canonicalKey);
      downloads.cached.remove(_remoteTaesd.canonicalKey);
      final events = <ModelDownloadProgress>[];

      await load(_sdxs(_remote, _remoteTaesd), onProgress: events.add);

      expect(downloads.downloaded, ['taesd.safetensors']);
      expect(events.map((e) => (e.receivedBytes, e.totalBytes)), [
        (8192, null),
        (8192 + 512, 8192 + 1024),
        (8192 + 1024, 8192 + 1024),
        (8192 + 1024, 8192 + 1024),
      ]);
    });

    test('local file sizes count toward the total from the start', () async {
      downloads.remoteSizes['late.gguf'] = 1024;
      downloads.remoteHeaders['late.gguf'] = ImageModelHeaders.taesd;
      final events = <ModelDownloadProgress>[];

      await load(
        _sdxs(
          _local(_model),
          ModelSource.url(Uri.parse('https://example.com/late.gguf')),
        ),
        onProgress: events.add,
      );

      expect(events.first.totalBytes, isNull);
      expect(events.first.receivedBytes, 651 << 20);
      expect(events.last.receivedBytes, (651 << 20) + 1024);
      expect(events.last.totalBytes, (651 << 20) + 1024);

      events.clear();
      await load(_sdxs(_local(_model), _local(_taesd)), onProgress: events.add);
      expect(events.map((e) => e.totalBytes), everyElement((660 << 20)));
    });

    test('a second load reuses the cache instead of downloading', () async {
      await load(_sdxs(_remote));
      await load(_sdxs(_remote));

      expect(downloads.downloaded, ['sdxs.gguf']);
      expect(downloads.calls, hasLength(2));
    });

    test('a cancelled load stops downloading, starts nothing and frees the '
        'slot', () async {
      final cancelToken = ModelDownloadCancelToken();
      final gate = downloads.gate = Completer<void>();

      final loading = load(
        _sdxs(_remote, _remoteTaesd),
        download: ModelLoadOptions(cancelToken: cancelToken),
      );
      await pumpEventQueue();
      cancelToken.cancel();
      gate.complete();

      await expectLater(loading, throwsA(isA<LlamaStateException>()));
      expect(downloads.calls, hasLength(1));
      expect(driver.started, isEmpty);

      downloads.gate = null;
      await load(_sdxs());
    });

    test('a cancel after the last file resolves stops before the runtime '
        'loads', () async {
      final cancelToken = ModelDownloadCancelToken();
      downloads.remoteSizes['sdxs.gguf'] = 4096;

      await expectLater(
        load(
          _sdxs(_remote),
          download: ModelLoadOptions(cancelToken: cancelToken),
          onProgress: (progress) {
            if (progress.receivedBytes == 4096) {
              cancelToken.cancel();
            }
          },
        ),
        throwsA(
          isA<LlamaStateException>().having(
            (error) => error.message,
            'message',
            contains('cancelled'),
          ),
        ),
      );
      expect(driver.started, isEmpty);
    });

    test('a download failure surfaces as the download manager threw '
        'it', () async {
      final failure = LlamaModelException('Failed to download sdxs.gguf.');
      downloads.error = failure;

      await expectLater(load(_sdxs(_remote)), throwsA(same(failure)));
      expect(driver.started, isEmpty);
    });

    test('a missing local file fails before anything downloads', () async {
      await expectLater(
        load(
          ImageGenerationModel(
            _remote,
            components: [
              ImageModelComponent.auto(_local(_clipL)),
              ImageModelComponent.auto(_local('/models/missing.gguf')),
            ],
          ),
        ),
        throwsA(
          isA<LlamaModelException>().having(
            (error) => error.message,
            'message',
            allOf(contains('component 2'), isNot(contains('missing.gguf'))),
          ),
        ),
      );
      expect(downloads.calls, isEmpty);
    });

    test('an unavailable runtime throws before anything downloads', () async {
      driver.status = StableDiffusionRuntimeStatus.unavailable(
        LlamaUnsupportedException('not published for android-x64'),
      );

      await expectLater(
        load(_sdxs(_remote)),
        throwsA(isA<LlamaUnsupportedException>()),
      );
      expect(downloads.calls, isEmpty);
    });

    test('a checksum in the load options is rejected before anything '
        'downloads', () async {
      await expectLater(
        load(_sdxs(_remote), download: ModelLoadOptions(sha256: 'a' * 64)),
        throwsA(
          isA<LlamaUnsupportedException>().having(
            (error) => error.message,
            'message',
            contains('ModelLoadOptions.sha256'),
          ),
        ),
      );
      expect(downloads.calls, isEmpty);
    });

    test('resolves through the given resolver, and keeps a signed URL out of '
        'its errors', () async {
      final signed = Uri.parse(
        'https://example.com/sdxs.gguf?X-Amz-Signature=supersecret',
      );

      await expectLater(
        load(
          _sdxs(_remote),
          resolver: _RemoteTargetResolver(signed, useBrowserCache: false),
          download: ModelLoadOptions(bearerToken: 'hf_secret'),
        ),
        throwsA(
          isA<LlamaUnsupportedException>().having(
            (error) => '${error.message} ${error.details}',
            'message',
            allOf(
              contains('image model'),
              isNot(contains('supersecret')),
              isNot(contains('hf_secret')),
            ),
          ),
        ),
      );

      await load(
        _sdxs(_remote),
        resolver: _RemoteTargetResolver(signed, useBrowserCache: true),
      );
      final (source, _) = downloads.calls.single;
      expect(source.resolvedUri, signed);
      expect(source.canonicalKey, _remote.canonicalKey);
    });

    test('the memory check counts downloaded files', () async {
      driver.budget = (bytes: _gib, source: 'test budget');
      downloads.remoteSizes['sdxs.gguf'] = 2 * _gib;

      await expectLater(
        load(_sdxs(_remote)),
        throwsA(
          isA<LlamaModelException>().having(
            (error) => error.message,
            'message',
            contains('2.00 GiB of weights'),
          ),
        ),
      );
      expect(downloads.downloaded, ['sdxs.gguf']);
      expect(driver.started, isEmpty);
    });
  });

  group('memory preflight', () {
    test('refuses a model whose estimate exceeds the budget', () async {
      driver.sizes[_model] = 2 * _gib;
      driver.budget = (
        bytes: 2 * _gib,
        source: 'MemAvailable in /proc/meminfo',
      );

      await expectLater(
        load(_sdxs()),
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
        load(_sdxs(_local(_model), _local(_taesd))),
        throwsA(isA<LlamaModelException>()),
      );

      driver.budget = (bytes: required, source: 'physical memory');
      await load(_sdxs(_local(_model), _local(_taesd)));
    });

    test('is skipped without a budget or when checkMemory is false', () async {
      driver.sizes[_model] = 64 * _gib;

      await load(_sdxs());

      driver.budget = (bytes: _gib, source: 'physical memory');
      await load(_sdxs(), params: const ImageModelParams(checkMemory: false));
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
          ComputeDevice.auto,
          ImageGenerationComputeDevice.metal,
        ),
        (
          'MTL0\tApple M4\nCPU\tApple M4\n',
          ComputeDevice.cpu,
          ImageGenerationComputeDevice.cpu,
        ),
        (
          'Vulkan0\tNVIDIA L4\nCPU\tHost\n',
          ComputeDevice.auto,
          ImageGenerationComputeDevice.otherGpu,
        ),
        (
          'CPU\tCortex-A78\n',
          ComputeDevice.auto,
          ImageGenerationComputeDevice.cpu,
        ),
      ]) {
        driver
          ..status = _available(devices)
          ..budgetDevices.clear();
        await load(_sdxs(), params: ImageModelParams(device: device));
        expect(driver.budgetDevices, [expected], reason: devices);
      }
    });
  });

  group('generate', () {
    test('rejects invalid requests before starting', () async {
      final engine = await load(_sdxs());

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

    test('fills unset size, steps and guidance with the neutral fallbacks, '
        'and leaves sampling to the runtime', () async {
      final engine = await load(_sdxs());

      await engine.generate(const ImageGenerationRequest(prompt: 'a')).done;

      final sent = driver.session.requests.last;
      expect((sent.width, sent.height), (512, 512));
      expect(sent.steps, 20);
      expect(sent.guidanceScale, 7);
      expect(sent.sampler, isNull);
      expect(sent.scheduler, isNull);
      expect(sent.flowShift, isNull);
    });

    test('sends every setting a request sets, each side of the size on its '
        'own', () async {
      final engine = await load(_fluxModel());

      await engine
          .generate(
            const ImageGenerationRequest(
              prompt: 'a',
              width: 1024,
              height: 768,
              steps: 4,
              guidanceScale: 1,
              sampler: ImageGenerationSampler.euler,
              scheduler: ImageGenerationScheduler.sgmUniform,
              flowShift: 3,
            ),
          )
          .done;
      var sent = driver.session.requests.last;
      expect((sent.width, sent.height, sent.steps), (1024, 768, 4));
      expect(sent.guidanceScale, 1);
      expect(sent.sampler, ImageGenerationSampler.euler);
      expect(sent.scheduler, ImageGenerationScheduler.sgmUniform);
      expect(sent.flowShift, 3);

      await engine
          .generate(const ImageGenerationRequest(prompt: 'a', width: 768))
          .done;
      sent = driver.session.requests.last;
      expect((sent.width, sent.height), (768, 512));
    });

    test('reports the seed it used', () async {
      final engine = await load(_sdxs());

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
      final engine = await load(_sdxs());

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
      final first = await load(_sdxs());
      final second = await load(_sdxs());
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
      await expectLater(load(_sdxs()), throwsA(isA<LlamaStateException>()));

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
      final engine = await load(_sdxs());
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
      final engine = await load(_sdxs());
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
      final engine = await load(_sdxs());
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
      final engine = await load(_sdxs());

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
      final engine = await load(_sdxs());
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
    test('runs one discarded single-step generation at the given size and '
        'guidance', () async {
      final engine = await load(_sdxs());

      await engine.warmUp(guidanceScale: 1);
      await engine.warmUp(width: 256, height: 384, guidanceScale: 1);

      expect(
        driver.session.requests.map(
          (r) => (r.width, r.height, r.steps, r.guidanceScale, r.count),
        ),
        [(512, 512, 1, 1.0, 1), (256, 384, 1, 1.0, 1)],
      );
    });

    test('falls back like a request, and a given side overrides it', () async {
      final engine = await load(_fluxModel());

      await engine.warmUp();
      await engine.warmUp(width: 1024, height: 1024);
      await engine.warmUp(height: 768);

      expect(
        driver.session.requests.map(
          (r) => (r.width, r.height, r.steps, r.guidanceScale),
        ),
        [(512, 512, 1, 7.0), (1024, 1024, 1, 7.0), (512, 768, 1, 7.0)],
      );
    });

    test('runs nothing on the CPU but still checks the size and the engine '
        'state', () async {
      driver.status = _available('CPU\tCortex-A78\n');
      final engine = await load(_sdxs());

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
      final engine = await load(_sdxs());

      for (final (width, height) in [(500, 512), (512, 56), (4096, 512)]) {
        await expectLater(
          engine.warmUp(width: width, height: height),
          throwsA(isA<LlamaImageGenerationException>()),
        );
      }
      expect(driver.session.requests, isEmpty);
    });

    test('holds the one-operation slot until it finishes', () async {
      final engine = await load(_sdxs());
      final gate = driver.session.gate = Completer<void>();

      final warmUp = engine.warmUp();

      expect(
        () => engine.generate(const ImageGenerationRequest(prompt: 'a')),
        throwsA(isA<LlamaStateException>()),
      );
      await expectLater(load(_sdxs()), throwsA(isA<LlamaStateException>()));
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
      final engine = await load(_sdxs());
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
      final engine = await load(_sdxs());
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
      final engine = await load(_sdxs());

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
  final Map<String, int> sizes = {
    _model: 651 << 20,
    _taesd: 9 << 20,
    _flux: 6 * _gib,
    _ae: 320 << 20,
    _clipL: 120 << 20,
    _t5xxl: 5 * _gib,
  };
  final Map<String, Uint8List> headers = {
    _model: ImageModelHeaders.sdTurboCheckpoint,
    _taesd: ImageModelHeaders.taesd,
    _flux: ImageModelHeaders.fluxDiffusion,
    _ae: ImageModelHeaders.fluxVae,
    _clipL: ImageModelHeaders.clipL,
    _t5xxl: ImageModelHeaders.t5xxl,
  };
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

  @override
  Future<Uint8List> readFileRange(String path, int offset, int length) async {
    await readGate?.future;
    final bytes = headers[path] ?? Uint8List(0);
    final start = offset.clamp(0, bytes.length);
    return Uint8List.sublistView(
      bytes,
      start,
      (offset + length).clamp(0, bytes.length),
    );
  }

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
    await startGate?.future;
    return session;
  }

  /// Holds header reads until completed.
  Completer<void>? readGate;

  /// Holds the native load, after it allocated the session, until completed.
  Completer<void>? startGate;
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

/// Passes local files through and "downloads" remote ones into a fake cache,
/// registering their sizes with the driver.
final class _FakeDownloads implements ModelDownloadManager {
  _FakeDownloads(this.driver);

  final _FakeDriver driver;
  final List<(ModelSource, ModelLoadOptions)> calls = [];
  final Set<String> cached = {};
  final List<String> downloaded = [];
  final Map<String, int> remoteSizes = {};

  /// Header of each downloaded file, by file name; `.gguf` files default to
  /// a checkpoint and `.safetensors` files to a TAESD.
  final Map<String, Uint8List> remoteHeaders = {};
  Object? error;
  Completer<void>? gate;

  static String cachePath(ModelSource source) =>
      '/cache/${source.cacheDirectoryName}/${source.fileName}';

  @override
  Future<ModelCacheEntry> ensureModel(
    ModelSource source, {
    ModelLoadOptions options = ModelLoadOptions.defaults,
    ModelDownloadProgressCallback? onProgress,
  }) async {
    calls.add((source, options));
    final path = source.isLocal ? source.path! : cachePath(source);
    if (!source.isLocal) {
      final failure = error;
      if (failure != null) {
        throw failure;
      }
      final size = remoteSizes[source.fileName] ?? 4096;
      if (cached.add(source.canonicalKey)) {
        onProgress?.call(
          ModelDownloadProgress(receivedBytes: size ~/ 2, totalBytes: size),
        );
        await gate?.future;
        if (options.cancelToken?.isCancelled ?? false) {
          throw LlamaStateException('Model download was cancelled.');
        }
        onProgress?.call(
          ModelDownloadProgress(receivedBytes: size, totalBytes: size),
        );
        downloaded.add(source.fileName);
      }
      driver.sizes[path] = size;
      driver.headers[path] =
          remoteHeaders[source.fileName] ??
          (source.fileName.endsWith('.gguf')
              ? ImageModelHeaders.sdTurboCheckpoint
              : ImageModelHeaders.taesd);
    }
    final now = DateTime.utc(2026);
    return ModelCacheEntry(
      sourceCanonicalKey: source.canonicalKey,
      cacheKey: source.cacheKey,
      fileName: source.fileName,
      filePath: path,
      createdAt: now,
      updatedAt: now,
      bytes: driver.sizes[path],
    );
  }

  @override
  Future<List<ModelCacheEntry>> list({String? cacheDirectory}) async => [];

  @override
  Future<ModelCacheEntry?> get(
    String cacheKey, {
    String? cacheDirectory,
  }) async => null;

  @override
  Future<void> remove(String cacheKey, {String? cacheDirectory}) async {}

  @override
  Future<void> clear({String? cacheDirectory}) async {}

  @override
  Future<List<ModelCacheEntry>> prune({
    Duration? maxAge,
    int? maxBytes,
    String? cacheDirectory,
  }) async => [];
}

final class _RemoteTargetResolver implements ModelResolver {
  _RemoteTargetResolver(this.url, {required this.useBrowserCache});

  final Uri url;
  final bool useBrowserCache;

  @override
  Future<ModelLoadTarget> resolve(
    ModelSource source,
    ModelResolveRequest request,
  ) async => RemoteModelUrl(url, useBrowserCache: useBrowserCache);
}
