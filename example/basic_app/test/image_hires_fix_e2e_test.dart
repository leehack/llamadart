@Tags(['local-only'])
@Timeout(Duration(minutes: 40))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:llamadart/llamadart.dart';
import 'package:test/test.dart';

const _prompt = 'a red fox sitting in a snowy forest, photograph';
const _negative = 'blurry';

/// Steps, guidance, hires steps and strength of each recipe; matches
/// `fixtures/image_hires_fix_native_reference.cpp`.
const _recipes = {
  'sd15': (
    family: 'SD 1.x',
    steps: 12,
    cfg: 7.0,
    hiresSteps: 8,
    strength: 0.55,
  ),
  'turbo': (family: 'SD 2.x', steps: 2, cfg: 1.0, hiresSteps: 2, strength: 0.5),
};

void main() {
  final environment = Platform.environment;
  final model = environment['LLAMADART_HIRES_MODEL'];
  final recipeName = environment['LLAMADART_HIRES_RECIPE'] ?? 'sd15';
  final deviceName = environment['LLAMADART_HIRES_DEVICE'] ?? 'cpu';
  final output = environment['LLAMADART_IMAGE_OUTPUT_DIR'];
  final references = environment['LLAMADART_HIRES_NATIVE_REFERENCES'];
  final recipe = _recipes[recipeName];
  test(
    'hires fix $recipeName on $deviceName: direct-C parity, one-pass reset, '
    'composition, latency, second-pass cancellation and reload',
    () async {
      final device = deviceName == 'gpu'
          ? ComputeDevice.gpu
          : ComputeDevice.cpu;
      ImageGenerationRequest ordinary(int size) => ImageGenerationRequest(
        prompt: _prompt,
        negativePrompt: _negative,
        width: size,
        height: size,
        steps: recipe!.steps,
        guidanceScale: recipe.cfg,
        seed: 42,
        sampler: ImageGenerationSampler.euler,
        scheduler: ImageGenerationScheduler.discrete,
      );
      HiresFixImageGenerationRequest hires(ImageHiresFix hiresFix) =>
          HiresFixImageGenerationRequest(
            prompt: _prompt,
            negativePrompt: _negative,
            width: 512,
            height: 512,
            steps: recipe!.steps,
            guidanceScale: recipe.cfg,
            seed: 42,
            sampler: ImageGenerationSampler.euler,
            scheduler: ImageGenerationScheduler.discrete,
            hiresFix: hiresFix,
          );
      final scaled = hires(
        ImageHiresFix.scale(
          1.5,
          steps: recipe!.hiresSteps,
          denoisingStrength: recipe.strength,
        ),
      );
      final sized = hires(
        ImageHiresFix.size(
          width: 768,
          height: 768,
          steps: recipe.hiresSteps,
          denoisingStrength: recipe.strength,
        ),
      );
      Future<ImageGenerationEngine> load() => ImageGenerationEngine.load(
        ImageGenerationModel(ModelSource.path(model!)),
        params: ImageModelParams(
          device: device,
          flashAttention: false,
          vaeDirectConvolution: false,
        ),
      );

      final engine = await load();
      addTearDown(engine.dispose);
      final capabilities = await engine.capabilities;
      expect(capabilities.modelVersion, recipe.family);
      expect(capabilities.supportsHiresFix, isTrue);
      expect(
        capabilities.backendName,
        device == ComputeDevice.cpu ? 'CPU' : startsWith('MTL'),
      );

      final records = <String, Object>{};
      final elapsed = <String, int>{};
      Future<GeneratedImage> run(
        String name,
        ImageGenerationRequest request,
      ) async {
        final task = await engine.generate(request);
        final events = await task.events.toList();
        final result = await task.result;
        final image = result.images.single;
        elapsed[name] = result.elapsed.inMilliseconds;
        records[name] = {
          'size': '${image.width}x${image.height}',
          'sha256': sha256.convert(image.pixels).toString(),
          'elapsedMs': result.elapsed.inMilliseconds,
          'samplingTotals': [
            for (final event
                in events.whereType<ImageGenerationProgressEvent>())
              if (event.phase == ImageGenerationPhase.sampling &&
                  event.step == event.steps)
                'pass ${event.pass}/${event.passCount}: ${event.steps}',
          ],
        };
        if (output != null) {
          File('$output/$name.png').writeAsBytesSync(image.toPng());
        }
        final reference = switch (name) {
          'base' || 'final' || 'hires' => '$recipeName-$deviceName-$name.ppm',
          _ => null,
        };
        if (references != null && reference != null) {
          final bytes = File('$references/$reference').readAsBytesSync();
          expect(
            image.pixels,
            bytes.sublist(bytes.length - image.pixels.length),
            reason: 'Independent direct-C parity $name',
          );
        }
        return image;
      }

      if (output != null) Directory(output).createSync(recursive: true);
      final base = await run('base', ordinary(512));
      expect((base.width, base.height), (512, 512));
      final oneFinal = await run('final', ordinary(768));
      final refined = await run('hires', scaled);
      expect((refined.width, refined.height, refined.channels), (768, 768, 3));
      expect(refined.pixels.toSet().length, greaterThan(64));
      final totals = records['hires']! as Map<String, Object>;
      expect(
        (totals['samplingTotals']! as List).first,
        'pass 0/2: ${recipe.steps}',
      );
      expect(
        (totals['samplingTotals']! as List).last,
        startsWith('pass 1/2: '),
      );
      final bySize = await run('hires-size', sized);
      expect(bySize.pixels, refined.pixels, reason: 'size and scale agree');
      final reset = await run('reset', ordinary(512));
      expect(reset.pixels, base.pixels, reason: 'ordinary after hires');

      // Fixed before qualification, not tuned to observed outputs.
      final upscaledBase = _resize(base, 768);
      final refineMae = _mae(refined.pixels, upscaledBase.pixels);
      expect(refineMae, greaterThan(1), reason: 'the second pass refines');
      final keptMae = _mae(_resize(refined, 512).pixels, base.pixels);
      final independentMae = _mae(_resize(oneFinal, 512).pixels, base.pixels);
      expect(
        keptMae,
        lessThan(independentMae),
        reason: 'the refinement keeps the first-pass composition',
      );

      final task = await engine.generate(scaled);
      var cancelledInSecondPass = false;
      await for (final event in task.events) {
        if (event case ImageGenerationProgressEvent(
          phase: ImageGenerationPhase.sampling,
          pass: 1,
          :final step,
        ) when step > 0 && !cancelledInSecondPass) {
          cancelledInSecondPass = true;
          task.cancel();
        }
      }
      expect(cancelledInSecondPass, isTrue);
      expect((await task.done).state, ImageGenerationCompletionState.cancelled);
      expect(
        (await engine.generateImage(scaled)).images.single.pixels,
        refined.pixels,
        reason: 'reuse after a second-pass cancel',
      );
      await engine.dispose();
      expect((await engine.capabilities).supportsHiresFix, isFalse);
      final reloaded = await load();
      try {
        expect((await reloaded.capabilities).supportsHiresFix, isTrue);
        expect(
          (await reloaded.generateImage(scaled)).images.single.pixels,
          refined.pixels,
          reason: 'reload',
        );
      } finally {
        await reloaded.dispose();
      }

      final metrics = {
        'recipe': recipeName,
        'device': deviceName,
        'backend': capabilities.backendName,
        'runtime': capabilities.runtimeVersion,
        'family': capabilities.modelVersion,
        'hiresVsUpscaledBaseMae': refineMae,
        'downscaledHiresVsBaseMae': keptMae,
        'downscaledOnePassFinalVsBaseMae': independentMae,
        'elapsedMs': elapsed,
        'maxRssBytes': ProcessInfo.maxRss,
        'images': records,
      };
      print('HIRES_FIX_METRICS ${jsonEncode(metrics)}');
      if (output != null) {
        File('$output/results.json').writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(metrics),
        );
      }
    },
    skip: !Platform.isMacOS
        ? 'The bounded recipe is macOS CPU or Metal'
        : model == null
        ? 'Set LLAMADART_HIRES_MODEL'
        : recipe == null
        ? 'LLAMADART_HIRES_RECIPE must be sd15 or turbo'
        : false,
  );
}

