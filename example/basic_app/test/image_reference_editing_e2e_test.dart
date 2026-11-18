@Tags(['local-only'])
@Timeout(Duration(minutes: 60))
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';
import 'package:test/test.dart';

const _size = 512;
const _prompt =
    'Change the red circle to blue. Keep the gray background and the dark bar.';

/// A red disk above a dark bar on a light gray background; matches
/// `fixtures/image_reference_editing_native_reference.cpp`.
Uint8List _referencePixels() {
  final pixels = Uint8List(_size * _size * 3);
  for (var y = 0; y < _size; y++) {
    for (var x = 0; x < _size; x++) {
      final dx = x - 256;
      final dy = y - 224;
      final (r, g, b) = dx * dx + dy * dy <= 120 * 120
          ? (200, 30, 30)
          : y >= 432 && y < 464 && x >= 64 && x < 448
          ? (40, 40, 40)
          : (225, 225, 225);
      final offset = (y * _size + x) * 3;
      pixels
        ..[offset] = r
        ..[offset + 1] = g
        ..[offset + 2] = b;
    }
  }
  return pixels;
}

void main() {
  final environment = Platform.environment;
  final diffusion = environment['LLAMADART_REFERENCE_EDIT_DIFFUSION'];
  final vae = environment['LLAMADART_REFERENCE_EDIT_VAE'];
  final clipL = environment['LLAMADART_REFERENCE_EDIT_CLIP_L'];
  final t5xxl = environment['LLAMADART_REFERENCE_EDIT_T5XXL'];
  test(
    'v0.4.0 refuses the historical FLUX.1 Kontext reference edit on Metal',
    () async {
      final engine = await ImageGenerationEngine.load(
        ImageGenerationModel(
          ModelSource.path(diffusion!),
          components: [
            ImageModelComponent.auto(ModelSource.path(vae!)),
            ImageModelComponent.auto(ModelSource.path(clipL!)),
            ImageModelComponent.auto(ModelSource.path(t5xxl!)),
          ],
        ),
        params: const ImageModelParams(device: ComputeDevice.gpu),
      );
      addTearDown(engine.dispose);

      final capabilities = await engine.capabilities;
      expect(capabilities.modelVersion, 'Flux');
      expect(capabilities.backendName, startsWith('MTL'));
      expect(capabilities.supportsReferenceImageEditing, isFalse);

      final request = ReferenceImageEditingRequest(
        prompt: _prompt,
        recipe: ImageReferenceEditingRecipe.fluxKontext,
        references: [
          ImageEditingPixels.rgb(
            width: _size,
            height: _size,
            pixels: _referencePixels(),
          ),
        ],
        steps: 20,
        guidanceScale: 1,
        seed: 42,
        sampler: ImageGenerationSampler.euler,
      );
      await expectLater(
        engine.generate(request),
        throwsA(
          isA<LlamaUnsupportedException>().having(
            (error) => error.message,
            'message',
            contains('Reference image editing'),
          ),
        ),
      );
    },
    skip: !Platform.isMacOS
        ? 'The refusal scenario requires macOS Metal'
        : [diffusion, vae, clipL, t5xxl].contains(null)
        ? 'Set LLAMADART_REFERENCE_EDIT_DIFFUSION, _VAE, _CLIP_L and _T5XXL'
        : false,
  );
}
