@TestOn('vm')
library;

import 'package:test/test.dart';

import 'package:llamadart/src/backends/stable_diffusion/stable_diffusion_image_worker.dart';
import 'package:llamadart/src/backends/stable_diffusion/stable_diffusion_runtime_io.dart';
import 'package:llamadart/src/core/exceptions.dart';
import 'package:llamadart/src/core/image/image_generation_driver.dart';

// Real generation needs the opt-in runtime, which the root package does not
// bundle; example/basic_app/test/image_generation_e2e_test.dart covers it.
void main() {
  test(
    'a worker whose runtime is missing fails its start and exits',
    () async {
      await expectLater(
        StableDiffusionImageWorker.start(
          const ImageGenerationSessionConfig(
            files: {'model': '/models/sdxs.gguf'},
            backend: null,
            threads: 0,
          ),
        ),
        throwsA(
          isA<LlamaStateException>().having(
            (error) => '${error.details}',
            'details',
            contains('stable_diffusion'),
          ),
        ),
      );
    },
    skip: probeStableDiffusionRuntime().isAvailable
        ? 'the stable_diffusion runtime is bundled here'
        : false,
  );
}
