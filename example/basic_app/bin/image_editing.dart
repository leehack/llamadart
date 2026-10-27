import 'dart:io';
import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';

/// Run: dart run bin/image_editing.dart /path/to/sd-turbo.gguf output.png
Future<void> main(List<String> arguments) async {
  if (arguments.length != 2) {
    stderr.writeln('Usage: image_editing.dart CHECKPOINT OUTPUT.png');
    exitCode = 64;
    return;
  }
  const size = 256;
  final rgb = Uint8List(size * size * 3);
  final mask = Uint8List(size * size);
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final i = y * size + x;
      rgb[i * 3] = x;
      rgb[i * 3 + 1] = y;
      rgb[i * 3 + 2] = 128;
      mask[i] = x < size ~/ 2 ? 255 : 0;
    }
  }
  final engine = await ImageGenerationEngine.load(
    ImageGenerationModel(ModelSource.path(arguments[0])),
    params: const ImageModelParams(
      device: ComputeDevice.cpu,
      threads: 4,
      flashAttention: false,
      vaeDirectConvolution: false,
    ),
  );
  try {
    if (!(await engine.capabilities).supportsImageEditing) {
      throw LlamaUnsupportedException(
        'Use the macOS CPU SD 2.x embedded full-VAE recipe.',
      );
    }
    final result = await engine.generateImage(
      ImageEditingRequest(
        prompt: 'a colorful painting of a small wooden house in a green meadow',
        initialImage: ImageEditingPixels.rgb(
          width: size,
          height: size,
          pixels: rgb,
        ),
        mask: ImageEditingPixels.mask(width: size, height: size, pixels: mask),
        strength: 0.75,
        steps: 4,
        guidanceScale: 1,
        seed: 42,
        sampler: ImageGenerationSampler.euler,
        scheduler: ImageGenerationScheduler.discrete,
      ),
    );
    await File(arguments[1]).writeAsBytes(result.images.single.toPng());
  } finally {
    await engine.dispose();
  }
}
