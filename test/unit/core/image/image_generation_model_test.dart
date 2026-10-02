import 'package:test/test.dart';

import 'package:llamadart/src/core/exceptions.dart';
import 'package:llamadart/src/core/image/image_generation_model.dart';
import 'package:llamadart/src/core/models/model_source.dart';

Map<String, String> _keys(ImageGenerationModel model) => {
  for (final MapEntry(key: role, value: source) in model.files.sources.entries)
    role: source.canonicalKey,
};

Map<String, String> _pinned(Map<String, ImageGenerationPresetFile> files) => {
  for (final MapEntry(key: role, value: file) in files.entries)
    role: file.source.canonicalKey,
};

void main() {
  group('presets', () {
    test('default to their pinned files and keep their sampling '
        'defaults', () {
      final sdxs = ImageGenerationModel.sdxsPreset();
      expect(sdxs.family, ImageGenerationModelFamily.sdxs);
      expect(_keys(sdxs), _pinned({'model': ImageGenerationPresetFile.sdxs}));
      expect((sdxs.defaults.steps, sdxs.defaults.guidanceScale), (1, 1.0));
      expect((sdxs.defaults.width, sdxs.defaults.height), (512, 512));

      final sdTurbo = ImageGenerationModel.sdTurboPreset();
      expect(sdTurbo.family, ImageGenerationModelFamily.sdTurbo);
      expect(
        _keys(sdTurbo),
        _pinned({'model': ImageGenerationPresetFile.sdTurbo}),
      );
      expect(
        (sdTurbo.defaults.steps, sdTurbo.defaults.guidanceScale),
        (1, 1.0),
      );

      final lightning = ImageGenerationModel.sdxlLightningPreset();
      expect(
        _keys(lightning),
        _pinned({'model': ImageGenerationPresetFile.sdxlLightning}),
      );
      expect(lightning.defaults.steps, 4);
      expect(lightning.defaults.width, 1024);
      expect(lightning.defaults.sampler, ImageGenerationSampler.euler);
      expect(lightning.defaults.scheduler, ImageGenerationScheduler.sgmUniform);

      final flux = ImageGenerationModel.flux1SchnellPreset();
      expect(flux.family, ImageGenerationModelFamily.flux1Schnell);
      expect(
        _keys(flux),
        _pinned({
          'diffusionModel': ImageGenerationPresetFile.flux1Schnell,
          'vae': ImageGenerationPresetFile.fluxVae,
          'clipL': ImageGenerationPresetFile.clipL,
          't5xxl': ImageGenerationPresetFile.t5xxl,
        }),
      );
      expect((flux.defaults.steps, flux.defaults.width), (4, 1024));

      final sd35 = ImageGenerationModel.sd35LargeTurboPreset();
      expect(sd35.family, ImageGenerationModelFamily.sd35LargeTurbo);
      expect(
        _keys(sd35),
        _pinned({
          'diffusionModel': ImageGenerationPresetFile.sd35LargeTurbo,
          'taesd': ImageGenerationPresetFile.taesd3,
          'clipL': ImageGenerationPresetFile.clipL,
          'clipG': ImageGenerationPresetFile.clipG,
          't5xxl': ImageGenerationPresetFile.t5xxl,
        }),
      );
      expect((sd35.defaults.steps, sd35.defaults.width), (4, 1024));

      final zImage = ImageGenerationModel.zImageTurboPreset();
      expect(zImage.family, ImageGenerationModelFamily.zImageTurbo);
      expect(
        _keys(zImage),
        _pinned({
          'diffusionModel': ImageGenerationPresetFile.zImageTurbo,
          'vae': ImageGenerationPresetFile.fluxVae,
          'llm': ImageGenerationPresetFile.zImageTurboLlm,
        }),
      );
      expect((zImage.defaults.steps, zImage.defaults.width), (8, 1024));
    });

    test('replace each file they are given', () {
      final local = ModelSource.path('/m/sdxs.gguf');
      expect(ImageGenerationModel.sdxsPreset(model: local).files.sources, {
        'model': local,
      });

      final taesd = ImageGenerationPresetFile.taesd.source;
      expect(
        _keys(ImageGenerationModel.sdTurboPreset(taesd: taesd)),
        _pinned({
          'model': ImageGenerationPresetFile.sdTurbo,
          'taesd': ImageGenerationPresetFile.taesd,
        }),
      );

      final llm = ModelSource.parse('hf://owner/repo@main/qwen3.gguf');
      final zImage = ImageGenerationModel.zImageTurboPreset(llm: llm);
      expect(zImage.files.sources['llm'], llm);
      expect(
        zImage.files.sources['vae']!.canonicalKey,
        ImageGenerationPresetFile.fluxVae.source.canonicalKey,
      );
    });

    test('flux1Schnell and sd35LargeTurbo decode with exactly the decoders '
        'given', () {
      final taef1 = ImageGenerationPresetFile.taef1.source;
      final vae = ModelSource.path('/m/sd35-vae.safetensors');

      expect(
        ImageGenerationModel.flux1SchnellPreset(
          taesd: taef1,
        ).files.sources.keys,
        ['diffusionModel', 'taesd', 'clipL', 't5xxl'],
      );
      expect(
        ImageGenerationModel.sd35LargeTurboPreset(vae: vae).files.sources,
        allOf(containsPair('vae', vae), isNot(contains('taesd'))),
      );
      expect(
        ImageGenerationModel.sd35LargeTurboPreset(
          vae: vae,
          taesd: taef1,
        ).files.sources.keys,
        containsAll(['vae', 'taesd']),
      );
    });
  });

  group('ImageGenerationModelFiles', () {
    test('fromSources keeps every role in order, with local paths in the '
        'deprecated fields', () {
      final remote = ModelSource.parse('hf://owner/repo@main/unet.gguf');
      final files = ImageGenerationModelFiles.fromSources(
        llm: ModelSource.path('/m/qwen3.gguf'),
        diffusionModel: remote,
        vae: ModelSource.path('/m/vae.safetensors'),
      );

      expect(files.sources.keys, ['diffusionModel', 'vae', 'llm']);
      expect(files.sources['diffusionModel'], remote);
      expect(files.diffusionModel, isNull);
      expect(files.vae, '/m/vae.safetensors');
      expect(files.paths, {
        'vae': '/m/vae.safetensors',
        'llm': '/m/qwen3.gguf',
      });
    });

    test('a path file set reports its paths as local sources, and rejects a '
        'blank path naming its role', () {
      const files = ImageGenerationModelFiles(
        model: '/m/sd15.safetensors',
        taesd: '/m/taesd.safetensors',
      );
      expect(files.sources.map((role, source) => MapEntry(role, source.path)), {
        'model': '/m/sd15.safetensors',
        'taesd': '/m/taesd.safetensors',
      });
      expect(files.sources.values.every((source) => source.isLocal), isTrue);

      expect(
        () => const ImageGenerationModelFiles(model: '/m/a', vae: ' ').sources,
        throwsA(
          isA<LlamaModelException>().having(
            (error) => error.message,
            'message',
            contains('vae'),
          ),
        ),
      );
    });
  });

  group('ImageGenerationPresetFile', () {
    test('each file is a Hugging Face source pinned to a commit, with its '
        'size and checksum', () {
      for (final file in ImageGenerationPresetFile.values) {
        final source = file.source;
        expect(source.kind, ModelSourceKind.huggingFace, reason: file.name);
        expect(source.repoId, file.repoId, reason: file.name);
        expect(file.revision, matches(RegExp(r'^[0-9a-f]{40}$')));
        expect(file.sha256, matches(RegExp(r'^[0-9a-f]{64}$')));
        expect(file.sizeBytes, greaterThan(1000000), reason: file.name);
        expect(
          source.resolvedUri.toString(),
          'https://huggingface.co/${file.repoId}/resolve/${file.revision}/'
          '${file.filePath}?download=true',
        );
      }
    });

    test('of finds the pinned file of a source and nothing else', () {
      expect(
        ImageGenerationPresetFile.of(ImageGenerationPresetFile.taef1.source),
        ImageGenerationPresetFile.taef1,
      );
      expect(
        ImageGenerationPresetFile.of(
          ModelSource.huggingFace(
            repoId: 'madebyollin/taef1',
            filePath: 'diffusion_pytorch_model.safetensors',
          ),
        ),
        isNull,
      );
      expect(
        ImageGenerationPresetFile.of(ModelSource.path('/m/taef1.safetensors')),
        isNull,
      );
    });
  });

  group('deprecated path factories', () {
    test('sdxs samples one step at guidance 1', () {
      final model = ImageGenerationModel.sdxs('/m/sdxs.gguf');

      expect(model.family, ImageGenerationModelFamily.sdxs);
      expect(model.files.paths, {'model': '/m/sdxs.gguf'});
      expect(model.defaults.steps, 1);
      expect(model.defaults.guidanceScale, 1);
    });

    test('sdTurbo samples one step at guidance 1 and adds TAESD', () {
      final withTaesd = ImageGenerationModel.sdTurbo(
        '/m/turbo.gguf',
        taesdPath: '/m/taesd.safetensors',
      );
      final withoutTaesd = ImageGenerationModel.sdTurbo('/m/turbo.gguf');

      expect(withTaesd.family, ImageGenerationModelFamily.sdTurbo);
      expect(withTaesd.files.paths, {
        'model': '/m/turbo.gguf',
        'taesd': '/m/taesd.safetensors',
      });
      expect(withoutTaesd.files.paths, {'model': '/m/turbo.gguf'});
      expect(withTaesd.defaults.steps, 1);
      expect(withTaesd.defaults.guidanceScale, 1);
    });

    test('sdxlLightning samples 4 Euler steps on the sgm_uniform schedule', () {
      final model = ImageGenerationModel.sdxlLightning(
        '/m/lightning.safetensors',
        taesdPath: '/m/taesdxl.safetensors',
      );

      expect(model.family, ImageGenerationModelFamily.sdxlLightning);
      expect(model.files.paths, {
        'model': '/m/lightning.safetensors',
        'taesd': '/m/taesdxl.safetensors',
      });
      expect(model.defaults.steps, 4);
      expect(model.defaults.guidanceScale, 1);
      expect(model.defaults.sampler, ImageGenerationSampler.euler);
      expect(model.defaults.scheduler, ImageGenerationScheduler.sgmUniform);
      expect(
        ImageGenerationModel.sdxlLightning(
          '/m/lightning.safetensors',
          vaePath: '/m/vae.safetensors',
        ).files.paths.keys,
        ['model', 'vae'],
      );
    });

    test('flux1Schnell takes split files and 4 steps at guidance 1', () {
      final model = ImageGenerationModel.flux1Schnell(
        diffusionModelPath: '/m/flux.gguf',
        clipLPath: '/m/clip_l.gguf',
        t5xxlPath: '/m/t5.gguf',
        vaePath: '/m/ae.safetensors',
      );

      expect(model.family, ImageGenerationModelFamily.flux1Schnell);
      expect(model.files.paths, {
        'diffusionModel': '/m/flux.gguf',
        'vae': '/m/ae.safetensors',
        'clipL': '/m/clip_l.gguf',
        't5xxl': '/m/t5.gguf',
      });
      expect((model.defaults.steps, model.defaults.guidanceScale), (4, 1.0));
      expect(model.defaults.sampler, isNull);
    });

    test('flux1Schnell decodes with TAESD alone when no VAE is given', () {
      final model = ImageGenerationModel.flux1Schnell(
        diffusionModelPath: '/m/flux.gguf',
        clipLPath: '/m/clip_l.gguf',
        t5xxlPath: '/m/t5.gguf',
        taesdPath: '/m/taef1.safetensors',
      );

      expect(model.files.paths, {
        'diffusionModel': '/m/flux.gguf',
        'taesd': '/m/taef1.safetensors',
        'clipL': '/m/clip_l.gguf',
        't5xxl': '/m/t5.gguf',
      });
    });

    test('sd35LargeTurbo takes three text encoders and 4 steps', () {
      final model = ImageGenerationModel.sd35LargeTurbo(
        diffusionModelPath: '/m/sd35lt.gguf',
        clipLPath: '/m/clip_l.gguf',
        clipGPath: '/m/clip_g.gguf',
        t5xxlPath: '/m/t5.gguf',
        taesdPath: '/m/taesd3.safetensors',
      );

      expect(model.family, ImageGenerationModelFamily.sd35LargeTurbo);
      expect(model.files.paths, {
        'diffusionModel': '/m/sd35lt.gguf',
        'taesd': '/m/taesd3.safetensors',
        'clipL': '/m/clip_l.gguf',
        'clipG': '/m/clip_g.gguf',
        't5xxl': '/m/t5.gguf',
      });
      expect((model.defaults.steps, model.defaults.guidanceScale), (4, 1.0));
    });

    test('zImageTurbo takes an llm text encoder and 8 steps', () {
      final model = ImageGenerationModel.zImageTurbo(
        diffusionModelPath: '/m/z.gguf',
        llmPath: '/m/qwen3.gguf',
        vaePath: '/m/ae.safetensors',
      );

      expect(model.family, ImageGenerationModelFamily.zImageTurbo);
      expect(model.files.paths, {
        'diffusionModel': '/m/z.gguf',
        'vae': '/m/ae.safetensors',
        'llm': '/m/qwen3.gguf',
      });
      expect((model.defaults.steps, model.defaults.guidanceScale), (8, 1.0));
    });

    test('split presets need a VAE or TAESD decoder', () {
      for (final (name, build) in <(String, ImageGenerationModel Function())>[
        (
          'flux1Schnell',
          () => ImageGenerationModel.flux1Schnell(
            diffusionModelPath: '/m/flux.gguf',
            clipLPath: '/m/clip_l.gguf',
            t5xxlPath: '/m/t5.gguf',
          ),
        ),
        (
          'sd35LargeTurbo',
          () => ImageGenerationModel.sd35LargeTurbo(
            diffusionModelPath: '/m/sd35lt.gguf',
            clipLPath: '/m/clip_l.gguf',
            clipGPath: '/m/clip_g.gguf',
            t5xxlPath: '/m/t5.gguf',
          ),
        ),
      ]) {
        expect(
          build,
          throwsA(
            isA<ArgumentError>().having(
              (error) => '${error.message}',
              'message',
              contains('$name needs vaePath or taesdPath'),
            ),
          ),
        );
      }
    });

    test('custom keeps its files and defaults to 20 steps at guidance 7', () {
      final model = ImageGenerationModel.custom(
        const ImageGenerationModelFiles(
          diffusionModel: '/m/unet.gguf',
          vae: '/m/vae.safetensors',
          clipL: '/m/clip_l.safetensors',
          clipG: '/m/clip_g.safetensors',
          t5xxl: '/m/t5.gguf',
          llm: '/m/qwen3.gguf',
        ),
      );

      expect(model.family, ImageGenerationModelFamily.custom);
      expect(model.files.paths.keys, [
        'diffusionModel',
        'vae',
        'clipL',
        'clipG',
        't5xxl',
        'llm',
      ]);
      expect(model.defaults.steps, 20);
      expect(model.defaults.guidanceScale, 7);
      expect(model.defaults.sampler, isNull);
      expect(model.defaults.scheduler, isNull);
      expect(model.defaults.flowShift, isNull);

      final tuned = ImageGenerationModel.custom(
        const ImageGenerationModelFiles(model: '/m/sd15.safetensors'),
        defaults: const ImageGenerationDefaults(steps: 8, guidanceScale: 2),
      );
      expect(tuned.defaults.steps, 8);
      expect(tuned.defaults.guidanceScale, 2);
    });
  });

  test('options default to auto, physical cores and a memory check', () {
    const options = ImageGenerationOptions();

    expect(options.device, ImageGenerationDevice.auto);
    expect(options.threads, 0);
    expect(options.checkMemory, isTrue);
    expect(options.flashAttention, isNull);
    expect(options.vaeDirectConvolution, isNull);
  });
}
