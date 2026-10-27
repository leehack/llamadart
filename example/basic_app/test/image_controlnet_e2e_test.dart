@Tags(['local-only'])
@Timeout(Duration(minutes: 20))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:llamadart/llamadart.dart';
import 'package:test/test.dart';

const _size = 256;
const _prompt = 'a small wooden house in a green meadow, photograph';

/// White three-pixel lines on black: a house outline (0) or a diagonal
/// cross (1). Matches `fixtures/image_controlnet_native_reference.cpp`.
Uint8List _edges(int shape) {
  final rgb = Uint8List(_size * _size * 3);
  void line(int x0, int y0, int x1, int y1) {
    final steps = (x1 - x0).abs() > (y1 - y0).abs()
        ? (x1 - x0).abs()
        : (y1 - y0).abs();
    for (var i = 0; i <= steps; i++) {
      final x = x0 + (x1 - x0) * i ~/ steps;
      final y = y0 + (y1 - y0) * i ~/ steps;
      for (var dy = -1; dy <= 1; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          final px = x + dx;
          final py = y + dy;
          if (px < 0 || py < 0 || px >= _size || py >= _size) continue;
          rgb.fillRange((py * _size + px) * 3, (py * _size + px) * 3 + 3, 255);
        }
      }
    }
  }

  if (shape == 0) {
    line(64, 224, 192, 224);
    line(64, 224, 64, 128);
    line(192, 224, 192, 128);
    line(56, 128, 128, 56);
    line(128, 56, 200, 128);
    line(56, 128, 200, 128);
  } else {
    line(16, 16, 240, 240);
    line(240, 16, 16, 240);
  }
  return rgb;
}

