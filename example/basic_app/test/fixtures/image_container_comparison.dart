import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:llamadart/llamadart.dart';
import 'package:test/test.dart';

/// Complete checkpoint controls for the existing container comparison case.
/// This reads tensor-only local inputs; it never executes Python pickle code.
Future<void> compareImageCheckpointContainers({
  required String modelSet,
  required String references,
  String? output,
}) async {
  final parsed = jsonDecode(File(modelSet).readAsStringSync());
  expect(parsed, isA<List<dynamic>>());
  final models = parsed as List<dynamic>;
  expect(models.length, greaterThanOrEqualTo(2));
  final records = <Map<String, Object>>[];
  Uint8List? baseline;
  for (final item in models) {
    final model = item as Map<String, dynamic>;
    final id = model['id'] as String;
    expect(id, matches(RegExp(r'^[a-z0-9_-]{1,32}$')));
    final file = File(model['path'] as String);
    final expectedHash = model['sha256'] as String;
    final actualHash = (await sha256.bind(file.openRead()).first).toString();
    expect(actualHash, expectedHash, reason: '$id checkpoint identity');
    for (final forced in model['auto'] == false ? [true] : [false, true]) {
      final clock = Stopwatch()..start();
      final engine = await ImageGenerationEngine.load(
        ImageGenerationModel(
          ModelSource.path(file.path),
          role: forced ? ImageModelRole.checkpoint : null,
        ),
        params: const ImageConditioningCacheParams(
          capacity: 0,
          device: ComputeDevice.cpu,
          threads: 4,
          flashAttention: false,
          vaeDirectConvolution: false,
        ),
      );
      try {
        final capabilities = await engine.capabilities;
        expect(capabilities.backendName, 'CPU');
        expect(capabilities.modelVersion, 'SD 2.x');
        expect(engine.roles.keys, [ImageModelRole.checkpoint]);
        final loadedMs = clock.elapsedMilliseconds;
        final image = (await engine.generateImage(
          const ImageGenerationRequest(
            prompt: 'a red fox in a green forest, watercolor painting',
            width: 128,
            height: 128,
            steps: 1,
            guidanceScale: 1,
            seed: 42,
            sampler: ImageGenerationSampler.euler,
            scheduler: ImageGenerationScheduler.discrete,
          ),
        )).images.single;
        expect((image.width, image.height, image.channels), (128, 128, 3));
        expect(image.pixels.toSet().length, greaterThan(64));
        if (baseline != null) {
          expect(image.pixels, baseline, reason: '$id container-only parity');
        }
        baseline ??= image.pixels;
        final reference = File('$references/$id.ppm').readAsBytesSync();
        expect(reference.length, greaterThan(image.pixels.length));
        expect(
          image.pixels,
          reference.sublist(reference.length - image.pixels.length),
          reason: '$id independent direct-C settings parity',
        );
        if (output != null) {
          Directory(output).createSync(recursive: true);
          File(
            '$output/$id-${forced ? 'explicit' : 'auto'}.png',
          ).writeAsBytesSync(image.toPng());
        }
        records.add({
          'id': id,
          'modelSha256': actualHash,
          'explicitRole': forced,
          'backend': capabilities.backendName!,
          'family': capabilities.modelVersion!,
          'loadMs': loadedMs,
          'generateMs': clock.elapsedMilliseconds - loadedMs,
          'rgbSha256': sha256.convert(image.pixels).toString(),
        });
      } finally {
        await engine.dispose();
      }
    }
  }
  print('IMAGE_CONTAINERS ${jsonEncode(records)}');
  if (output != null) {
    File('$output/results.json').writeAsStringSync(jsonEncode(records));
  }
}
