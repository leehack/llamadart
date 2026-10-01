@TestOn('vm')
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

import 'package:llamadart/src/backends/stable_diffusion/stable_diffusion_bindings.dart'
    as sd;
import 'package:llamadart/src/backends/stable_diffusion/stable_diffusion_params.dart';
import 'package:llamadart/src/core/image/image_generation_driver.dart';
import 'package:llamadart/src/core/image/image_generation_model.dart';

String? _text(Pointer<Char> value) =>
    value == nullptr ? null : value.cast<Utf8>().toDartString();

void main() {
  group('applyStableDiffusionContextParams', () {
    Pointer<sd.sd_ctx_params_t> apply(
      Arena arena,
      ImageGenerationSessionConfig config,
    ) {
      final params = arena<sd.sd_ctx_params_t>();
      applyStableDiffusionContextParams(params, config, arena);
      return params;
    }

    test('writes every file role to its own path field', () {
      using((arena) {
        final params = apply(
          arena,
          const ImageGenerationSessionConfig(
            files: {
              'model': '/m/model.gguf',
              'diffusionModel': '/m/diffusion.gguf',
              'vae': '/m/vae.safetensors',
              'taesd': '/m/taesd.safetensors',
              'clipL': '/m/clip_l.gguf',
              'clipG': '/m/clip_g.gguf',
              't5xxl': '/m/t5xxl.gguf',
              'llm': '/m/qwen3.gguf',
            },
            backend: 'gpu',
            threads: 6,
          ),
        ).ref;

        expect(_text(params.model_path), '/m/model.gguf');
        expect(_text(params.diffusion_model_path), '/m/diffusion.gguf');
        expect(_text(params.vae_path), '/m/vae.safetensors');
        expect(_text(params.taesd_path), '/m/taesd.safetensors');
        expect(_text(params.clip_l_path), '/m/clip_l.gguf');
        expect(_text(params.clip_g_path), '/m/clip_g.gguf');
        expect(_text(params.t5xxl_path), '/m/t5xxl.gguf');
        expect(_text(params.llm_path), '/m/qwen3.gguf');
        expect(_text(params.backend), 'gpu');
        expect(params.n_threads, 6);
        expect(params.eager_load, isTrue);
      });
    });

    test('leaves unset roles, backend and threads at their defaults', () {
      using((arena) {
        final params = arena<sd.sd_ctx_params_t>();
        params.ref.n_threads = -1;
        applyStableDiffusionContextParams(
          params,
          const ImageGenerationSessionConfig(
            files: {'model': '/m/sdxs.gguf'},
            backend: null,
            threads: 0,
          ),
          arena,
        );

        expect(_text(params.ref.model_path), '/m/sdxs.gguf');
        for (final field in [
          params.ref.diffusion_model_path,
          params.ref.vae_path,
          params.ref.taesd_path,
          params.ref.clip_l_path,
          params.ref.clip_g_path,
          params.ref.t5xxl_path,
          params.ref.llm_path,
          params.ref.backend,
        ]) {
          expect(field, nullptr);
        }
        expect(params.ref.n_threads, -1);
      });
    });

    test('writes flash attention and direct VAE convolutions to their own '
        'fields', () {
      using((arena) {
        for (final (flashAttention, vaeDirectConvolution) in [
          (true, false),
          (false, true),
          (true, true),
          (false, false),
        ]) {
          final params = apply(
            arena,
            ImageGenerationSessionConfig(
              files: const {'model': '/m/sdxs.gguf'},
              backend: null,
              threads: 0,
              flashAttention: flashAttention,
              vaeDirectConvolution: vaeDirectConvolution,
            ),
          ).ref;

          final reason = 'fa $flashAttention, vcd $vaeDirectConvolution';
          expect(params.diffusion_flash_attn, flashAttention, reason: reason);
          expect(params.vae_conv_direct, vaeDirectConvolution, reason: reason);
          expect(params.flash_attn, isFalse, reason: reason);
          expect(params.diffusion_conv_direct, isFalse, reason: reason);
        }
      });
    });
  });

  group('applyStableDiffusionGenerationParams', () {
    const request = ImageGenerationSessionRequest(
      prompt: 'a fox',
      negativePrompt: 'blurry',
      width: 1024,
      height: 768,
      steps: 4,
      guidanceScale: 1.5,
      seed: 42,
      count: 2,
    );

    test('writes the prompt, size, seed, count, steps and guidance', () {
      using((arena) {
        final params = arena<sd.sd_img_gen_params_t>();
        applyStableDiffusionGenerationParams(params, request, arena);

        expect(_text(params.ref.prompt), 'a fox');
        expect(_text(params.ref.negative_prompt), 'blurry');
        expect((params.ref.width, params.ref.height), (1024, 768));
        expect(params.ref.seed, 42);
        expect(params.ref.batch_count, 2);
        expect(params.ref.sample_params.sample_steps, 4);
        expect(params.ref.sample_params.guidance.txt_cfg, 1.5);
      });
    });

    test('an unset sampler, scheduler and flow shift ask the runtime for '
        'its defaults', () {
      using((arena) {
        final params = arena<sd.sd_img_gen_params_t>();
        applyStableDiffusionGenerationParams(params, request, arena);

        final sample = params.ref.sample_params;
        expect(sample.sample_methodAsInt, 21);
        expect(sample.schedulerAsInt, 17);
        expect(sample.flow_shift, double.infinity);
      });
    });

    test('writes a set sampler, scheduler and flow shift', () {
      using((arena) {
        final params = arena<sd.sd_img_gen_params_t>();
        applyStableDiffusionGenerationParams(
          params,
          const ImageGenerationSessionRequest(
            prompt: 'a fox',
            negativePrompt: '',
            width: 512,
            height: 512,
            steps: 4,
            guidanceScale: 1,
            seed: 0,
            count: 1,
            sampler: ImageGenerationSampler.euler,
            scheduler: ImageGenerationScheduler.sgmUniform,
            flowShift: 3,
          ),
          arena,
        );

        final sample = params.ref.sample_params;
        expect(sample.sample_methodAsInt, 0);
        expect(sample.schedulerAsInt, 5);
        expect(sample.flow_shift, 3);
      });
    });
  });

  test('samplers map to stable-diffusion.h sample_method_t values', () {
    expect(
      {
        for (final sampler in [null, ...ImageGenerationSampler.values])
          sampler?.name: stableDiffusionSampleMethod(sampler).value,
      },
      {null: 21, 'euler': 0, 'eulerAncestral': 1, 'dpmpp2m': 5, 'lcm': 9},
    );
  });

  test('schedulers map to stable-diffusion.h scheduler_t values', () {
    expect(
      {
        for (final scheduler in [null, ...ImageGenerationScheduler.values])
          scheduler?.name: stableDiffusionScheduler(scheduler).value,
      },
      {null: 17, 'discrete': 0, 'karras': 1, 'sgmUniform': 5, 'simple': 6},
    );
  });

  test('an unset flow shift is infinity, the runtime default', () {
    expect(stableDiffusionFlowShift(null), double.infinity);
    expect(stableDiffusionFlowShift(3), 3);
  });
}
