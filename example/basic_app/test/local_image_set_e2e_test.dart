@Tags(['local-only'])
@Timeout(Duration(minutes: 15))
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:llamadart/llamadart.dart';
import 'package:test/test.dart';

const _params = ImageConditioningCacheParams(
  capacity: 0,
  device: ComputeDevice.cpu,
  threads: 4,
  flashAttention: false,
  vaeDirectConvolution: false,
);
const _request = ImageGenerationRequest(
  prompt: 'a red fox in a green forest, watercolor painting',
  width: 128,
  height: 128,
  steps: 1,
  guidanceScale: 1,
  seed: 42,
  sampler: ImageGenerationSampler.euler,
  scheduler: ImageGenerationScheduler.discrete,
);
void main() {
  final fixture = Platform.environment['LLAMADART_LOCAL_SET_FIXTURES'];
  final output = Platform.environment['LLAMADART_IMAGE_OUTPUT_DIR'];
  final reference = Platform.environment['LLAMADART_LOCAL_SET_REFERENCE'];
  test(
    'owned directory/index snapshots match C and survive source removal, cancel and reload',
    () async {
      final directory = Directory(fixture!);
      final receipt =
          jsonDecode(File('$fixture/fixture.json').readAsStringSync()) as Map;
      expect(receipt['marker'], 'llamadart-local-checkpoint-fixture-v1');
      final identities = {
        for (final record in receipt['files'] as List)
          record['name'] as String: record['sha256'] as String,
      };
      final expectedBytes = (receipt['files'] as List).fold<int>(
        0,
        (a, b) => a + (b['bytes'] as int),
      );
      final root = Directory(output!);
      await root.create(recursive: true);
      final cache = '${root.path}/cache';
      ImageGenerationModel model(String path, {String? cachePath}) =>
          ImageGenerationModel.localSafetensorsSet(
            path,
            sha256: identities,
            cacheDirectory: cachePath ?? cache,
          );
      final events = <ModelDownloadProgress>[];
      final first = await ImageGenerationEngine.load(
        model(directory.path),
        params: _params,
        onProgress: events.add,
      );
      addTearDown(first.dispose);
      final records = <Map<String, Object?>>[];
      Future<void> compare(ImageGenerationEngine engine, String name) async {
        final caps = await engine.capabilities;
        expect(caps.backendName, 'CPU');
        expect(caps.modelVersion, 'SD 2.x');
        expect(caps.supportsLocalSafetensorsSets, isTrue);
        final image = (await engine.generateImage(_request)).images.single;
        expect((image.width, image.height, image.channels), (128, 128, 3));
        final hash = sha256.convert(image.pixels).toString();
        expect(
          hash,
          'f08a13f24bbe3fee369616e1d2308468dacbcd78af3c09162ddd46405f532ec6',
        );
        if (reference != null) {
          final raw = File(reference).readAsBytesSync();
          expect(image.pixels, raw.sublist(raw.length - image.pixels.length));
        }
        await File('${root.path}/$name.png').writeAsBytes(image.toPng());
        records.add({
          'case': name,
          'rawPixelSha256': hash,
          'managedCapability': caps.supportsLocalSafetensorsSets,
        });
      }

      await compare(first, 'directory');
      expect(events.last.receivedBytes, expectedBytes);
      expect(events.last.totalBytes, expectedBytes);
      await expectLater(
        first.generateImage(
          const TiledImageGenerationRequest(
            prompt: 'x',
            vaeTiling: ImageVaeTiling(),
          ),
        ),
        throwsA(isA<LlamaUnsupportedException>()),
      );
      await expectLater(
        first.generateImage(
          const SeamlessImageGenerationRequest(
            prompt: 'x',
            width: 128,
            height: 128,
            steps: 1,
            guidanceScale: 1,
            seed: 42,
            circularX: true,
          ),
        ),
        throwsA(isA<LlamaUnsupportedException>()),
      );
      // These are only the script-created owned fixtures, never the user's source checkpoint.
      final held = '${directory.path}-held';
      await directory.rename(held);
      try {
        await compare(first, 'source-removed');
        await first.dispose();
        expect(
          (await first.capabilities).supportsLocalSafetensorsSets,
          isFalse,
        );
        final reloaded = await ImageGenerationEngine.load(
          model('${directory.path}/model.safetensors.index.json'),
          params: _params,
        );
        try {
          await compare(reloaded, 'index-cache-reload');
        } finally {
          await reloaded.dispose();
        }
      } finally {
        await Directory(held).rename(directory.path);
      }
      final token = ModelDownloadCancelToken();
      final cancelCache = '${root.path}/cancel-cache';
      await expectLater(
        ImageGenerationEngine.load(
          model(directory.path, cachePath: cancelCache),
          params: _params,
          download: ModelLoadOptions(cancelToken: token),
          onProgress: (_) => token.cancel(),
        ),
        throwsA(isA<LlamaStateException>()),
      );
      expect(
        await Directory('$cancelCache/llamadart_image_sets_v1').list().toList(),
        isEmpty,
      );
      final recovered = await ImageGenerationEngine.load(
        model(directory.path),
        params: _params,
      );
      try {
        await compare(recovered, 'after-cancel-recovery');
      } finally {
        await recovered.dispose();
      }
      final report = {
        'expectedAggregateBytes': expectedBytes,
        'lastProgress': {
          'received': events.last.receivedBytes,
          'total': events.last.totalBytes,
        },
        'cacheSurvivedSourceRemoval': true,
        'cancelledStagingRemoved': true,
        'images': records,
      };
      await File(
        '${root.path}/results.json',
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(report));
      print('LOCAL_SET_RESULTS ${jsonEncode(report)}');
    },
    skip: !Platform.isMacOS
        ? 'Bounded recipe is macOS CPU'
        : fixture == null || output == null
        ? 'Run image-local-checkpoint-sets with the fixture builder'
        : false,
  );
}
