/// Private S24 LiteRT admission and evidence checks; never submits a device run.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'src/manifest.dart';
import 'src/s24_litert_capture.dart';

const s24LiteRtCpuHash =
    'c5f39b4191926786c3e6668b62af4d6eb15248dfc7a5348252a9b406f33f2108';
const s24LiteRtGpuHash =
    '555579ff2f4fd13379abe69c1c3ab5200f7338bc92471557f1d6614a6e5ab0b4';
const s24LiteRtLegacyGpuProfileAsset =
    'assets/fixtures/s24/chat-litert-gpu-legacy.json';
const s24LiteRtFallbackWarning =
    'LiteRT-LM could not create a GPU engine under ComputeDevice.auto; '
    'retrying on the CPU.';
const s24LiteRtNativeLibraries = {
  'libLiteRtLm.so',
  'libLiteRtGpuAccelerator.so',
  'libLiteRtOpenClAccelerator.so',
  'libLiteRtWebGpuAccelerator.so',
  'libGemmaModelConstraintProvider.so',
  'libwebgpu_dawn.so',
};

/// Owner runtime tags the S24 binding admits. `v0.19.1-2` changes only the
/// Android `libLiteRtLm.so` and passed the full S24 graph again
/// (Test Lab `matrix-wmalbq6nz437a`, #1830).
/// `v0.19.1-5` changes the Android `libLiteRtLm.so` again (it links the WebGPU
/// top-k sampler, #1998) and is admitted for its S24 requalification.
/// `v0.19.1-6` is admitted for S24 requalification of the recurrent-state fix (#672).
/// `v0.19.1-7` is admitted for S24 requalification of the GPU binding fix (#2134).
const s24LiteRtRuntimeTags = {
  'v0.19.1',
  'v0.19.1-1',
  'v0.19.1-2',
  'v0.19.1-3',
  'v0.19.1-4',
  'v0.19.1-5',
  'v0.19.1-6',
  'v0.19.1-7',
};

// Pin the exact Android archive for every tag, including rebuilds that share
// library bytes. The inventory digest hashes canonical JSON of basename to SHA-256.
const _s24LiteRtPublishedDigests =
    <String, ({String archive, String libraries})>{
      'v0.19.1': (
        archive:
            'abe6732029a99a5825dd644655eae18fb0e193f8af1bdf41f5c5ff5aa69650b9',
        libraries:
            '1b60e80533a1bb1dee19bac289de9006823660d176a3b1fba539a4e6c4a960a4',
      ),
      'v0.19.1-1': (
        archive:
            '0f719f12595963f9c3718b920c85be94c0813089e051e95326351d92356f2d21',
        libraries:
            '1b60e80533a1bb1dee19bac289de9006823660d176a3b1fba539a4e6c4a960a4',
      ),
      'v0.19.1-2': (
        archive:
            '1b72d7f6b144b3c7514e7c8a1573abf190e57dfc9808037302c113d1713c1bf5',
        libraries:
            'c21036e25fe26518ca48bf2199b1377c8cfdd75bdb1b92d486ee54536122e806',
      ),
      'v0.19.1-3': (
        archive:
            'c79e5d825537f0c914cefc6a94001cbb5aa55dab1d9f44aa4d76c61c86e1a069',
        libraries:
            'c21036e25fe26518ca48bf2199b1377c8cfdd75bdb1b92d486ee54536122e806',
      ),
      'v0.19.1-4': (
        archive:
            '1a75bcb89152db7659fdf565e45efac01ff3e486ecbd6e86971392a62ffacd6e',
        libraries:
            'c21036e25fe26518ca48bf2199b1377c8cfdd75bdb1b92d486ee54536122e806',
      ),
      'v0.19.1-5': (
        archive:
            '09da4ead66bfe95d32aefb890c5b45b10074c60545b99d6c10266d054d93e55f',
        libraries:
            'ae8452144db326698fac50d2c4da20411468b7715fd2d1eae9e73827cec8f50a',
      ),
      'v0.19.1-6': (
        archive:
            '2c1d9dfb62b02ef2a2c73f7bb4089f84a8c10363d8f2e36560263f62aa984fcb',
        libraries:
            'b36636e0b03c1bab7cf48b44bc601245d3cf3245135bbae561b4dc50fcea8a28',
      ),
      'v0.19.1-7': (
        archive:
            'ad437e55e0c2c56b0d76c4711923eca71b027bcdffee293b2b48ffe6de3a7d3a',
        libraries:
            '8ceef81c639c619a5638862b85bf88e8192937e2cf18f0e72c56a68ddfbf1a98',
      ),
    };

// These rebuilds retain byte-identical Android libraries (#1808, #1798, #1911).
const _s24LiteRtRuntimeAliases = {
  'v0.19.1-1': 'v0.19.1',
  'v0.19.1-3': 'v0.19.1-2',
  'v0.19.1-4': 'v0.19.1-2',
};

