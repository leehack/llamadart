import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'case_catalog.dart';
import 'decision_catalog.dart';
import 'manifest.dart';
import 'npu_evidence.dart';

/// Conservative GGUF native-log evidence. A selector or device inventory alone
/// is insufficient: every expected load needs positive offload and compute allocation.
Map<String, dynamic> inspectPlacement(
  Map<String, dynamic> manifest,
  List<Map<String, dynamic>> cases,
  String? log,
) {
  final profile = manifest['profile'] is Map
      ? manifest['profile'] as Map
      : const {};
  final backend = profile['backend'];
  // The selector determines the obligation; a journal flag cannot waive it.
  final required = !['cpu', 'auto', 'blas'].contains(backend);
  if (!required) {
    return {'required': false, 'verified': true, 'reason': 'not_required'};
  }
  final result = <String, dynamic>{
    'required': true,
    'verified': false,
    'reason': 'native placement evidence unavailable',
    if (log != null) 'log_sha256': sha256.convert(utf8.encode(log)).toString(),
  };
  // Derive obligations from the executable profile, never from a producer's
  // case inventory or the evidence records that happen to be present.
  final List<String> selected;
  var headContexts = const <String, int>{};
  try {
    final parsed = ValidationProfile.fromJson(
      Map<String, dynamic>.from(profile),
    );
    final schema = manifest['schema_version'];
    if (schema != 1 && schema != 2 ||
        schema == 1 && (parsed.selection == 'focused' || parsed.isDecision)) {
      return result;
    }
    if (parsed.isDecision) headContexts = decisionHeadContexts;
    final catalog = manifest['catalog'] as Map?;
    final version = catalog?['version'] ?? 1;
    selected =
        (schema == 1
                ? parsed.legacyCaseIds
                : version is int &&
                      version >= 1 &&
                      version <= validationCatalogVersion
                ? parsed.caseIdsForCatalog(version)
                : parsed.caseIds)
            .where(
              (id) =>
                  !['C10.stop', 'C12.guards'].contains(id) ||
                  (schema == 2 &&
                      version is int &&
                      version >= 3 &&
                      !parsed.nativeReference),
            )
            .toList();
  } catch (_) {
    return result;
  }
  if (profile['runtime'] == 'litert' && backend == 'npu') {
    return _inspectNpu(manifest, cases, selected, result);
  }
  if (profile['runtime'] != 'gguf' ||
      log == null ||
      !['cuda', 'metal', 'vulkan'].contains(backend)) {
    return result;
  }
  if (backend == 'vulkan' &&
      RegExp(
        r'llvmpipe|lavapipe|swiftshader|microsoft basic render driver|software rasterizer',
        caseSensitive: false,
      ).hasMatch(log)) {
    return {
      ...result,
      'reason':
          'software Vulkan device present; physical accelerator execution is unproven',
    };
  }
  final expectedIds = selected
      .where(
        (id) => [
          'C01.load',
          'C09.reload',
          'C12.recovery',
          'C09.reload.second',
          'C12.guards',
          'D06.reload',
        ].contains(id),
      )
      .toList();
  final loads = cases
      .where((c) => expectedIds.contains(c['case_id']) && c['status'] == 'PASS')
      .toList();
  final expectedLoads = expectedIds.length;
  final prefix = {
    'cuda': r'CUDA\d+',
    'metal': r'MTL\d+|Metal',
    'vulkan': r'Vulkan\d+',
  }[backend]!;
  final heads = cases
      .where((c) => headContexts.containsKey(c['case_id']))
      .toList();
  final headDevices = [
    for (final head in heads)
      for (final evidence in [head, head['head_reload'], head['model_reload']])
        if (evidence is Map && evidence.containsKey('device_name'))
          evidence['device_name'],
  ];
  if (headContexts.keys.any(
        (id) =>
            heads
                .where((c) => c['case_id'] == id && c['status'] == 'PASS')
                .length !=
            1,
      ) ||
      headDevices.length != headContexts.values.fold(0, (a, b) => a + b) ||
      headDevices.any(
        (device) =>
            device is! String || !RegExp('^(?:$prefix)\$').hasMatch(device),
      )) {
    return {...result, 'reason': 'decision head placement evidence incomplete'};
  }
  if (expectedLoads == 0 ||
      expectedIds.any(
        (id) => loads.where((c) => c['case_id'] == id).length != 1,
      ) ||
      loads.any((c) {
        final name = (c['diagnostics'] as Map?)?['backend_name'];
        return name is! String ||
            !name.toLowerCase().contains(backend as String);
      })) {
    return result;
  }
  final offloads = RegExp(
    r'load_tensors: offloaded (\d+)/(\d+) layers to GPU',
  ).allMatches(log).toList();
  final buffers = RegExp(
    '(?:$prefix) compute buffer size =\\s*([0-9.]+) (?:MiB|MB)',
  ).allMatches(log).toList();
  var deviceIdentityVerified = true;
  if (backend == 'vulkan') {
    final devices = <String, Set<String>>{};
    void addDevice(String index, String name, {bool discovery = false}) {
      // Discovery includes capability columns and sometimes a vendor suffix;
      // selected-model records contain just the same physical device name.
      final unsafe = RegExp(
        r'\b(cpu|software|virtual)\b',
        caseSensitive: false,
      ).hasMatch(name);
      final identity = !discovery || unsafe
          ? name.trim()
          : name
                .split('|')
                .first
                .trim()
                .replaceFirst(
                  RegExp(r'\s+\((?:NVIDIA|AMD|Intel|Apple|Qualcomm)\)$'),
                  '',
                );
      devices.putIfAbsent(index, () => {}).add(identity);
    }

    for (final match in RegExp(
      r'ggml_vulkan:\s*(\d+)\s*=\s*([^\r\n]+)',
    ).allMatches(log)) {
      addDevice(match[1]!, match[2]!, discovery: true);
    }
    for (final match in RegExp(
      r'^llama_prepare_model_devices: using device Vulkan(\d+) '
      r'\(((?:[^()\r\n]|\([^()\r\n]*\))+)\)'
      r'(?: \([0-9a-fA-F:.]+\))? - [0-9]+(?:\.[0-9]+)? MiB free\r?$',
      multiLine: true,
    ).allMatches(log)) {
      addDevice(match[1]!, match[2]!);
    }
    final selectedDevices = RegExp(
      r'Vulkan(\d+) compute buffer size',
    ).allMatches(log).map((match) => match[1]!).toSet();
    final hardwareVendor = RegExp(
      r'\b(NVIDIA|AMD|Radeon|Intel|Apple|Adreno|Mali|PowerVR|Immortalis|Xclipse|Qualcomm)\b',
      caseSensitive: false,
    );
    final softwareDevice = RegExp(
      r'\b(cpu|software|virtual)\b',
      caseSensitive: false,
    );
    deviceIdentityVerified =
        selectedDevices.isNotEmpty &&
        selectedDevices.every((id) {
          final names = devices[id];
          return names != null &&
              names.length == 1 &&
              hardwareVendor.hasMatch(names.single) &&
              !softwareDevice.hasMatch(names.single);
        });
  }
  final positive =
      deviceIdentityVerified &&
      offloads.length == expectedLoads &&
      offloads.every(
        (m) => int.parse(m[1]!) > 0 && int.parse(m[1]!) <= int.parse(m[2]!),
      ) &&
      buffers.length ==
          expectedLoads + headContexts.values.fold(0, (a, b) => a + b) &&
      buffers.every((m) => (double.tryParse(m[1]!) ?? 0) > 0);
  return {
    ...result,
    'verified': positive,
    'reason': positive
        ? 'matching runtime diagnostics, positive native tensor offload and compute buffers for all $expectedLoads loads'
        : !deviceIdentityVerified
        ? 'Vulkan compute device identity is missing, contradictory or unrecognized as physical hardware'
        : 'native placement records incomplete or contradictory',
    'expected_loads': expectedLoads,
    'offload_records': offloads.map((m) => m[0]).toList(),
    'compute_records': buffers.map((m) => m[0]).toList(),
  };
}

