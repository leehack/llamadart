@Tags(['local-only'])
@Timeout(Duration(minutes: 60))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
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
  final output = environment['LLAMADART_IMAGE_OUTPUT_DIR'];
  final references = environment['LLAMADART_REFERENCE_EDIT_NATIVE_REFERENCES'];
  test(
    'FLUX.1 Kontext reference editing on Metal: visible edit, preserved '
    'content, references used, direct-C parity, cancellation and reload',
    () async {
      final referencePixels = _referencePixels();
      final edit = ReferenceImageEditingRequest(
        prompt: _prompt,
        recipe: ImageReferenceEditingRecipe.fluxKontext,
        references: [
          ImageEditingPixels.rgb(
            width: _size,
            height: _size,
            pixels: referencePixels,
          ),
        ],
        steps: 20,
        guidanceScale: 1,
        seed: 42,
        sampler: ImageGenerationSampler.euler,
      );
      const plain = ImageGenerationRequest(
        prompt: _prompt,
        width: _size,
        height: _size,
        steps: 20,
        guidanceScale: 1,
        seed: 42,
        sampler: ImageGenerationSampler.euler,
      );
      Future<ImageGenerationEngine> load() => ImageGenerationEngine.load(
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

      final engine = await load();
      addTearDown(engine.dispose);
      final capabilities = await engine.capabilities;
      expect(capabilities.modelVersion, 'Flux');
      expect(capabilities.backendName, startsWith('MTL'));
      expect(capabilities.supportsReferenceImageEditing, isTrue);

      final records = <String, Object>{};
      Future<GeneratedImage> run(
        String name,
        ImageGenerationRequest request,
      ) async {
        final result = await engine.generateImage(request);
        final image = result.images.single;
        records[name] = {
          'size': '${image.width}x${image.height}',
          'sha256': sha256.convert(image.pixels).toString(),
          'elapsedMs': result.elapsed.inMilliseconds,
        };
        if (output != null) {
          File('$output/$name.png').writeAsBytesSync(image.toPng());
        }
        if (references != null && (name == 'edit' || name == 'plain')) {
          final bytes = File('$references/$name.ppm').readAsBytesSync();
          expect(
            image.pixels,
            bytes.sublist(bytes.length - image.pixels.length),
            reason: 'Independent direct-C parity $name',
          );
        }
        return image;
      }

      if (output != null) {
        Directory(output).createSync(recursive: true);
        File('$output/reference.png').writeAsBytesSync(
          GeneratedImage(
            width: _size,
            height: _size,
            channels: 3,
            pixels: referencePixels,
          ).toPng(),
        );
      }
      final edited = await run('edit', edit);
      expect((edited.width, edited.height, edited.channels), (_size, _size, 3));
      final ordinary = await run('plain', plain);

      // Fixed before qualification, not tuned to observed outputs.
      final disk = _region(
        edited.pixels,
        (x, y) => _distance2(x, y) <= 90 * 90,
      );
      final sourceDisk = _region(
        referencePixels,
        (x, y) => _distance2(x, y) <= 90 * 90,
      );
      bool background(int x, int y) =>
          _distance2(x, y) >= 150 * 150 && (y < 416 || y >= 480) && y >= 16;
      final keptMae = _maeIn(edited.pixels, referencePixels, background);
      final bar = _region(
        edited.pixels,
        (x, y) => y >= 440 && y < 456 && x >= 96 && x < 416,
      );
      final referencesUsedMae = _mae(edited.pixels, ordinary.pixels);
      expect(
        sourceDisk.b - sourceDisk.r,
        lessThan(-100),
        reason: 'the fixture disk is red',
      );
      expect(disk.b - disk.r, greaterThan(40), reason: 'the disk turned blue');
      expect(keptMae, lessThan(25), reason: 'the background is kept');
      expect(
        (bar.r + bar.g + bar.b) / 3,
        lessThan(90),
        reason: 'the dark bar is kept',
      );
      expect(
        referencesUsedMae,
        greaterThan(10),
        reason: 'the reference changes the output',
      );

      final task = await engine.generate(edit);
      var cancelled = false;
      await for (final event in task.events) {
        if (event case ImageGenerationProgressEvent(
          phase: ImageGenerationPhase.sampling,
          :final step,
        ) when step > 0 && !cancelled) {
          cancelled = true;
          task.cancel();
        }
      }
      expect(cancelled, isTrue);
      expect((await task.done).state, ImageGenerationCompletionState.cancelled);
      expect((await task.done).result, isNull);
      expect(
        (await engine.generateImage(edit)).images.single.pixels,
        edited.pixels,
        reason: 'reuse after a cancel',
      );
      expect(
        (await engine.generateImage(plain)).images.single.pixels,
        ordinary.pixels,
        reason: 'an ordinary request after an edit',
      );
      await engine.dispose();
      expect(
        (await engine.capabilities).supportsReferenceImageEditing,
        isFalse,
      );
      final reloaded = await load();
      try {
        expect(
          (await reloaded.capabilities).supportsReferenceImageEditing,
          isTrue,
        );
        expect(
          (await reloaded.generateImage(edit)).images.single.pixels,
          edited.pixels,
          reason: 'reload',
        );
      } finally {
        await reloaded.dispose();
      }

      final metrics = {
        'backend': capabilities.backendName,
        'runtime': capabilities.runtimeVersion,
        'family': capabilities.modelVersion,
        'diskBlueMinusRed': disk.b - disk.r,
        'backgroundKeptMae': keptMae,
        'barMean': (bar.r + bar.g + bar.b) / 3,
        'editVsPlainMae': referencesUsedMae,
        'maxRssBytes': ProcessInfo.maxRss,
        'images': records,
      };
      print('REFERENCE_EDIT_METRICS ${jsonEncode(metrics)}');
      if (output != null) {
        File('$output/results.json').writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(metrics),
        );
      }
    },
    skip: !Platform.isMacOS
        ? 'The bounded recipe is macOS Metal'
        : [diffusion, vae, clipL, t5xxl].contains(null)
        ? 'Set LLAMADART_REFERENCE_EDIT_DIFFUSION, _VAE, _CLIP_L and _T5XXL'
        : false,
  );
}

/// Squared distance from the fixture disk's centre.
int _distance2(int x, int y) {
  final dx = x - 256;
  final dy = y - 224;
  return dx * dx + dy * dy;
}

({double r, double g, double b}) _region(
  Uint8List pixels,
  bool Function(int x, int y) inside,
) {
  var r = 0, g = 0, b = 0, count = 0;
  for (var y = 0; y < _size; y++) {
    for (var x = 0; x < _size; x++) {
      if (!inside(x, y)) continue;
      final offset = (y * _size + x) * 3;
      r += pixels[offset];
      g += pixels[offset + 1];
      b += pixels[offset + 2];
      count++;
    }
  }
  return (r: r / count, g: g / count, b: b / count);
}

double _mae(Uint8List a, Uint8List b) => _maeIn(a, b, (_, _) => true);

double _maeIn(Uint8List a, Uint8List b, bool Function(int x, int y) inside) {
  var sum = 0, count = 0;
  for (var y = 0; y < _size; y++) {
    for (var x = 0; x < _size; x++) {
      if (!inside(x, y)) continue;
      for (var c = 0; c < 3; c++) {
        final offset = (y * _size + x) * 3 + c;
        sum += (a[offset] - b[offset]).abs();
        count++;
      }
    }
  }
  return sum / count;
}
