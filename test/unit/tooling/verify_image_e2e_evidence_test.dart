@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:llamadart/src/core/image/png_encoder.dart';
import 'package:llamadart/src/hook/native_release_pins.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../../example/chat_app/integration_test/support/image_evidence.dart';
// Use the same maintained lock as the production verifier.
// ignore: avoid_relative_lib_imports
import '../../../example/chat_app/lib/models/image_model_profile.dart';

const _commit = 'dfc58e7998bd751a9084bfa36d9ab9a90ba6d963';

void main() {
  late Directory directory;
  setUp(
    () => directory = Directory.systemTemp.createTempSync('image-tool-test-'),
  );
  tearDown(() => directory.deleteSync(recursive: true));

  Uint8List png(int width, int height) => encodePng(
    width: width,
    height: height,
    channels: 3,
    pixels: Uint8List(width * height * 3),
  );
  Future<void> prepare() async {
    final profile = ImageModelProfile.sdxs;
    final uri = Uri.parse(profile.modelSource.url);
    await writeImageEvidence(
      directory: directory,
      generatedPng: png(512, 512),
      screenPng: png(8, 12),
      metadata: {
        'source_commit': _commit,
        'source_dirty': false,
        'backend': 'CPU',
        'runtime_tag': stableDiffusionReleaseTag,
        'model_lock': {
          'id': profile.id,
          'filename': profile.modelSource.filename,
          'sha256': profile.modelSource.sha256,
          'bytes': profile.modelSource.sizeBytes,
          'revision': uri.pathSegments[uri.pathSegments.indexOf('resolve') + 1],
        },
        'seed': 42,
        'width': 512,
        'height': 512,
      },
    );
  }

  Future<ProcessResult> run({
    String commit = _commit,
    String backend = 'CPU',
  }) => Process.run(Platform.resolvedExecutable, [
    '--packages=${p.absolute('.dart_tool/package_config.json')}',
    'tool/testing/verify_image_e2e_evidence.dart',
    directory.path,
    commit,
    backend,
  ]);
  void update(void Function(Map<String, dynamic>) change) {
    final file = File(p.join(directory.path, imageEvidenceManifestName));
    final data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    change(data);
    file.writeAsStringSync(jsonEncode(data));
  }

  test(
    'CLI verifies actual generated and screen PNGs with exact provenance',
    () async {
      await prepare();
      final result = await run();
      expect(result.exitCode, 0, reason: result.stderr.toString());
      expect((jsonDecode(result.stdout.toString()) as Map)['verified'], true);
    },
  );
  test(
    'CLI rejects wrong source instead of accepting PNG-only evidence',
    () async {
      await prepare();
      expect((await run(commit: '0' * 40)).exitCode, 1);
    },
  );
  test(
    'CLI rejects missing PNG, source/backend/runtime/model/profile skew',
    () async {
      for (final mutate in <void Function(Map<String, dynamic>)>[
        (data) => data['source_dirty'] = true,
        (data) => data['backend'] = 'Vulkan',
        (data) => data['runtime_tag'] = 'v0.2.0-2',
        (data) => (data['model_lock'] as Map)['sha256'] = '0' * 64,
        (data) => (data['model_lock'] as Map)['id'] = 'different-model',
        (data) =>
            ((data['artifacts'] as Map)['image_generation_e2e.png']
                    as Map)['width'] =
                1,
      ]) {
        await prepare();
        update(mutate);
        expect((await run()).exitCode, 1);
      }
      await prepare();
      File(p.join(directory.path, 'image_generation_screen.png')).deleteSync();
      expect((await run()).exitCode, 1);
    },
  );
  test(
    'CLI rejects truncated PNG even with recomputed manifest identity',
    () async {
      await prepare();
      final file = File(p.join(directory.path, 'image_generation_e2e.png'));
      final bytes = file.readAsBytesSync();
      file.writeAsBytesSync(bytes.sublist(0, bytes.length - 12));
      update((data) {
        final artifact =
            (data['artifacts'] as Map)['image_generation_e2e.png'] as Map;
        artifact['bytes'] = file.lengthSync();
        // Keep the provided byte identity internally consistent: PNG parsing must reject it.
        artifact['sha256'] = sha256.convert(file.readAsBytesSync()).toString();
      });
      expect((await run()).exitCode, 1);
    },
  );
}
