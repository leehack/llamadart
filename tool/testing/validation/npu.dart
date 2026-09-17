import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// The native release and its actual LiteRT dependency, not the LiteRT-LM tag.
const npuRuntimeTag = '0.17.0-3';
const npuLiteRtRevision = '9fe5be45564c868408e6514c8aabb83e211a0911';
const npuDispatchHeaderHash =
    '11dd4d98bd084157ac987b1ee1951f3f96e2b3ca6b51a27c10e645686bf0e3ee';

/// Rejects dispatch until the installed-app adapter and native proof exist.
/// Keep this at both build and upload boundaries: old/custom bundles can bypass
/// the builder, and spending a Firebase execution cannot repair missing inputs.
void requireExecutableValidationProfile(Map<dynamic, dynamic> profile) {
  if (profile['backend'] == 'npu') {
    throw StateError(
      'NPU qualification is not executable yet: installed-app vendor packaging, '
      'SoC preflight and per-generation native execution proof are required. '
      'Run validation.dart npu-preflight for the locked input inventory.',
    );
  }
}

/// Audits local inputs without network access, executing libraries or dispatching.
/// A successful input check is deliberately separate from hardware qualification.
Future<Map<String, dynamic>> inspectNpuInputs(
  String root,
  String profileId, {
  String? modelPath,
  String? kitPath,
}) async {
  if (!const ['npu-qualcomm-sm8650', 'npu-tensor-g5'].contains(profileId)) {
    throw const FormatException('Select a locked NPU profile');
  }
  final profile =
      jsonDecode(
            File(
              p.join(
                root,
                'packages/llamadart_validation/assets/profiles',
                '$profileId.json',
              ),
            ).readAsStringSync(),
          )
          as Map<String, dynamic>;
  final target = profile['npu_target'] as Map<String, dynamic>;
  final model = profile['model'] as Map<String, dynamic>;
  final checks = <Map<String, dynamic>>[];
  void check(String id, bool pass, String reason) => checks.add({
    'id': id,
    'status': pass ? 'PASS' : 'NOT_RUN',
    'reason': reason,
  });
  final hook = File(p.join(root, 'hook/build.dart')).readAsStringSync();
  final tag = RegExp(
    r"const _litertLmVersion = '([^']+)'",
  ).firstMatch(hook)?.group(1);
  check(
    'runtime_pin',
    tag == npuRuntimeTag,
    tag == npuRuntimeTag
        ? 'Runtime matches the audited LiteRT dependency'
        : 'Runtime pin changed; resolve and audit its LiteRT dependency again',
  );
  check(
    'model',
    modelPath != null && await _matches(File(modelPath), model),
    'A locally supplied model must match the locked size and SHA256; '
        'no download credentials are read or exported',
  );
  Map<String, dynamic>? kit;
  if (kitPath != null) {
    final file = File(p.join(kitPath, 'npu-kit.json'));
    if (file.existsSync()) {
      kit = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    }
  }
  final identityMatches =
      kit?['schema_version'] == 1 &&
      kit?['target'] == target['soc'] &&
      kit?['runtime_tag'] == npuRuntimeTag &&
      kit?['litert_revision'] == npuLiteRtRevision &&
      kit?['dispatch_header_sha256'] == npuDispatchHeaderHash;
  check(
    'kit_identity',
    identityMatches,
    'Kit must bind the compiled SoC, runtime tag and exact LiteRT source/header; '
        'matching an API version string alone is insufficient',
  );
  final inventory = kit?['libraries'];
  final libraries = inventory is Map ? inventory : const {};
  final required = (target['libraries'] as Map).cast<String, dynamic>();
  final onDisk = kitPath != null && Directory(kitPath).existsSync()
      ? Directory(kitPath)
            .listSync(followLinks: false)
            .map((entry) => p.basename(entry.path))
            .where((name) => name.endsWith('.so'))
            .toSet()
      : <String>{};
  check(
    'kit_library_inventory',
    libraries.length == required.length &&
        required.keys.every(libraries.containsKey) &&
        onDisk.length == required.length &&
        required.keys.every(onDisk.contains),
    'Kit inventory and on-disk shared libraries must exactly match the target lock',
  );
  final libraryEvidence = <String, dynamic>{};
  for (final entry in required.entries) {
    final name = entry.key;
    // Names come only from the checked-in target lock, never an external kit.
    if (p.basename(name) != name || !name.endsWith('.so')) {
      throw const FormatException('Invalid locked library basename');
    }
    final lock = entry.value as Map;
    final declaration = libraries[name];
    final file = kitPath == null ? null : File(p.join(kitPath, name));
    final declared =
        declaration is Map &&
        RegExp(r'^[a-f0-9]{64}$').hasMatch(
          declaration['sha256'] is String ? declaration['sha256'] : '',
        ) &&
        declaration['bytes'] is int &&
        declaration['bytes'] > 0;
    final matches =
        file != null &&
        declared &&
        await _matches(file, declaration) &&
        (lock['sha256'] == null || declaration['sha256'] == lock['sha256']);
    var elfMatches = false;
    if (matches) {
      final handle = await file.open();
      try {
        final header = await handle.read(20);
        elfMatches =
            header.length == 20 &&
            header[0] == 0x7f &&
            header[1] == 0x45 &&
            header[2] == 0x4c &&
            header[3] == 0x46 &&
            header[4] == lock['elf_class'] &&
            header[5] == 1 &&
            (header[18] | header[19] << 8) == lock['elf_machine'];
      } finally {
        await handle.close();
      }
    }
    check(
      'library:$name',
      identityMatches && matches && elfMatches,
      'Require kit identity, file hash/size and the expected ELF architecture',
    );
    if (matches && elfMatches) {
      libraryEvidence[name] = {
        'sha256': declaration['sha256'],
        'bytes': declaration['bytes'],
        'elf_machine': lock['elf_machine'],
      };
    }
  }
  return {
    'schema_version': 1,
    'profile': profileId,
    'profile_sha256': sha256
        .convert(utf8.encode(jsonEncode(profile)))
        .toString(),
    'target': target['soc'],
    'model': model,
    'runtime_tag': tag,
    'litert_revision': npuLiteRtRevision,
    'dispatch_header_sha256': npuDispatchHeaderHash,
    'checks': checks,
    'libraries': libraryEvidence,
    'inputs_verified': checks.every((check) => check['status'] == 'PASS'),
    'status': 'NOT_RUN',
    'dispatch_allowed': false,
    'qualified': false,
    'remaining': [
      'Inspect final APK dependencies, licenses and sandbox-accessible model delivery',
      'Check on-device Build.SOC_MODEL, ABI and API level before native load',
      'Implement installed-app direct-native reference and public Dart NPU paths',
      'Require per-generation completed NPU execution evidence; selector and async submission do not qualify',
    ],
  };
}

Future<bool> _matches(File file, Map lock) async {
  // Reject symbolic links so the audit only covers regular kit files.
  if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
          FileSystemEntityType.file ||
      await file.length() != lock['bytes']) {
    return false;
  }
  return (await sha256.bind(file.openRead()).first).toString() ==
      lock['sha256'];
}
