@Tags(['local-only'])
@Timeout(Duration(minutes: 8))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:llamadart/llamadart.dart';
import 'package:test/test.dart';

const _size = 256;
const _prompt = 'a colorful painting of a small wooden house in a green meadow';

void main() {
  final model = Platform.environment['LLAMADART_SD_TURBO_MODEL'];
  final output = Platform.environment['LLAMADART_IMAGE_OUTPUT_DIR'];
  final references =
      Platform.environment['LLAMADART_EDITING_NATIVE_REFERENCES'];
  test(
    'SD-Turbo full-VAE CPU image, mask polarity, strength, cancellation and reset',
    () async {
      final rgb = Uint8List(_size * _size * 3);
      for (var y = 0; y < _size; y++) {
        for (var x = 0; x < _size; x++) {
          final i = (y * _size + x) * 3;
          rgb[i] = x ~/ 32 % 2 == 1 ? 220 : 40;
          rgb[i + 1] = y ~/ 32 % 2 == 1 ? 200 : 60;
          rgb[i + 2] = (x + y) % 256;
        }
      }
      final initial = ImageEditingPixels.rgb(
        width: _size,
        height: _size,
        pixels: rgb,
      );
      ImageGenerationRequest request(int mode, {int steps = 4}) {
        if (mode == 0 || mode == 6) {
          return ImageGenerationRequest(
            prompt: _prompt,
            width: _size,
            height: _size,
            steps: steps,
            guidanceScale: 1,
            seed: 42,
            sampler: ImageGenerationSampler.euler,
            scheduler: ImageGenerationScheduler.discrete,
          );
        }
        return ImageEditingRequest(
          prompt: _prompt,
          initialImage: initial,
          strength: mode == 2 ? 0.5 : 1,
          mask: mode < 3
              ? null
              : ImageEditingPixels.mask(
                  width: _size,
                  height: _size,
                  pixels: Uint8List.fromList(
                    List.generate(
                      _size * _size,
                      (i) => mode == 3 || (mode == 5 && i % _size < _size ~/ 2)
                          ? 255
                          : 0,
                    ),
                  ),
                ),
          steps: steps,
          guidanceScale: 1,
          seed: 42,
          sampler: ImageGenerationSampler.euler,
          scheduler: ImageGenerationScheduler.discrete,
        );
      }

      Future<ImageGenerationEngine> load() => ImageGenerationEngine.load(
        ImageGenerationModel(ModelSource.path(model!)),
        params: const ImageModelParams(
          device: ComputeDevice.cpu,
          threads: 4,
          flashAttention: false,
          vaeDirectConvolution: false,
        ),
      );
      final engine = await load();
      addTearDown(engine.dispose);
      final capabilities = await engine.capabilities;
      expect(capabilities.backendName, 'CPU');
      expect(capabilities.modelVersion, 'SD 2.x');
      expect(capabilities.supportsImageEditing, isTrue);
      final images = <GeneratedImage>[];
      final records = <Map<String, Object>>[];
      if (output != null) {
        Directory(output).createSync(recursive: true);
        File('$output/input.png').writeAsBytesSync(
          GeneratedImage(
            width: _size,
            height: _size,
            channels: 3,
            pixels: rgb,
          ).toPng(),
        );
      }
      for (var mode = 0; mode < 7; mode++) {
        final image = (await engine.generateImage(request(mode))).images.single;
        images.add(image);
        expect((image.width, image.height, image.channels), (_size, _size, 3));
        expect(image.pixels.toSet().length, greaterThan(64));
        if (references != null) {
          final reference = File(
            '$references/edit-$mode.ppm',
          ).readAsBytesSync();
          expect(
            image.pixels,
            reference.sublist(reference.length - image.pixels.length),
            reason: 'Independent direct-C parity mode $mode',
          );
        }
        records.add({
          'mode': mode,
          'sha256': sha256.convert(image.pixels).toString(),
        });
        if (output != null) {
          File('$output/mode-$mode.png').writeAsBytesSync(image.toPng());
        }
      }
      expect(
        images[6].pixels,
        images[0].pixels,
        reason: 'ordinary defaults reset after editing',
      );
      expect(
        images[3].pixels,
        images[1].pixels,
        reason: 'white mask equals omitted mask',
      );
      final strengthMae = _mae(images[1], images[2]);
      final editMae = _mae(images[5], images[4], left: true);
      final preserveMae = _mae(images[5], images[4], left: false);
      // Fixed before qualification; exclude a 32px center band to avoid VAE bleed.
      expect(strengthMae, greaterThan(1), reason: 'strength reaches sampling');
      expect(editMae, greaterThan(1), reason: 'white region changes');
      expect(
        editMae,
        greaterThan(preserveMae * 2),
        reason: 'white edits, black preserves latent',
      );
      final metrics = {
        'strengthMae': strengthMae,
        'whiteRegionMae': editMae,
        'blackRegionMae': preserveMae,
        'backend': capabilities.backendName,
        'runtime': capabilities.runtimeVersion,
        'images': records,
      };
      print('EDITING_METRICS ${jsonEncode(metrics)}');
      if (output != null) {
        File('$output/results.json').writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(metrics),
        );
      }
      final task = await engine.generate(request(5, steps: 20));
      var cancelledDuringSampling = false;
      await for (final event in task.events) {
        if (event case ImageGenerationProgressEvent(
          phase: ImageGenerationPhase.sampling,
          :final step,
        ) when step > 0) {
          cancelledDuringSampling = true;
          task.cancel();
        }
      }
      expect(cancelledDuringSampling, isTrue);
      expect((await task.done).state, ImageGenerationCompletionState.cancelled);
      expect(
        (await engine.generateImage(request(0))).images.single.pixels,
        images[0].pixels,
      );
      expect(
        (await engine.generateImage(request(5))).images.single.pixels,
        images[5].pixels,
      );
      await engine.dispose();
      expect((await engine.capabilities).supportsImageEditing, isFalse);
      final reloaded = await load();
      try {
        expect((await reloaded.capabilities).supportsImageEditing, isTrue);
        expect(
          (await reloaded.generateImage(request(2))).images.single.pixels,
          images[2].pixels,
        );
      } finally {
        await reloaded.dispose();
      }
    },
    skip: !Platform.isMacOS
        ? 'Bounded recipe is macOS CPU'
        : model == null
        ? 'Set LLAMADART_SD_TURBO_MODEL'
        : false,
  );
}

double _mae(GeneratedImage a, GeneratedImage b, {bool? left}) {
  var sum = 0;
  var count = 0;
  for (var y = 0; y < a.height; y++) {
    for (var x = 0; x < a.width; x++) {
      if (left == true && x >= _size ~/ 2 - 32 ||
          left == false && x < _size ~/ 2 + 32) {
        continue;
      }
      for (var c = 0; c < 3; c++) {
        final i = (y * a.width + x) * 3 + c;
        sum += (a.pixels[i] - b.pixels[i]).abs();
        count++;
      }
    }
  }
  return sum / count;
}