Map<String, dynamic> _inspectNpu(
  Map<String, dynamic> manifest,
  List<Map<String, dynamic>> cases,
  List<String> selected,
  Map<String, dynamic> result,
) {
  final profile = manifest['profile'] as Map;
  final target = profile['npu_target'] as Map? ?? {};
  final identity = (manifest['preparation'] as Map?)?['npu'] as Map? ?? {};
  final device = identity['device'] as Map? ?? {};
  final kit = identity['kit'] as Map? ?? {};
  final libraries = kit['libraries'] as Map? ?? {};
  final locks = target['libraries'] as Map? ?? {};
  final aliases = target['device_soc_models'] as List? ?? [];
  final identitiesMatch =
      locks.isNotEmpty &&
      kit['target'] == target['soc'] &&
      kit['runtime_tag'] == (manifest['environment'] as Map?)?['litert_tag'] &&
      kit['schema_version'] == 1 &&
      kit['litert_revision'] == '9fe5be45564c868408e6514c8aabb83e211a0911' &&
      kit['dispatch_header_sha256'] ==
          '11dd4d98bd084157ac987b1ee1951f3f96e2b3ca6b51a27c10e645686bf0e3ee' &&
      device['verified'] == true &&
      device['abi'] == target['abi'] &&
      device['android_api'] is int &&
      target['minimum_android_api'] is int &&
      (device['android_api'] as int) >=
          (target['minimum_android_api'] as int) &&
      aliases.any(
        (soc) => '$soc'.toLowerCase() == '${device['soc_model']}'.toLowerCase(),
      ) &&
      libraries.length == locks.length &&
      locks.entries.every((entry) {
        final value = libraries[entry.key];
        final lock = entry.value as Map;
        return value is Map &&
            value['bytes'] is int &&
            (value['bytes'] as int) > 0 &&
            RegExp(r'^[a-f0-9]{64}$').hasMatch('${value['sha256']}') &&
            (lock['sha256'] == null || value['sha256'] == lock['sha256']);
      });
  final version = (manifest['catalog'] as Map?)?['version'];
  final expected = selected.where(
    (id) => [
      'C03.raw',
      'C04.hello',
      'C04.arithmetic',
      'C06.history',
      'C06.history.public_system_wire',
      'C06.history.no_system',
      'C06.history.combined',
      'C08.cancel',
      'C09.reload',
      'C10.limit',
      'C12.recovery',
      'B01.warmup',
      'B01.1',
      'B01.2',
      'B01.3',
      'C09.reload.second',
      'C10.stop',
      'C12.guards',
      if (version is int && version >= 4) ...[
        'C02.generate',
        'C05.thinking',
        'C07.tools',
      ],
      if (version is int && version >= 5) ...[
        'C08.cancel.early',
        'C07.tools.auto_text',
      ],
    ].contains(id),
  );
  final records = {for (final record in cases) record['case_id']: record};
  var valid = identitiesMatch;
  var proven = 0;
  List<int>? previous;
  for (final id in expected) {
    final record = records[id];
    if (record == null) {
      valid = false;
      continue;
    }
    final generations = switch (id) {
      'C08.cancel' => [
        record['uncancelled_control'],
        record,
        record['recovery'],
      ],
      'C10.stop' => [record['control'], record['stopped'], record['recovery']],
      'C12.guards' || 'C08.cancel.early' => [record['recovery']],
      'C05.thinking' => [
        for (var i = 0; i < 2; i++)
          record['trials'] is List && (record['trials'] as List).length > i
              ? (record['trials'] as List)[i]
              : null,
      ],
      'C07.tools' => [
        for (var i = 0; i < 3; i++) ...[
          record['trials'] is List && (record['trials'] as List).length > i
              ? (record['trials'] as List)[i]
              : null,
          if (i < 2)
            record['trials'] is List &&
                    (record['trials'] as List).length > i &&
                    (record['trials'] as List)[i] is Map
                ? ((record['trials'] as List)[i] as Map)['tool_result_followup']
                : null,
        ],
        record['recovery'],
      ],
      _ => [record],
    };
    for (final generation in generations) {
      final evidence = generation is Map ? generation['npu_execution'] : null;
      final before = evidence is Map ? evidence['before'] : null;
      final after = evidence is Map ? evidence['after'] : null;
      if (before is! List ||
          after is! List ||
          before.any((v) => v is! int) ||
          after.any((v) => v is! int)) {
        valid = false;
        continue;
      }
      final start = before.cast<int>();
      final end = after.cast<int>();
      final checked = npuGenerationEvidence(start, end);
      if (checked['verified'] != true ||
          (previous != null &&
              (start.length != 7 ||
                  List.generate(
                    5,
                    (i) => start[i + 1] < previous![i + 1],
                  ).any((v) => v)))) {
        valid = false;
      } else {
        proven++;
      }
      if (end.length == 7) previous = end;
    }
  }
  return {
    ...result,
    'verified': valid,
    'reason': valid
        ? 'Per-generation completed vendor calls; CPU partitions remain unknown'
        : 'Missing, inconsistent or failed per-generation NPU evidence/device identity',
    'placement': valid
        ? 'npu_participation_cpu_partitions_unknown'
        : 'unverified',
    'proven_generations': proven,
    'native_reference_only': profile['execution_path'] == 'native_c_api',
  };
}
