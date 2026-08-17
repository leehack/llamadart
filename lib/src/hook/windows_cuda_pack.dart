// ignore_for_file: public_member_api_docs

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

const int windowsCudaPackContractVersion = 3;

class WindowsCudaReleaseManifest {
  final String nativeTag;
  final String llamaCppTag;
  final String llamaCppCommit;
  final Map<String, String> assetDigests;

  const WindowsCudaReleaseManifest({
    required this.nativeTag,
    required this.llamaCppTag,
    required this.llamaCppCommit,
    required this.assetDigests,
  });

  factory WindowsCudaReleaseManifest.parse(String source) {
    final decoded = jsonDecode(source);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Native release manifest must be an object.');
    }
    final artifacts = decoded['artifacts'];
    if (artifacts is! List<Object?>) {
      throw const FormatException(
        'Native release manifest artifacts must be an array.',
      );
    }
    final digests = <String, String>{};
    for (final entry in artifacts) {
      if (entry is! Map<String, Object?>) {
        throw const FormatException('Native release artifact is invalid.');
      }
      final file = entry['file'];
      final sha256 = entry['sha256'];
      if (file is! String ||
          sha256 is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256)) {
        throw const FormatException(
          'Native release artifact name or SHA-256 is invalid.',
        );
      }
      if (digests.containsKey(file)) {
        throw FormatException('Duplicate native release artifact: $file.');
      }
      digests[file] = sha256;
    }

    final nativeTag = decoded['tag'];
    final llamaCppTag = decoded['llama_cpp_tag'];
    final llamaCppCommit = decoded['llama_cpp_commit'];
    if (nativeTag is! String ||
        llamaCppTag is! String ||
        llamaCppCommit is! String ||
        !RegExp(r'^[0-9a-f]{40}$').hasMatch(llamaCppCommit)) {
      throw const FormatException(
        'Native release provenance metadata is invalid.',
      );
    }
    return WindowsCudaReleaseManifest(
      nativeTag: nativeTag,
      llamaCppTag: llamaCppTag,
      llamaCppCommit: llamaCppCommit,
      assetDigests: Map.unmodifiable(digests),
    );
  }
}

class WindowsCudaPackManifest {
  final int cudaMajor;
  final String backendLibrary;
  final Map<String, ({String sha256, int size})> files;

  const WindowsCudaPackManifest({
    required this.cudaMajor,
    required this.backendLibrary,
    required this.files,
  });
}

Future<String> sha256File(File file) async {
  return sha256.bind(file.openRead()).first.then((digest) => digest.toString());
}

