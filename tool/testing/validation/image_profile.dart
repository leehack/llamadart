import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

// The chat app owns the single model its image test downloads; profiles must
// lock exactly that file. Read it without the app's Flutter package resolver.
// ignore: avoid_relative_lib_imports
import '../../../example/chat_app/lib/models/image_model_profile.dart';
import '../../../example/chat_app/integration_test/support/image_evidence.dart';

/// The chat-app integration test an image-generation bundle compiles.
const imageGenerationTestTarget =
    'integration_test/image_generation_e2e_test.dart';

/// Where that test writes its evidence on Android (app external files).
const androidImageEvidenceDirectory =
    '/sdcard/Android/data/com.example.llamadart_chat_example/files/'
    '$imageEvidenceDirectoryName';

/// Where the shared validation test writes its journal on Android.
const androidValidationDirectory =
    '/sdcard/Android/data/com.example.llamadart_chat_example/files/validation';

/// Each image backend runs on one mobile target, and the test records the
/// device name the stable_diffusion runtime reports for it.
const _imageBackends = {
  'cpu': (target: 'android', device: 'CPU'),
  'metal': (target: 'ios', device: 'MTL0'),
};

/// Whether [profile] is an image-generation profile rather than a text one.
bool isImageGenerationProfile(Map<dynamic, dynamic> profile) =>
    profile['runtime'] == 'stable_diffusion';

/// The bundled profile file for [id]: text profiles live in `profiles/`,
/// image-generation profiles in `image_profiles/`, and an ID names one file.
File validationProfileFile(String package, String id) {
  final candidates = [
    for (final directory in ['profiles', 'image_profiles'])
      File(p.join(package, 'assets', directory, '$id.json')),
  ].where((file) => file.existsSync()).toList();
  if (candidates.length != 1) {
    throw FormatException(
      candidates.isEmpty
          ? 'Unknown validation profile: $id'
          : 'Validation profile $id exists as both a text and an image profile',
    );
  }
  return candidates.single;
}

/// The model lock of the chat app's SDXS profile, as the image test records
/// it in its evidence receipt, plus the download URL the profile pins.
Map<String, Object> sdxsModelLock() {
  const profile = ImageModelProfile.sdxs;
  final uri = Uri.parse(profile.modelSource.url);
  return {
    'id': profile.id,
    'revision': uri.pathSegments[uri.pathSegments.indexOf('resolve') + 1],
    'filename': profile.modelSource.filename,
    'sha256': profile.modelSource.sha256!,
    'bytes': profile.modelSource.sizeBytes!,
    'url': profile.modelSource.url,
  };
}

/// Rejects an image profile that is malformed, locks another model than the
/// one the test downloads, or is built for a target its backend cannot run on.
/// Keep this at both build and upload boundaries, like NPU kit checks.
void requireImageGenerationProfile(
  Map<dynamic, dynamic> profile,
  String target,
) {
  final model = profile['model'];
  final backend = _imageBackends[profile['backend']];
  final lock = sdxsModelLock();
  if (!isImageGenerationProfile(profile) ||
      profile['schema_version'] != 1 ||
      !RegExp(r'^[a-z][a-z0-9-]{0,63}$').hasMatch('${profile['id']}') ||
      !_sameKeys(profile, [
        'schema_version',
        'id',
        'runtime',
        'backend',
        'model',
        // The builder records the execution path in the bundled copy.
        if (profile.containsKey('execution_path')) 'execution_path',
      ]) ||
      (profile.containsKey('execution_path') &&
          profile['execution_path'] != 'public_api') ||
      model is! Map ||
      !_sameKeys(model, [...lock.keys, 'kind']) ||
      model['kind'] != 'image' ||
      lock.entries.any((entry) => model[entry.key] != entry.value)) {
    throw const FormatException(
      'Image-generation profiles lock the chat app SDXS model exactly: '
      'schema_version, id, runtime stable_diffusion, backend and a model '
      'with kind image',
    );
  }
  if (backend == null) {
    throw FormatException(
      'Image-generation backend ${profile['backend']} has no device route; '
      'use ${_imageBackends.keys.join(' or ')}',
    );
  }
  if (target != backend.target) {
    throw UnsupportedError(
      'Image-generation profile ${profile['id']} runs only in ${backend.target} '
      'bundles; the ${profile['backend']} backend is not routed on $target',
    );
  }
}

bool _sameKeys(Map<dynamic, dynamic> value, List<String> keys) =>
    value.length == keys.length && keys.every(value.containsKey);

/// The pinned stable_diffusion release tag at [root], which the image test
/// compiles in and records as its runtime tag.
String readStableDiffusionTag(String root) {
  final pins = File(
    p.join(root, 'lib/src/hook/native_release_pins.dart'),
  ).readAsStringSync();
  final tag = RegExp(
    "const stableDiffusionReleaseTag = '([^']+)'",
  ).firstMatch(pins)?.group(1);
  if (tag == null) throw StateError('Cannot establish the image runtime pin');
  return tag;
}