/// Fixed prospective stage caps sum to 1,050s; FTL still caps the run at 1,200s.
const s24LiteRtStageSeconds = {
  'staging-and-identity': 120,
  'native-guard': 120,
  'public-gpu-refusal': 60,
  'native-cpu-corrected': 120,
  'public-cpu-corrected': 150,
  'public-auto-legacy': 150,
  'native-gpu-corrected': 120,
  'public-auto-corrected': 150,
  'cleanup-and-export': 60,
};

final List<String> s24LiteRtCases = List.unmodifiable([
  's24.native.launch',
  's24.native.gpu-guard',
  'public.legacy.gpu-refusal',
  's24.native.cpu-corrected',
  for (final route in ['cpu-corrected', 'auto-legacy', 'auto-corrected']) ...[
    for (final lifetime in [1, 2]) ...[
      '$route.$lifetime.hello',
      '$route.$lifetime.arithmetic',
    ],
    '$route.cancel',
  ],
  's24.native.gpu-corrected',
]);

String s24LiteRtHash(Object? value) =>
    sha256.convert(utf8.encode(canonicalJson(value))).toString();

void _require(bool condition, String message) {
  if (!condition) throw FormatException(message);
}

void requireS24LiteRtProfile(Map<String, dynamic> value, String backend) {
  final profile = ValidationProfile.fromJson(value);
  _require(
    profile.id == 'chat-litert-$backend' &&
        value['runtime'] == 'litert' &&
        value['backend'] == backend &&
        value['context_size'] == 1024 &&
        value['threads'] == 4 &&
        value['max_tokens'] == 32,
    'S24 requires the unchanged maintained chat profile configuration',
  );
  final model = value['model'] as Map;
  final revision = backend == 'cpu'
      ? 'e6687177e00897731e7716267eebd4eba0dde7c2'
      : '8414150f2e9dcc82449bcc9c5abc404b399a4d06';
  _require(
    model['id'] == 'chat-litert' &&
        model['filename'] == 'Qwen3-0.6B.litertlm' &&
        model['kind'] == 'chat' &&
        model['revision'] == revision &&
        model['url'] ==
            'https://huggingface.co/litert-community/Qwen3-0.6B/resolve/$revision/Qwen3-0.6B.litertlm',
    'Model metadata must identify its own maintained CPU or GPU artifact',
  );

  _require(
    model['sha256'] ==
            (backend == 'cpu' ? s24LiteRtCpuHash : s24LiteRtGpuHash) &&
        model['bytes'] == (backend == 'cpu' ? 613722264 : 614236160),
    'S24 CPU and GPU artifacts must retain their separate model locks',
  );
  _require(
    canonicalJson(value['fixtures']) ==
        canonicalJson({
          'hello': {
            'prompt': 'Reply with one short sentence saying hello.',
            'regex': r'\bhello\b',
          },
          'arithmetic': {
            'prompt': 'What is 3 + 4? Reply with only the number.',
            'regex': r'^(?:3 \+ 4 = )?7[.!]?$',
          },
        }),
    'The maintained C04 prompts and semantic oracles cannot change',
  );
}

