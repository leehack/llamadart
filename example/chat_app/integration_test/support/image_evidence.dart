import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

const String imageEvidenceDirectoryName = 'image_generation_e2e';
const String imageEvidenceManifestName = 'image_evidence.json';
const _artifactNames = [
  'image_generation_e2e.png',
  'image_generation_screen.png',
];

/// Validates the non-interlaced 8-bit PNGs emitted by the image encoder/Skia.
/// Checks every chunk CRC, dimensions and decompressed scanline structure.
Map<String, int> inspectEvidencePng(Uint8List bytes) {
  const signature = [137, 80, 78, 71, 13, 10, 26, 10];
  if (bytes.length < 33 ||
      List.generate(8, (i) => bytes[i] != signature[i]).any((v) => v)) {
    throw const FormatException('Invalid PNG signature');
  }
  final data = ByteData.sublistView(bytes);
  var offset = 8;
  var width = 0;
  var height = 0;
  var channels = 0;
  var ended = false;
  final compressed = BytesBuilder(copy: false);
  while (offset + 12 <= bytes.length) {
    final length = data.getUint32(offset);
    final end = offset + 12 + length;
    if (end > bytes.length) throw const FormatException('Truncated PNG chunk');
    final type = ascii.decode(bytes.sublist(offset + 4, offset + 8));
    final crc = _crc32(bytes, offset + 4, offset + 8 + length);
    if (crc != data.getUint32(offset + 8 + length)) {
      throw const FormatException('Invalid PNG chunk CRC');
    }
    if (offset == 8 && type != 'IHDR') {
      throw const FormatException('PNG must start with IHDR');
    }
    if (type == 'IHDR') {
      if (width != 0 || length != 13) {
        throw const FormatException('Invalid PNG header');
      }
      width = data.getUint32(offset + 8);
      height = data.getUint32(offset + 12);
      channels = switch (bytes[offset + 17]) {
        0 => 1,
        2 => 3,
        4 => 2,
        6 => 4,
        _ => 0,
      };
      if (width < 1 ||
          height < 1 ||
          width > 4096 ||
          height > 4096 ||
          bytes[offset + 16] != 8 ||
          channels == 0 ||
          bytes[offset + 18] != 0 ||
          bytes[offset + 19] != 0 ||
          bytes[offset + 20] != 0) {
        throw const FormatException('Unsupported evidence PNG format');
      }
    } else if (type == 'IDAT') {
      compressed.add(bytes.sublist(offset + 8, offset + 8 + length));
    } else if (type == 'IEND') {
      if (length != 0 || end != bytes.length) {
        throw const FormatException('Invalid PNG end');
      }
      ended = true;
      break;
    } else if (bytes[offset + 4] & 0x20 == 0) {
      throw const FormatException('Unexpected critical PNG chunk');
    }
    offset = end;
  }
  if (!ended || compressed.length == 0) {
    throw const FormatException('Incomplete PNG');
  }
  final stride = width * channels + 1;
  final scanlines = _ScanlineSink(stride, height);
  final decoder = ZLibDecoder().startChunkedConversion(scanlines);
  decoder.add(compressed.takeBytes());
  decoder.close();
  return {'width': width, 'height': height};
}

class _ScanlineSink extends ByteConversionSink {
  _ScanlineSink(this.stride, this.height);
  final int stride;
  final int height;
  int count = 0;

  @override
  void add(List<int> chunk) {
    if (count + chunk.length > stride * height) {
      throw const FormatException('PNG pixel data exceeds dimensions');
    }
    for (
      var i = (stride - count % stride) % stride;
      i < chunk.length;
      i += stride
    ) {
      if (chunk[i] > 4) throw const FormatException('Invalid PNG row filter');
    }
    count += chunk.length;
  }

  @override
  void close() {
    if (count != stride * height) {
      throw const FormatException('PNG pixel data does not match dimensions');
    }
  }
}

final _crcTable = List<int>.generate(256, (n) {
  var value = n;
  for (var bit = 0; bit < 8; bit++) {
    value = value & 1 != 0 ? 0xedb88320 ^ (value >> 1) : value >> 1;
  }
  return value;
});

