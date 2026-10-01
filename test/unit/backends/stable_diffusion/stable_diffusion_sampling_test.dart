@TestOn('vm')
library;

import 'package:test/test.dart';

import 'package:llamadart/src/backends/stable_diffusion/stable_diffusion_sampling.dart';
import 'package:llamadart/src/core/image/image_generation_model.dart';

void main() {
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