/// Validates a prospective final build binding, independently of run claims.
void requireS24LiteRtBinding(Map<String, dynamic> value) {
  final runtimeTag = value['runtime_tag'];
  final published = _s24LiteRtPublishedDigests[runtimeTag];
  _require(
    value['schema'] == 1 &&
        value['source_dirty'] == false &&
        s24LiteRtRuntimeTags.contains(
          _s24LiteRtRuntimeAliases[runtimeTag] ?? runtimeTag,
        ) &&
        published != null &&
        value['abi'] == 'android-arm64' &&
        value['test_class'] ==
            'com.example.llamadart_chat_example.S24LiteRtPublicTest' &&
        value['max_minutes'] == 20 &&
        value['execution_count'] == 1 &&
        value['reservation_usd'] == '2.50' &&
        value['shared_cap_usd'] == '22.50',
    'S24 admission requires one bounded run and the existing shared budget',
  );
  for (final key in ['source_commit', 'source_tree', 'owner_commit']) {
    _require(
      value[key] is String && RegExp(r'^[a-f0-9]{40}$').hasMatch(value[key]),
      'Missing exact source/owner revision: $key',
    );
  }
  _require(
    value['owner_commit'] != '7ea10d0cce10dfddbae273bb69e253d9ea97e1d2',
    'The aborted 7ea candidate is not the final rebuilt owner artifact',
  );
  for (final key in [
    'source_inventory_sha256',
    'runtime_archive_sha256',
    'runtime_manifest_sha256',
    'shared_budget_receipt_sha256',
    'template_sha256',
    'child_sha256',
  ]) {
    _require(
      value[key] is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(value[key]),
      'Missing admitted source/artifact/budget binding: $key',
    );
  }
  final inventory = value['libraries'];
  _require(inventory is Map, 'Missing installed native inventory');
  _require(
    (inventory as Map)['libllamadart_litert_child.so']?['sha256'] ==
        value['child_sha256'],
    'The owned child executable must be part of the APK inventory',
  );
  final profiles = value['profiles'];
  _require(profiles is Map, 'Missing maintained profiles');
  for (final backend in ['cpu', 'gpu']) {
    _require(
      (profiles as Map)[backend] is Map,
      'Missing maintained $backend profile',
    );
    requireS24LiteRtProfile(
      Map<String, dynamic>.from(profiles[backend] as Map),
      backend,
    );
  }
  _require(
    inventory.keys.toSet().containsAll(s24LiteRtNativeLibraries),
    'Incomplete Android owner runtime inventory',
  );
  _require(
    value['owner_libraries'] is Map &&
        canonicalJson(value['owner_libraries']) ==
            canonicalJson(value['archive_libraries']) &&
        (value['owner_libraries'] as Map).keys.toSet().containsAll(
          s24LiteRtNativeLibraries,
        ),
    'Owner libraries must match the complete admitted archive',
  );
  for (final entry in (value['owner_libraries'] as Map).entries) {
    _require(
      canonicalJson(inventory[entry.key]) == canonicalJson(entry.value),
      'APK owner payload differs from its archive',
    );
  }
  for (final entry in inventory.entries) {
    _require(
      entry.key is String &&
          RegExp(r'^lib[A-Za-z0-9_.+-]+\.so$').hasMatch(entry.key) &&
          entry.value is Map &&
          entry.value['bytes'] is int &&
          entry.value['bytes'] > 0 &&
          entry.value['sha256'] is String &&
          RegExp(r'^[a-f0-9]{64}$').hasMatch(entry.value['sha256']),
      'Invalid runtime library identity',
    );
  }
  _require(
    value['runtime_archive_sha256'] == published!.archive,
    'S24 runtime archive digest differs from the published tag',
  );
  final ownerLibraries = value['owner_libraries'] as Map;
  _require(
    s24LiteRtHash({
          for (final entry in ownerLibraries.entries)
            entry.key: entry.value['sha256'],
        }) ==
        published.libraries,
    'S24 owner library digests differ from the published tag',
  );
}

/// Grades copied public bytes only after the caller has persisted them.
void requireS24LiteRtAnswer(String name, List<int> bytes) {
  _require(
    const ['hello', 'arithmetic'].contains(name),
    'Unknown fixed C04 fixture',
  );
  final text = utf8.decode(bytes);
  _require(
    !text.contains('<think>') && !text.contains('</think>'),
    'Thinking delimiters escaped into the public answer',
  );
  final expression = name == 'hello'
      ? RegExp(r'\bhello\b', caseSensitive: false)
      : RegExp(r'^(?:3 \+ 4 = )?7[.!]?$');
  _require(expression.hasMatch(text.trim()), 'Fixed C04 $name oracle failed');
}

/// Minimum observable proof; public backend labels alone are not placement proof.
void requireS24LiteRtCpuObservation(
  Map<String, dynamic> value, {
  required bool automatic,
  required String lifetimeId,
}) {
  _require(
    value['backend_name'] == 'LiteRT-LM cpu' &&
        value['reported_gpu_layers'] == 0 &&
        value['native_finish'] == 'not_exposed_by_default_service' &&
        value['native_settlement'] == 'settled' &&
        value['input_tokens'] is int &&
        value['input_tokens'] > 0 &&
        value['output_tokens'] is int &&
        value['output_tokens'] > 0 &&
        value['mapped_core_verified'] == true,
    'CPU functionality lacks correlated native/provenance/lifecycle evidence',
  );
  List<int> captured(Map value) => decodeS24LiteRtCapture(value);

  final initialization = value['process_cpu_delegate_initialization'];
  final current = value['native_stderr'];
  _require(
    initialization is Map &&
        initialization['pid'] == value['public_process_pid'] &&
        current is Map &&
        current['lifetime_id'] == lifetimeId &&
        current['empty_at_load'] == true,
    'CPU initialization scope or fresh lifetime capture differs',
  );
  final processLog = utf8.decode(
    captured((initialization as Map)['capture'] as Map),
    allowMalformed: true,
  );
  final currentLog = utf8.decode(
    captured(current as Map),
    allowMalformed: true,
  );
  _require(
    processLog.contains('Created TensorFlow Lite XNNPACK delegate for CPU.') &&
        currentLog.contains(
          'Flatbuffer model initialized directly from incoming litert model.',
        ),
    'Need process-wide CPU initialization and fresh current-lifetime native compilation',
  );
  final warnings = value['warnings'];
  _require(warnings is List, 'Missing per-lifetime warning capture');
  final observed = (warnings as List).whereType<String>().any(
    (line) => line.contains(s24LiteRtFallbackWarning),
  );
  _require(
    observed == automatic,
    'Auto requires observed GPU failure then CPU recovery; explicit CPU must skip it',
  );
}