/// Grades one collected Firebase image-generation run with the maintained
/// image verifier and writes `report/image-verdict.json`. The evidence must
/// match the bundle exactly: clean source commit, the profile's backend
/// device, the bundle's runtime tag and model lock, seed 42, 512x512 and
/// structurally valid PNGs whose bytes match the receipt.
///
/// Android evidence is the pulled `image_generation_e2e/run-*` directory.
/// iOS evidence is the XCTest attachments the runner adds from the app's
/// cache directory, exported from `.xcresult` on macOS. Exactly one run's
/// files must be present; anything else does not verify.
bool gradeCollectedImageRun(
  Directory run,
  Map<dynamic, dynamic> profile,
  Map<dynamic, dynamic> bundle,
) {
  final report = Directory(p.join(run.path, 'report'))
    ..createSync(recursive: true);
  final verdict = File(p.join(report.path, 'image-verdict.json'));
  if (verdict.existsSync()) verdict.deleteSync();
  final model = profile['model'] as Map;
  final expected = <String, Object?>{
    'source_commit': bundle['source_commit'],
    'source_dirty': false,
    'backend': _imageBackends[profile['backend']]?.device,
    'runtime_tag': bundle['stable_diffusion_tag'],
    'model_lock': {
      for (final key in ['id', 'filename', 'sha256', 'bytes', 'revision'])
        key: model[key],
    },
  };
  String? reason;
  String? location;
  Map<String, dynamic>? evidence;
  try {
    if (bundle['source_dirty'] != false ||
        !RegExp(r'^[0-9a-f]{40}$').hasMatch('${bundle['source_commit']}') ||
        expected['backend'] == null ||
        expected['runtime_tag'] is! String) {
      throw const FormatException('Bundle lacks a clean image build identity');
    }
    final directory = _locateImageEvidence(run, report);
    location = p.relative(directory.path, from: run.path);
    evidence = verifyImageEvidence(
      directory,
      expectedCommit: expected['source_commit'] as String,
      expectedBackend: expected['backend'] as String,
      expectedRuntimeTag: expected['runtime_tag'] as String,
      expectedModelLock: Map<String, dynamic>.from(
        expected['model_lock'] as Map,
      ),
    );
  } on FormatException catch (error) {
    reason = error.message;
  } on Object catch (error) {
    // Like the verifier CLI: any malformed receipt fails closed, by type only.
    reason = 'Image evidence is unreadable or malformed (${error.runtimeType})';
  }
  verdict.writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert({
      'schema_version': 1,
      'kind': 'image_generation_e2e',
      'profile': profile['id'],
      'evidence_verified': reason == null,
      'reason': ?reason,
      'expected': expected,
      'evidence_directory': ?location,
      'evidence': ?evidence,
    }),
    flush: true,
  );
  return reason == null;
}

const _evidenceFiles = {
  imageEvidenceManifestName,
  'image_generation_e2e.png',
  'image_generation_screen.png',
};

/// Exported attachments are named `<stem>_<index>_<UUID>.<extension>`.
final _exportedAttachment = RegExp(
  r'^(.+)_\d+_[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}'
  r'(\.[a-z]+)$',
);

Directory _locateImageEvidence(Directory run, Directory report) {
  final pulled = [
    for (final file in Directory(
      p.join(run.path, 'remote-results'),
    ).listSync(recursive: true, followLinks: false).whereType<File>())
      if (p.basename(file.path) == imageEvidenceManifestName &&
          RegExp(
            '/files/$imageEvidenceDirectoryName/run-\\d+\$',
          ).hasMatch(p.dirname(file.path).replaceAll('\\', '/')))
        file.parent,
  ];
  final attached = <String, List<File>>{};
  for (final exported in run.listSync().whereType<Directory>().where(
    (d) => p.basename(d.path).startsWith('xctest-attachments-'),
  )) {
    final manifest = File(p.join(exported.path, 'manifest.json'));
    if (!manifest.existsSync()) continue;
    for (final test in jsonDecode(manifest.readAsStringSync()) as List) {
      for (final attachment in (test as Map)['attachments'] as List) {
        final match = _exportedAttachment.firstMatch(
          '${(attachment as Map)['suggestedHumanReadableName']}',
        );
        final name = match == null ? null : '${match[1]}${match[2]}';
        final file = File(
          p.join(
            exported.path,
            p.basename('${attachment['exportedFileName']}'),
          ),
        );
        if (name != null && _evidenceFiles.contains(name)) {
          (attached[name] ??= []).add(file);
        }
      }
    }
  }
  if (pulled.length + (attached.isEmpty ? 0 : 1) != 1) {
    throw FormatException(
      pulled.isEmpty && attached.isEmpty
          ? 'No image evidence was collected'
          : 'More than one image evidence run was collected',
    );
  }
  if (pulled.isNotEmpty) return pulled.single;
  if (attached.length != _evidenceFiles.length ||
      attached.values.any((files) => files.length != 1)) {
    throw const FormatException(
      'XCTest attachments do not hold exactly one image evidence run',
    );
  }
  final staged = Directory(p.join(report.path, 'image-evidence'));
  if (staged.existsSync()) staged.deleteSync(recursive: true);
  staged.createSync(recursive: true);
  for (final entry in attached.entries) {
    entry.value.single.copySync(p.join(staged.path, entry.key));
  }
  return staged;
}