Future<WindowsCudaPackManifest> verifyWindowsCudaPackDirectory({
  required Directory directory,
  required int expectedCudaMajor,
  required WindowsCudaReleaseManifest release,
  required File coreLibrary,
}) async {
  final manifestFile = File(path.join(directory.path, 'cuda-pack.json'));
  if (!manifestFile.existsSync()) {
    throw const FormatException('CUDA sidecar is missing cuda-pack.json.');
  }
  final decoded = jsonDecode(await manifestFile.readAsString());
  if (decoded is! Map<String, Object?>) {
    throw const FormatException('CUDA sidecar manifest must be an object.');
  }
  if (decoded['contract_version'] != windowsCudaPackContractVersion) {
    throw FormatException(
      'Unsupported CUDA sidecar contract version: '
      '${decoded['contract_version']}.',
    );
  }
  if (decoded['native_release_tag'] != release.nativeTag ||
      decoded['llama_cpp_tag'] != release.llamaCppTag ||
      decoded['llama_cpp_commit'] != release.llamaCppCommit) {
    throw const FormatException(
      'CUDA sidecar provenance does not match the native release.',
    );
  }
  if (decoded['platform'] != 'windows' || decoded['arch'] != 'x64') {
    throw const FormatException('CUDA sidecar must target Windows x64.');
  }
  if (decoded['backend'] != 'cuda' ||
      decoded['cuda_major'] != expectedCudaMajor) {
    throw FormatException(
      'CUDA sidecar variant does not match CUDA $expectedCudaMajor.',
    );
  }

  final expectedBackend = 'ggml-cuda-$expectedCudaMajor.dll';
  if (decoded['backend_library'] != expectedBackend) {
    throw FormatException('CUDA sidecar backend must be $expectedBackend.');
  }
  final expectedCompatibility = expectedCudaMajor == 12
      ? const <String, Object?>{
          'minimum_compute_capability': 50,
          'minimum_driver_family': 525,
          'minimum_driver_api': 12000,
        }
      : const <String, Object?>{
          'minimum_compute_capability': 75,
          'minimum_driver_family': 580,
          'minimum_driver_api': 13000,
        };
  final compatibility = decoded['compatibility'];
  if (compatibility is! Map<String, Object?> ||
      compatibility.length != expectedCompatibility.length ||
      !expectedCompatibility.entries.every(
        (entry) => compatibility[entry.key] == entry.value,
      )) {
    throw FormatException(
      'CUDA $expectedCudaMajor compatibility metadata differs from the '
      'supported contract.',
    );
  }
  final coreCompatibility = decoded['core_compatibility'];
  if (coreCompatibility is! Map<String, Object?> ||
      coreCompatibility['library'] != 'ggml-base.dll' ||
      coreCompatibility['sha256'] != await sha256File(coreLibrary)) {
    throw const FormatException(
      'CUDA sidecar does not match the selected native core.',
    );
  }

  final expectedNames = <String>{
    expectedBackend,
    'cudart64_$expectedCudaMajor.dll',
    'cublas64_$expectedCudaMajor.dll',
    'cublasLt64_$expectedCudaMajor.dll',
  };
  final fileEntries = decoded['files'];
  if (fileEntries is! List<Object?>) {
    throw const FormatException('CUDA sidecar file manifest is invalid.');
  }
  final files = <String, ({String sha256, int size})>{};
  for (final entry in fileEntries) {
    if (entry is! Map<String, Object?> ||
        entry['name'] is! String ||
        entry['sha256'] is! String ||
        entry['size'] is! int) {
      throw const FormatException('CUDA sidecar file entry is invalid.');
    }
    final name = entry['name']! as String;
    final digest = entry['sha256']! as String;
    final size = entry['size']! as int;
    if (!expectedNames.contains(name) ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest) ||
        size < 0 ||
        files.containsKey(name)) {
      throw FormatException('CUDA sidecar file entry is invalid: $name.');
    }
    files[name] = (sha256: digest, size: size);
  }
  if (files.keys.toSet().difference(expectedNames).isNotEmpty ||
      expectedNames.difference(files.keys.toSet()).isNotEmpty) {
    throw const FormatException(
      'CUDA sidecar payload differs from the required dependency family.',
    );
  }

  final extractedEntities = directory.listSync(followLinks: false);
  if (extractedEntities.any(
    (entity) =>
        FileSystemEntity.typeSync(entity.path, followLinks: false) !=
        FileSystemEntityType.file,
  )) {
    throw const FormatException(
      'CUDA sidecar contains an unexpected directory or link.',
    );
  }
  final actualEntries = extractedEntities
      .map((entity) => path.basename(entity.path))
      .toSet();
  if (actualEntries.difference({
        ...expectedNames,
        'cuda-pack.json',
      }).isNotEmpty ||
      expectedNames.difference(actualEntries).isNotEmpty) {
    throw const FormatException(
      'CUDA sidecar contains missing or unexpected files.',
    );
  }
  for (final MapEntry(key: name, value: expected) in files.entries) {
    final file = File(path.join(directory.path, name));
    if (file.lengthSync() != expected.size ||
        await sha256File(file) != expected.sha256) {
      throw FormatException('CUDA sidecar payload digest differs: $name.');
    }
  }

  return WindowsCudaPackManifest(
    cudaMajor: expectedCudaMajor,
    backendLibrary: expectedBackend,
    files: Map.unmodifiable(files),
  );
}
