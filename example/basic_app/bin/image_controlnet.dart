import 'dart:io';
import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';

/// Run: dart run bin/image_controlnet.dart /path/to/sd15.safetensors
/// /path/to/control_sd15_canny.safetensors output.png
Future<void> main(List<String> arguments) async {
  if (arguments.length != 3) {
    stderr.writeln(
      'Usage: image_controlnet.dart CHECKPOINT CANNY_CONTROLNET OUTPUT.png',
    );
    exitCode = 64;
    return;
  }
  final engine = await ImageGenerationEngine.load(
    ImageGenerationModel(
      ModelSource.path(arguments[0]),
      components: [ImageModelComponent.auto(ModelSource.path(arguments[1]))],
    ),
    params: const ImageModelParams(
      device: ComputeDevice.cpu,
      threads: 4,
      flashAttention: false,
      vaeDirectConvolution: false,
    ),
  );
  try {
    if (!(await engine.capabilities).supportsControlNet) {
      throw LlamaUnsupportedException(
        'Use the macOS CPU SD 1.x ControlNet recipe.',
      );
    }
    final result = await engine.generateImage(
      ControlNetImageGenerationRequest(
        prompt: 'a small wooden house in a green meadow, photograph',
        control: ImageControlNetCondition(image: houseEdges(), strength: 1),
        steps: 20,
        guidanceScale: 7,
        seed: 42,
        sampler: ImageGenerationSampler.euler,
        scheduler: ImageGenerationScheduler.discrete,
      ),
    );
    await File(arguments[2]).writeAsBytes(result.images.single.toPng());
  } finally {
    await engine.dispose();
  }
}

/// A 512x512 Canny-style edge map, white lines on black, of a house outline.
/// A real app runs its own edge detector; the runtime receives these pixels
/// unchanged.
ImageEditingPixels houseEdges() {
  const size = 512;
  final rgb = Uint8List(size * size * 3);
  void dot(int x, int y) {
    for (var dy = -1; dy <= 1; dy++) {
      for (var dx = -1; dx <= 1; dx++) {
        final px = x + dx;
        final py = y + dy;
        if (px < 0 || py < 0 || px >= size || py >= size) continue;
        rgb.fillRange((py * size + px) * 3, (py * size + px) * 3 + 3, 255);
      }
    }
  }

  void line(int x0, int y0, int x1, int y1) {
    final steps = (x1 - x0).abs() > (y1 - y0).abs()
        ? (x1 - x0).abs()
        : (y1 - y0).abs();
    for (var i = 0; i <= steps; i++) {
      dot(x0 + (x1 - x0) * i ~/ steps, y0 + (y1 - y0) * i ~/ steps);
    }
  }

  line(128, 448, 384, 448);
  line(128, 448, 128, 256);
  line(384, 448, 384, 256);
  line(112, 256, 256, 112);
  line(256, 112, 400, 256);
  line(112, 256, 400, 256);
  line(224, 448, 224, 352);
  line(288, 448, 288, 352);
  line(224, 352, 288, 352);
  return ImageEditingPixels.rgb(width: size, height: size, pixels: rgb);
}
