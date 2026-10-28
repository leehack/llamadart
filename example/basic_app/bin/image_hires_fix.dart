import 'dart:io';

import 'package:llamadart/llamadart.dart';

/// Run: dart run bin/image_hires_fix.dart /path/to/sd15.safetensors
/// output.png [cpu|gpu]
Future<void> main(List<String> arguments) async {
  if (arguments.length < 2 ||
      arguments.length > 3 ||
      !const {'cpu', 'gpu'}.contains(arguments.elementAtOrNull(2) ?? 'cpu')) {
    stderr.writeln(
      'Usage: image_hires_fix.dart CHECKPOINT OUTPUT.png [cpu|gpu]',
    );
    exitCode = 64;
    return;
  }
  final engine = await ImageGenerationEngine.load(
    ImageGenerationModel(ModelSource.path(arguments[0])),
    params: ImageModelParams(
      device: arguments.elementAtOrNull(2) == 'gpu'
          ? ComputeDevice.gpu
          : ComputeDevice.cpu,
    ),
  );
  try {
    if (!(await engine.capabilities).supportsHiresFix) {
      throw LlamaUnsupportedException(
        'Use an SD 1.x or SD 2.x checkpoint with its embedded full VAE on '
        'macOS CPU or Metal.',
      );
    }
    final task = await engine.generate(
      const HiresFixImageGenerationRequest(
        prompt: 'a red fox sitting in a snowy forest, photograph',
        negativePrompt: 'blurry',
        width: 512,
        height: 512,
        steps: 20,
        guidanceScale: 7,
        seed: 42,
        hiresFix: ImageHiresFix.scale(1.5, steps: 10, denoisingStrength: 0.55),
      ),
    );
    await for (final event in task.events) {
      if (event case ImageGenerationProgressEvent(
        phase: ImageGenerationPhase.sampling,
        :final pass,
        :final passCount,
        :final step,
        :final steps,
      )) {
        stdout.write('\rpass ${pass + 1}/$passCount, step $step/$steps   ');
      }
    }
    stdout.writeln();
    final image = (await task.result).images.single;
    await File(arguments[1]).writeAsBytes(image.toPng());
    stdout.writeln('Wrote ${image.width}x${image.height} to ${arguments[1]}');
  } finally {
    await engine.dispose();
  }
}