double _mae(Uint8List a, Uint8List b) {
  var sum = 0;
  for (var i = 0; i < a.length; i++) {
    sum += (a[i] - b[i]).abs();
  }
  return sum / a.length;
}

/// Bilinear resize of a square RGB [image] to [size], sampling pixel centres.
GeneratedImage _resize(GeneratedImage image, int size) {
  final source = image.width;
  final pixels = Uint8List(size * size * 3);
  for (var y = 0; y < size; y++) {
    final sy = ((y + 0.5) * source / size - 0.5).clamp(0, source - 1.0);
    final y0 = sy.floor();
    final y1 = (y0 + 1).clamp(0, source - 1);
    final fy = sy - y0;
    for (var x = 0; x < size; x++) {
      final sx = ((x + 0.5) * source / size - 0.5).clamp(0, source - 1.0);
      final x0 = sx.floor();
      final x1 = (x0 + 1).clamp(0, source - 1);
      final fx = sx - x0;
      for (var c = 0; c < 3; c++) {
        double at(int px, int py) =>
            image.pixels[(py * source + px) * 3 + c].toDouble();
        final top = at(x0, y0) * (1 - fx) + at(x1, y0) * fx;
        final bottom = at(x0, y1) * (1 - fx) + at(x1, y1) * fx;
        pixels[(y * size + x) * 3 + c] = (top * (1 - fy) + bottom * fy).round();
      }
    }
  }
  return GeneratedImage(width: size, height: size, channels: 3, pixels: pixels);
}
