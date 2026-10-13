import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/src/core/image/png_encoder.dart';
import 'package:path/path.dart' as p;

import '../integration_test/support/image_evidence.dart';
import 'evidence_png_fixture.dart';

const _commit = 'dfc58e7998bd751a9084bfa36d9ab9a90ba6d963';
Uint8List _png(int width, int height, {int value = 0}) => encodePng(
  width: width,
  height: height,
  channels: 3,
  pixels: Uint8List.fromList(List.filled(width * height * 3, value)),
);
Matcher _rejects(String detail) => throwsA(
  isA<FormatException>().having((e) => e.message, 'message', contains(detail)),
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  setUp(
    () =>
        directory = Directory.systemTemp.createTempSync('image-evidence-test-'),
  );
  tearDown(() => directory.deleteSync(recursive: true));
  Future<Map<String, dynamic>> write() => writeImageEvidence(
    directory: directory,
    generatedPng: _png(512, 512, value: 17),
    screenPng: _png(800, 1400, value: 23),
    metadata: {
      'source_commit': _commit,
      'source_dirty': false,
      'backend': 'CPU',
      'seed': 42,
      'width': 512,
      'height': 512,
    },
  );
  void updateManifest(void Function(Map<String, dynamic>) update) {
    final file = File(p.join(directory.path, imageEvidenceManifestName));
    final manifest =
        jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    update(manifest);
    file.writeAsStringSync(jsonEncode(manifest));
  }

  test(
    'writes and rechecks both actual PNG identities and dimensions',
    () async {
      final result = await write();
      expect(result['artifacts'], hasLength(2));
      expect(
        verifyImageEvidence(
          directory,
          expectedCommit: _commit,
          expectedBackend: 'CPU',
        ),
        result,
      );
      final generated =
          (result['artifacts'] as Map)['image_generation_e2e.png'] as Map;
      expect(
        generated['sha256'],
        sha256.convert(_png(512, 512, value: 17)).toString(),
      );
      expect(generated['width'], 512);
      final screen =
          (result['artifacts'] as Map)['image_generation_screen.png'] as Map;
      expect(screen['width'], 800);
      expect(screen['height'], 1400);
    },
  );
  test('accepts a real Skia PNG screen capture', () async {
    final recorder = ui.PictureRecorder();
    ui.Canvas(
      recorder,
    ).drawPaint(ui.Paint()..color = const ui.Color(0xff123456));
    final picture = recorder.endRecording();
    final image = await picture.toImage(8, 12);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      expect(inspectEvidencePng(data!.buffer.asUint8List()), {
        'width': 8,
        'height': 12,
      });
    } finally {
      image.dispose();
      picture.dispose();
    }
  });
  test(
    'accepts a real Skia 16-bit PNG only when deep samples are allowed',
    () async {
      final samples = Float32List(8 * 12 * 4)..fillRange(0, 8 * 12 * 4, 0.5);
      final buffer = await ui.ImmutableBuffer.fromUint8List(
        samples.buffer.asUint8List(),
      );
      final descriptor = ui.ImageDescriptor.raw(
        buffer,
        width: 8,
        height: 12,
        pixelFormat: ui.PixelFormat.rgbaFloat32,
      );
      final codec = await descriptor.instantiateCodec();
      final image = (await codec.getNextFrame()).image;
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final png = data!.buffer.asUint8List();
        expect(png[24], 16);
        expect(inspectEvidencePng(png, allowSixteenBit: true), {
          'width': 8,
          'height': 12,
        });
        expect(
          () => inspectEvidencePng(png),
          _rejects('8x12, bit depth 16, colour type 6'),
        );
      } finally {
        image.dispose();
        codec.dispose();
        descriptor.dispose();
        buffer.dispose();
      }
    },
  );
  test('writes and rechecks a 16-bit screen capture', () async {
    final result = await writeImageEvidence(
      directory: directory,
      generatedPng: _png(512, 512),
      screenPng: evidencePngFixture(width: 800, height: 1400),
      metadata: {'seed': 42, 'width': 512, 'height': 512},
    );
    expect(verifyImageEvidence(directory), result);
    final screen =
        (result['artifacts'] as Map)['image_generation_screen.png'] as Map;
    expect(screen['width'], 800);
    expect(screen['height'], 1400);
  });
  test('rejects a 16-bit generated image and names the artifact', () async {
    await expectLater(
      writeImageEvidence(
        directory: directory,
        generatedPng: evidencePngFixture(width: 512, height: 512),
        screenPng: _png(8, 12),
        metadata: {'seed': 42, 'width': 512, 'height': 512},
      ),
      _rejects(
        'image_generation_e2e.png: Unsupported evidence PNG format: 512x512, '
        'bit depth 16, colour type 6, compression 0, filter 0, interlace 0',
      ),
    );
  });
  test('names an unsupported screen capture and its header', () async {
    await expectLater(
      writeImageEvidence(
        directory: directory,
        generatedPng: _png(512, 512),
        screenPng: evidencePngFixture(width: 8, height: 12, interlace: 1),
        metadata: {'seed': 42, 'width': 512, 'height': 512},
      ),
      _rejects(
        'image_generation_screen.png: Unsupported evidence PNG format: 8x12, '
        'bit depth 16, colour type 6, compression 0, filter 0, interlace 1',
      ),
    );
  });
  test('rejects malformed 16-bit PNGs', () {
    final png = evidencePngFixture(width: 8, height: 12);
    Map<String, int> inspect(Uint8List bytes) =>
        inspectEvidencePng(bytes, allowSixteenBit: true);
    expect(inspect(png), {'width': 8, 'height': 12});
    expect(
      () => inspect(evidencePngFixture(width: 8, height: 12, rowBytes: 8 * 4)),
      _rejects('does not match dimensions'),
    );
    expect(
      () => inspect(evidencePngFixture(width: 8, height: 12, rowBytes: 8 * 16)),
      _rejects('exceeds dimensions'),
    );
    expect(
      () => inspect(png.sublist(0, png.length - 12)),
      _rejects('Incomplete PNG'),
    );
    expect(
      () => inspect(Uint8List.fromList(png)..[png.length - 20] ^= 1),
      _rejects('Invalid PNG chunk CRC'),
    );
    for (final (bitDepth, colorType) in [(4, 0), (8, 3), (16, 3), (32, 6)]) {
      expect(
        () => inspect(
          evidencePngFixture(
            width: 8,
            height: 12,
            bitDepth: bitDepth,
            colorType: colorType,
          ),
        ),
        _rejects('bit depth $bitDepth, colour type $colorType'),
      );
    }
  });
  test('rejects a missing screenshot instead of log-only evidence', () async {
    await write();
    File(p.join(directory.path, 'image_generation_screen.png')).deleteSync();
    expect(() => verifyImageEvidence(directory), throwsFormatException);
  });
  test('rejects substituted valid pixels with the same dimensions', () async {
    await write();
    File(
      p.join(directory.path, 'image_generation_e2e.png'),
    ).writeAsBytesSync(_png(512, 512, value: 99));
    expect(() => verifyImageEvidence(directory), throwsFormatException);
  });
  test('rejects CRC corruption even when receipt hash is rewritten', () async {
    await write();
    final file = File(p.join(directory.path, 'image_generation_e2e.png'));
    final bytes = file.readAsBytesSync();
    bytes[29] ^= 1;
    file.writeAsBytesSync(bytes);
    updateManifest(
      (manifest) =>
          ((manifest['artifacts'] as Map)['image_generation_e2e.png']
              as Map)['sha256'] = sha256
              .convert(bytes)
              .toString(),
    );
    expect(() => verifyImageEvidence(directory), throwsFormatException);
  });
  test('rejects incomplete and trailing PNG bytes', () {
    final png = _png(2, 3);
    expect(
      () => inspectEvidencePng(png.sublist(0, png.length - 12)),
      throwsFormatException,
    );
    expect(
      () => inspectEvidencePng(Uint8List.fromList([...png, 0])),
      throwsFormatException,
    );
  });
  test(
    'rejects dirty, unknown or different source and wrong backend',
    () async {
      await write();
      expect(
        () => verifyImageEvidence(directory, expectedCommit: 'unknown'),
        throwsFormatException,
      );
      expect(
        () => verifyImageEvidence(directory, expectedCommit: '0' * 40),
        throwsFormatException,
      );
      expect(
        () => verifyImageEvidence(directory, expectedBackend: 'Vulkan'),
        throwsFormatException,
      );
      updateManifest((manifest) => manifest['source_dirty'] = true);
      expect(
        () => verifyImageEvidence(directory, expectedCommit: _commit),
        throwsFormatException,
      );
    },
  );
  test('rejects wrong seed, missing record and forged dimensions', () async {
    await write();
    updateManifest((manifest) => manifest['seed'] = 1);
    expect(() => verifyImageEvidence(directory), throwsFormatException);
    await write();
    updateManifest(
      (manifest) =>
          (manifest['artifacts'] as Map).remove('image_generation_screen.png'),
    );
    expect(() => verifyImageEvidence(directory), throwsFormatException);
    await write();
    updateManifest(
      (manifest) =>
          ((manifest['artifacts'] as Map)['image_generation_screen.png']
                  as Map)['height'] =
              1,
    );
    expect(() => verifyImageEvidence(directory), throwsFormatException);
  });

  test('rejects wrong declared runtime/model/profile identities', () async {
    await write();
    updateManifest((manifest) {
      manifest['runtime_tag'] = 'v0.2.0-3';
      manifest['model_lock'] = {'id': 'sdxs', 'sha256': 'a' * 64};
    });
    expect(
      () => verifyImageEvidence(directory, expectedRuntimeTag: 'v0.2.0-2'),
      throwsFormatException,
    );
    expect(
      () => verifyImageEvidence(
        directory,
        expectedModelLock: {'id': 'different', 'sha256': 'a' * 64},
      ),
      throwsFormatException,
    );
    expect(
      () => verifyImageEvidence(
        directory,
        expectedModelLock: {'id': 'sdxs', 'sha256': 'b' * 64},
      ),
      throwsFormatException,
    );
    expect(
      () => verifyImageEvidence(
        directory,
        expectedRuntimeTag: 'v0.2.0-3',
        expectedModelLock: {'id': 'sdxs', 'sha256': 'a' * 64},
      ),
      returnsNormally,
    );
  });

  test('rejects a missing generated PNG', () async {
    await write();
    File(p.join(directory.path, 'image_generation_e2e.png')).deleteSync();
    expect(() => verifyImageEvidence(directory), throwsFormatException);
  });
  test('failed export invalidates an earlier valid receipt', () async {
    await write();
    await expectLater(
      writeImageEvidence(
        directory: directory,
        generatedPng: _png(512, 512),
        screenPng: Uint8List.fromList([1, 2, 3]),
        metadata: {'seed': 42, 'width': 512, 'height': 512},
      ),
      throwsFormatException,
    );
    expect(
      File(p.join(directory.path, imageEvidenceManifestName)).existsSync(),
      false,
    );
  });
}