void main() {
  final model = Platform.environment['LLAMADART_SD15_MODEL'];
  final controlNet = Platform.environment['LLAMADART_SD15_CONTROLNET'];
  final output = Platform.environment['LLAMADART_IMAGE_OUTPUT_DIR'];
  final references =
      Platform.environment['LLAMADART_CONTROLNET_NATIVE_REFERENCES'];
  test(
    'SD 1.x ControlNet CPU control image, strength, reset, cancellation and '
    'reload',
    () async {
      final house = _edges(0);
      final cross = _edges(1);
      // Modes: ordinary text, house at 1, house at 0, cross at 1, house at 2,
      // ordinary text reset.
      ImageGenerationRequest request(int mode, {int steps = 8}) {
        if (mode == 0 || mode == 5) {
          return ImageGenerationRequest(
            prompt: _prompt,
            width: _size,
            height: _size,
            steps: steps,
            guidanceScale: 7,
            seed: 42,
            sampler: ImageGenerationSampler.euler,
            scheduler: ImageGenerationScheduler.discrete,
          );
        }
        return ControlNetImageGenerationRequest(
          prompt: _prompt,
          control: ImageControlNetCondition(
            image: ImageEditingPixels.rgb(
              width: _size,
              height: _size,
              pixels: mode == 3 ? cross : house,
            ),
            strength: switch (mode) {
              2 => 0,
              4 => 2,
              _ => 1,
            },
          ),
          steps: steps,
          guidanceScale: 7,
          seed: 42,
          sampler: ImageGenerationSampler.euler,
          scheduler: ImageGenerationScheduler.discrete,
        );
      }

      Future<ImageGenerationEngine> load() => ImageGenerationEngine.load(
        ImageGenerationModel(
          ModelSource.path(model!),
          components: [ImageModelComponent.auto(ModelSource.path(controlNet!))],
        ),
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
      expect(capabilities.modelVersion, 'SD 1.x');
      expect(capabilities.supportsControlNet, isTrue);
      expect(engine.roles.keys, {
        ImageModelRole.checkpoint,
        ImageModelRole.controlNet,
      });
      final images = <GeneratedImage>[];
      final records = <Map<String, Object>>[];
      if (output != null) {
        Directory(output).createSync(recursive: true);
        for (final (name, rgb) in [('house', house), ('cross', cross)]) {
          File('$output/control-$name.png').writeAsBytesSync(
            GeneratedImage(
              width: _size,
              height: _size,
              channels: 3,
              pixels: rgb,
            ).toPng(),
          );
        }
      }
      for (var mode = 0; mode < 6; mode++) {
        final image = (await engine.generateImage(request(mode))).images.single;
        images.add(image);
        expect((image.width, image.height, image.channels), (_size, _size, 3));
        expect(image.pixels.toSet().length, greaterThan(64));
        if (references != null) {
          final reference = File(
            '$references/control-$mode.ppm',
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
        images[5].pixels,
        images[0].pixels,
        reason: 'ordinary requests carry no control after ControlNet requests',
      );
      expect(
        images[2].pixels,
        images[0].pixels,
        reason: 'strength 0 adds zero residuals',
      );
      final strengthMae = _mae(images[1], images[2]);
      final imageMae = _mae(images[1], images[3]);
      final houseFollow = _edgeContrast(images[1], house);
      final crossOnHouse = _edgeContrast(images[3], house);
      // Fixed before qualification, not tuned to observed outputs.
      expect(strengthMae, greaterThan(1), reason: 'strength reaches sampling');
      expect(imageMae, greaterThan(1), reason: 'control image reaches it');
      expect(
        houseFollow,
        greaterThan(crossOnHouse),
        reason: 'output edges follow the control map',
      );
      final metrics = {
        'strength1VsStrength0Mae': strengthMae,
        'houseVsCrossMae': imageMae,
        'strength2VsStrength1Mae': _mae(images[4], images[1]),
        'houseEdgeContrastWithHouse': houseFollow,
        'houseEdgeContrastWithCross': crossOnHouse,
        'backend': capabilities.backendName,
        'runtime': capabilities.runtimeVersion,
        'images': records,
      };
      print('CONTROLNET_METRICS ${jsonEncode(metrics)}');
      if (output != null) {
        File('$output/results.json').writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(metrics),
        );
      }
      final task = await engine.generate(request(1, steps: 20));
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
        (await engine.generateImage(request(1))).images.single.pixels,
        images[1].pixels,
      );
      await engine.dispose();
      expect((await engine.capabilities).supportsControlNet, isFalse);
      final reloaded = await load();
      try {
        expect((await reloaded.capabilities).supportsControlNet, isTrue);
        expect(
          (await reloaded.generateImage(request(3))).images.single.pixels,
          images[3].pixels,
        );
      } finally {
        await reloaded.dispose();
      }
    },
    skip: !Platform.isMacOS
        ? 'Bounded recipe is macOS CPU'
        : model == null || controlNet == null
        ? 'Set LLAMADART_SD15_MODEL and LLAMADART_SD15_CONTROLNET'
        : false,
  );
}

double _mae(GeneratedImage a, GeneratedImage b) {
  var sum = 0;
  for (var i = 0; i < a.pixels.length; i++) {
    sum += (a.pixels[i] - b.pixels[i]).abs();
  }
  return sum / a.pixels.length;
}

/// Mean luminance gradient of [image] on the white pixels of [edges] minus
/// its mean gradient elsewhere.
double _edgeContrast(GeneratedImage image, Uint8List edges) {
  double luma(int x, int y) {
    final i = (y * _size + x) * 3;
    return 0.299 * image.pixels[i] +
        0.587 * image.pixels[i + 1] +
        0.114 * image.pixels[i + 2];
  }

  var onSum = 0.0;
  var onCount = 0;
  var offSum = 0.0;
  var offCount = 0;
  for (var y = 1; y < _size - 1; y++) {
    for (var x = 1; x < _size - 1; x++) {
      final gradient =
          (luma(x + 1, y) - luma(x - 1, y)).abs() +
          (luma(x, y + 1) - luma(x, y - 1)).abs();
      if (edges[(y * _size + x) * 3] == 255) {
        onSum += gradient;
        onCount++;
      } else {
        offSum += gradient;
        offCount++;
      }
    }
  }
  return onSum / onCount - offSum / offCount;
}
