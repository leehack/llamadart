import 'dart:convert';
import 'dart:io';

import 'package:llamadart/llamadart.dart';

/// Run with DIRECTORY_OR_INDEX TRUSTED_SHA256_JSON PRIVATE_CACHE OUTPUT.png.
Future<void> main(List<String> args) async {
  if (args.length != 4) {
    stderr.writeln(
      'Usage: local_image_set.dart DIRECTORY_OR_INDEX SHA256_JSON PRIVATE_CACHE OUTPUT.png',
    );
    exitCode = 64;
    return;
  }
  final hashes = (jsonDecode(await File(args[1]).readAsString()) as Map)
      .cast<String, String>();
  final engine = await ImageGenerationEngine.load(
    ImageGenerationModel.localSafetensorsSet(
      args[0],
      sha256: hashes,
      cacheDirectory: args[2],
    ),
    params: const ImageModelParams(
      device: ComputeDevice.cpu,
      threads: 4,
      flashAttention: false,
      vaeDirectConvolution: false,
    ),
  );
  try {
    final image = (await engine.generateImage(
      const ImageGenerationRequest(
        prompt: 'a red fox in a green forest, watercolor painting',
        width: 128,
        height: 128,
        steps: 1,
        guidanceScale: 1,
        seed: 42,
        sampler: ImageGenerationSampler.euler,
        scheduler: ImageGenerationScheduler.discrete,
      ),
    )).images.single;
    await File(args[3]).writeAsBytes(image.toPng());
  } finally {
    await engine.dispose();
  }
}