int _crc32(Uint8List bytes, int start, int end) {
  var crc = 0xffffffff;
  for (var i = start; i < end; i++) {
    crc = _crcTable[(crc ^ bytes[i]) & 0xff] ^ (crc >> 8);
  }
  return crc ^ 0xffffffff;
}

/// Writes both PNGs and a final receipt, then verifies the actual saved bytes.
/// A run has its own directory so an earlier capture cannot stand in for it.
Future<Map<String, dynamic>> writeImageEvidence({
  required Directory directory,
  required Uint8List generatedPng,
  required Uint8List screenPng,
  required Map<String, dynamic> metadata,
}) async {
  await directory.create(recursive: true);
  final receipt = File(p.join(directory.path, imageEvidenceManifestName));
  if (receipt.existsSync()) await receipt.delete();
  final artifacts = <String, dynamic>{};
  for (final entry in [generatedPng, screenPng].asMap().entries) {
    final dimensions = inspectEvidencePng(entry.value);
    final name = _artifactNames[entry.key];
    await File(
      p.join(directory.path, name),
    ).writeAsBytes(entry.value, flush: true);
    artifacts[name] = {
      'bytes': entry.value.length,
      'sha256': sha256.convert(entry.value).toString(),
      ...dimensions,
    };
  }
  final manifest = {
    ...metadata,
    'schema_version': 1,
    'scenario': 'image-generation-e2e',
    'artifacts': artifacts,
  };
  await receipt.writeAsString('${jsonEncode(manifest)}\n', flush: true);
  return verifyImageEvidence(directory);
}

/// Verifies captured bytes, with optional exact build/backend qualification.
/// PNG validation is structural; it does not judge image quality or GPU work.
Map<String, dynamic> verifyImageEvidence(
  Directory directory, {
  String? expectedCommit,
  String? expectedBackend,
  String? expectedRuntimeTag,
  Map<String, dynamic>? expectedModelLock,
}) {
  final manifest =
      jsonDecode(
            File(
              p.join(directory.path, imageEvidenceManifestName),
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  if (manifest['schema_version'] != 1 ||
      manifest['scenario'] != 'image-generation-e2e') {
    throw const FormatException('Invalid image evidence manifest');
  }
  if (expectedCommit != null &&
      (!RegExp(r'^[0-9a-f]{40}$').hasMatch(expectedCommit) ||
          manifest['source_commit'] != expectedCommit ||
          manifest['source_dirty'] != false)) {
    throw const FormatException(
      'Image evidence source does not match clean build',
    );
  }
  if (expectedBackend != null && manifest['backend'] != expectedBackend) {
    throw const FormatException('Image evidence backend mismatch');
  }
  if (expectedRuntimeTag != null &&
      manifest['runtime_tag'] != expectedRuntimeTag) {
    throw const FormatException('Image evidence runtime pin mismatch');
  }
  if (expectedModelLock != null) {
    final model = manifest['model_lock'];
    if (model is! Map ||
        expectedModelLock.entries.any(
          (entry) => model[entry.key] != entry.value,
        )) {
      throw const FormatException('Image evidence model/profile lock mismatch');
    }
  }
  if (manifest['seed'] != 42 ||
      manifest['width'] != 512 ||
      manifest['height'] != 512) {
    throw const FormatException('Image evidence seed/dimensions mismatch');
  }
  final artifacts = manifest['artifacts'] as Map<String, dynamic>;
  if (artifacts.length != 2 || !_artifactNames.every(artifacts.containsKey)) {
    throw const FormatException(
      'Image evidence requires generated PNG and screenshot',
    );
  }
  for (final name in _artifactNames) {
    final expected = artifacts[name] as Map<String, dynamic>;
    final file = File(p.join(directory.path, name));
    if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const FormatException(
        'Image evidence artifact missing or not a regular file',
      );
    }
    final bytes = file.readAsBytesSync();
    final dimensions = inspectEvidencePng(bytes);
    if (expected['bytes'] != bytes.length ||
        expected['sha256'] != sha256.convert(bytes).toString() ||
        expected['width'] != dimensions['width'] ||
        expected['height'] != dimensions['height'] ||
        name == _artifactNames.first &&
            (dimensions['width'] != 512 || dimensions['height'] != 512)) {
      throw const FormatException('Image evidence PNG identity mismatch');
    }
  }
  return manifest;
}
