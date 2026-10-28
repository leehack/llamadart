import 'dart:io';
import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';

/// Run: dart run bin/image_reference_editing.dart
/// flux1-kontext-dev.gguf ae.safetensors clip_l.gguf t5xxl.gguf output.png
Future<void> main(List<String> arguments) async {
  if (arguments.length != 5) {
    stderr.writeln(
      'Usage: image_reference_editing.dart KONTEXT_TRANSFORMER AE CLIP_L '
      'T5XXL OUTPUT.png',
    );
    exitCode = 64;
    return;
  }
  // A decoded reference: a red disk on a light gray background. Crop or
  // resize real photos to the output size first.
  const size = 512;
  final rgb = Uint8List(size * size * 3);
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final inside = (x - 256) * (x - 256) + (y - 256) * (y - 256) <= 14400;
      rgb.setAll((y * size + x) * 3, inside ? [200, 30, 30] : [225, 225, 225]);
    }
  }
  final engine = await ImageGenerationEngine.load(
    ImageGenerationModel(
      ModelSource.path(arguments[0]),
      components: [
        for (final path in arguments.sublist(1, 4))
          ImageModelComponent.auto(ModelSource.path(path)),
      ],
    ),
    params: const ImageModelParams(device: ComputeDevice.gpu),
  );
  try {
    if (!(await engine.capabilities).supportsReferenceImageEditing) {
      throw LlamaUnsupportedException(
        'Use the FLUX.1 Kontext [dev] transformer with ae, CLIP-L and T5-XXL '
        'on macOS Metal.',
      );
    }
    final result = await engine.generateImage(
      ReferenceImageEditingRequest(
        prompt: 'Change the red circle to blue.',
        recipe: ImageReferenceEditingRecipe.fluxKontext,
        references: [
          ImageEditingPixels.rgb(width: size, height: size, pixels: rgb),
        ],
        steps: 20,
        guidanceScale: 1,
        seed: 42,
      ),
    );
    await File(arguments[4]).writeAsBytes(result.images.single.toPng());
  } finally {
    await engine.dispose();
  }
}
