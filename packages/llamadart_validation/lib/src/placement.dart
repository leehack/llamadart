import 'dart:convert';
import 'package:crypto/crypto.dart';

/// Conservative GGUF native-log evidence. A selector or device inventory alone
/// is insufficient: every expected load needs positive offload and compute allocation.
Map<String, dynamic> inspectPlacement(
  Map<String, dynamic> manifest,
  List<Map<String, dynamic>> cases,
  String? log,
) {
  final profile = manifest['profile'] as Map? ?? {};
  final backend = profile['backend'];
  final required = manifest['accelerator_evidence_required'] == true;
  if (!required) {
    return {'required': false, 'verified': true, 'reason': 'not_required'};
  }
  final result = <String, dynamic>{
    'required': true,
    'verified': false,
    'reason': 'native placement evidence unavailable',
    if (log != null) 'log_sha256': sha256.convert(utf8.encode(log)).toString(),
  };
  if (profile['runtime'] != 'gguf' ||
      log == null ||
      !['cuda', 'metal', 'vulkan'].contains(backend)) {
    return result;
  }
  final loads = cases
      .where(
        (c) =>
            ['C01.load', 'C09.reload', 'C12.recovery'].contains(c['case_id']) &&
            c['status'] == 'PASS',
      )
      .toList();
  final expectedLoads = loads.length;
  if (expectedLoads != 3 ||
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
  final prefix = {
    'cuda': r'CUDA\d+',
    'metal': r'MTL\d+|Metal',
    'vulkan': r'Vulkan\d+',
  }[backend]!;
  final buffers = RegExp(
    '(?:$prefix) compute buffer size =\\s*([0-9.]+) (?:MiB|MB)',
  ).allMatches(log).toList();
  final positive =
      offloads.length == expectedLoads &&
      offloads.every(
        (m) => int.parse(m[1]!) > 0 && int.parse(m[1]!) <= int.parse(m[2]!),
      ) &&
      buffers.length == expectedLoads &&
      buffers.every((m) => (double.tryParse(m[1]!) ?? 0) > 0);
  return {
    ...result,
    'verified': positive,
    'reason': positive
        ? 'matching runtime diagnostics, positive native tensor offload and compute buffers for all three loads'
        : 'native placement records incomplete or contradictory',
    'expected_loads': expectedLoads,
    'offload_records': offloads.map((m) => m[0]).toList(),
    'compute_records': buffers.map((m) => m[0]).toList(),
  };
}
