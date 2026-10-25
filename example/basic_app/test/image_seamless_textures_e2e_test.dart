@Tags(['local-only'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:llamadart/llamadart.dart';
import 'package:test/test.dart';

const _prompt =
    'seamless texture of weathered gray stone, uniform rough stone '
    'surface, flat lighting, top down';

void main() {
  final model = Platform.environment['LLAMADART_SDXS_MODEL'];
  final output = Platform.environment['LLAMADART_IMAGE_OUTPUT_DIR'];
  final references =
      Platform.environment['LLAMADART_TEXTURE_NATIVE_REFERENCES'];
  final devices =
      (Platform.environment['LLAMADART_TEXTURE_DEVICES'] ?? 'cpu,metal').split(
        ',',
      );
  for (final device in devices) {
    test(
      'SDXS $device independent axes, seams, cancellation and reset',
      () async {
        expect(['cpu', 'metal'], contains(device));
        final engine = await ImageGenerationEngine.load(
          ImageGenerationModel(ModelSource.path(model!)),
          params: ImageModelParams(
            device: device == 'cpu' ? ComputeDevice.cpu : ComputeDevice.gpu,
            threads: 4,
            flashAttention: false,
            vaeDirectConvolution: false,
          ),
        );
        addTearDown(engine.dispose);
        final capabilities = await engine.capabilities;
        expect(capabilities.modelVersion, 'SDXS (512-DS)');
        expect(
          capabilities.backendName,
          device == 'cpu' ? equals('CPU') : startsWith('MTL'),
        );
        ImageGenerationRequest request(int mode, {int steps = 4}) =>
            SeamlessImageGenerationRequest(
              prompt: _prompt,
              width: 512,
              height: 512,
              steps: steps,
              guidanceScale: 1,
              seed: 42,
              sampler: ImageGenerationSampler.euler,
              scheduler: ImageGenerationScheduler.discrete,
              circularX: mode == 1 || mode == 3,
              circularY: mode == 2 || mode == 3,
            );
        final images = <GeneratedImage>[];
        final report = <Map<String, Object>>[];
        for (var mode = 0; mode < 5; mode++) {
          final image = (await engine.generateImage(
            request(mode),
          )).images.single;
          images.add(image);
          expect((image.width, image.height, image.channels), (512, 512, 3));
          expect(image.pixels.toSet().length, greaterThan(64));
          final record = <String, Object>{
            'mode': mode,
            'backend': capabilities.backendName!,
            'sha256': sha256.convert(image.pixels).toString(),
            'xSeamMae': _difference(image, horizontal: true, seam: true),
            'ySeamMae': _difference(image, horizontal: false, seam: true),
            'xInteriorMae': _difference(image, horizontal: true, seam: false),
            'yInteriorMae': _difference(image, horizontal: false, seam: false),
          };
          report.add(record);
          print('TEXTURE_PIXELS ${jsonEncode(record)}');
          if (references != null) {
            // Native C reference emits P6 RGB; comparing the suffix avoids
            // depending on its whitespace-only PPM header formatting.
            final reference = File(
              '$references/sdxs-$device-$mode.ppm',
            ).readAsBytesSync();
            expect(
              image.pixels,
              reference.sublist(reference.length - image.pixels.length),
              reason: 'Exact native settings parity, $device mode $mode',
            );
          }
          if (output != null) {
            Directory(output).createSync(recursive: true);
            File('$output/$device-$mode.png').writeAsBytesSync(image.toPng());
            File(
              '$output/$device-$mode-repeat.png',
            ).writeAsBytesSync(_repeat(image).toPng());
            File('$output/$device.json').writeAsStringSync(
              const JsonEncoder.withIndent('  ').convert(report),
            );
          }
        }
        for (final mode in [1, 2, 3]) {
          for (final horizontal in [true, false]) {
            if ((horizontal && mode == 2) || (!horizontal && mode == 1)) {
              continue;
            }
            final seam = _difference(
              images[mode],
              horizontal: horizontal,
              seam: true,
            );
            final interior = _difference(
              images[mode],
              horizontal: horizontal,
              seam: false,
            );
            final off = _difference(
              images[0],
              horizontal: horizontal,
              seam: true,
            );
            expect(
              seam,
              lessThan(8),
              reason: '$device mode $mode absolute seam',
            );
            expect(
              seam,
              lessThan(interior * 1.5),
              reason: '$device mode $mode seam versus interior',
            );
            expect(
              seam,
              lessThan(off * 0.4),
              reason: '$device mode $mode improvement versus off',
            );
          }
        }
        expect(images[4].pixels, images[0].pixels, reason: 'off after on');
        final cancelled = await engine.generate(request(3, steps: 20));
        var observedStep = false;
        await for (final event in cancelled.events) {
          if (event case ImageGenerationProgressEvent(
            phase: ImageGenerationPhase.sampling,
            :final step,
          ) when step > 0) {
            observedStep = true;
            cancelled.cancel();
          }
        }
        expect(observedStep, isTrue);
        expect(
          (await cancelled.done).state,
          ImageGenerationCompletionState.cancelled,
        );
        expect(
          (await engine.generateImage(request(0))).images.single.pixels,
          images[0].pixels,
          reason: 'ordinary reuse after circular cancellation',
        );
        expect(
          (await engine.generateImage(request(3))).images.single.pixels,
          images[3].pixels,
          reason: 'circular reuse after cancellation',
        );
      },
      skip: model == null ? 'Set LLAMADART_SDXS_MODEL' : false,
    );
  }
}

double _difference(
  GeneratedImage image, {
  required bool horizontal,
  required bool seam,
}) {
  var total = 0;
  var count = 0;
  final along = horizontal ? image.width : image.height;
  final across = horizontal ? image.height : image.width;
  int value(int a, int b, int channel) =>
      image.pixels[((horizontal ? b * image.width + a : a * image.width + b) *
              3) +
          channel];
  for (var b = 0; b < across; b++) {
    for (var a = seam ? along - 1 : 0; a < along - (seam ? 0 : 1); a++) {
      for (var channel = 0; channel < 3; channel++) {
        total += (value(a, b, channel) - value(seam ? 0 : a + 1, b, channel))
            .abs();
        count++;
      }
    }
  }
  return total / count;
}

GeneratedImage _repeat(GeneratedImage image) {
  final pixels = Uint8List(image.pixels.length * 4);
  for (var y = 0; y < image.height * 2; y++) {
    for (var x = 0; x < image.width * 2; x++) {
      final source = ((y % image.height) * image.width + x % image.width) * 3;
      final target = (y * image.width * 2 + x) * 3;
      pixels.setRange(target, target + 3, image.pixels, source);
    }
  }
  return GeneratedImage(
    width: image.width * 2,
    height: image.height * 2,
    channels: 3,
    pixels: pixels,
  );
}
