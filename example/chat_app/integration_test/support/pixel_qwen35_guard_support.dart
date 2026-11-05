import 'dart:convert';

import 'package:llamadart/llamadart.dart';

import 'micro_batch_sweep_support.dart';

const pixelQwen35RunId = 'core018-pixel-supported-cases-20261104';
const pixelQwen35ModelSha256 =
    '57d1997790d1744fba5b40a7317df71ea5e2acee28c47e78f0cce39c0703f8cf';
const pixelQwen35ModelBytes = 563036064;
const pixelQwen35NativeArchiveSha256 =
    'a40669ffb3ab20a62028fbe65c0d217e5a36f71e4beef36447a6a630d5953a76';
const pixelQwen35AcceptedSizes = [0, 1, 2, 3, 4, 5, 6, 7, 8];
const pixelQwen35RefusedSizes = [9, 32, 33, 64, 512];

/// Builds the exact public request, including the CPU zero-layer control.
ModelParams pixelQwen35LoadParams(
  ModelParams profile, {
  required String backend,
  required int microBatchSize,
  bool zeroLayers = false,
}) {
  final params = profile.copyWith(
    microBatchSize: microBatchSize,
    gpuLayers: zeroLayers ? 0 : profile.gpuLayers,
    device: zeroLayers
        ? ComputeDevice.auto
        : backend == 'vulkan'
        ? ComputeDevice.gpu
        : ComputeDevice.cpu,
  );
  params.validate();
  return params;
}

/// Preserves the maintained C06 comparison, including case sensitivity.
bool pixelQwen35HistoryPass(String content) => content.trim() == 'cedar17';

bool pixelQwen35TypedRefusal(Object? error, {bool diagnostic = true}) =>
    error is LlamaUnsupportedException &&
    (!diagnostic ||
        error.message.contains('Android/Vulkan') &&
            error.message.contains('948'));

/// These logs establish placement; they are not per-request shader tracing.
bool pixelQwen35VulkanPlacement(String log) {
  if (RegExp(
    r'llvmpipe|lavapipe|SwiftShader|software',
    caseSensitive: false,
  ).hasMatch(log)) {
    return false;
  }
  final offloads = RegExp(
    r'load_tensors: offloaded (\d+)/(\d+) layers to GPU',
  ).allMatches(log).toList();
  if (offloads.length != 1 ||
      int.parse(offloads.single[1]!) <= 0 ||
      int.parse(offloads.single[1]!) > int.parse(offloads.single[2]!)) {
    return false;
  }
  final devices = RegExp(
    r'using device Vulkan(\d+) \((Mali-G715[^\r\n]*)\)',
  ).allMatches(log).map((m) => m[1]).toSet();
  final buffers = RegExp(
    r'Vulkan(\d+) compute buffer size =\s*([0-9.]+) (?:MiB|MB)',
  ).allMatches(log).toList();
  return devices.length == 1 &&
      buffers.isNotEmpty &&
      buffers.every(
        (m) => devices.contains(m[1]) && (double.tryParse(m[2]!) ?? 0) > 0,
      );
}

/// A real capped decision is required; no test seam supplies device facts.
bool pixelQwen35RestrictedFacts(Iterable<String> messages) {
  final decisions = messages.map(parsePromptCapDecision).nonNulls.toList();
  return decisions.isNotEmpty &&
      decisions.every(
        (decision) =>
            decision.capTokens == 8 &&
            decision.detail.isNotEmpty &&
            (decision.devices.isEmpty ||
                decision.devices.any(
                  (device) =>
                      device.name.contains('Mali-G715') &&
                      device.subgroupSize != 8 &&
                      device.subgroupSize < 32,
                )),
      );
}

/// Public evidence only: output IDs are visible-output retokenization IDs,
/// never sampled native token IDs or the hidden stop/EOG sequence.
List<String> pixelQwen35ArithmeticFailures(
  Map<String, dynamic> evidence, {
  Map<String, dynamic>? reference,
  bool requireReference = false,
}) {
  final failures = <String>[];
  if (requireReference && reference == null) {
    return ['cpu_reference_not_passed'];
  }
  final content = evidence['content'] as String? ?? '';
  if (!RegExp(r'^4[.!]?$').hasMatch(content.trim())) {
    failures.add('semantic');
  }
  if (evidence['thinking'] != '') {
    failures.add('thinking');
  }
  if (evidence['stream_completed'] != true ||
      evidence['ordered_terminal'] != true) {
    failures.add('stream');
  }
  if (evidence['finish_reason'] != 'stop') {
    failures.add('finish');
  }
  final usage = evidence['native_usage_counts'] as Map?;
  if (usage == null ||
      (usage['prompt_tokens'] as int? ?? 0) <= 0 ||
      (usage['completion_tokens'] as int? ?? 0) <= 0) {
    failures.add('usage');
  }
  final inputIds = evidence['rendered_input_ids'] as List?;
  if (inputIds == null ||
      inputIds.length <= 8 ||
      evidence['rendered_prompt'] is! String ||
      (evidence['rendered_prompt'] as String).isEmpty) {
    failures.add('geometry');
  }
  if ((evidence['visible_output_retokenization_ids'] as List?)?.isNotEmpty !=
      true) {
    failures.add('visible_output_ids');
  }
  if (reference != null) {
    for (final key in [
      'content',
      'visible_output_utf8',
      'visible_output_retokenization_ids',
      'messages',
      'request_settings',
      'rendered_prompt',
      'rendered_input_ids',
      'native_usage_counts',
      'finish_reason',
    ]) {
      if (jsonEncode(evidence[key]) != jsonEncode(reference[key])) {
        failures.add('parity.$key');
      }
    }
  }
  return failures;
}

List<String> pixelQwen35MissingCases(
  Iterable<String> requiredCases,
  Iterable<String> completed,
) => requiredCases.where((id) => !completed.contains(id)).toList();

/// Complete prospective inventory; strict C06 remains separate from C04.
List<String> pixelQwen35RequiredCases() => <String>[
  'cpu-original',
  'cpu-original.C06.history',
  'gpu-default',
  'gpu-default.C06.history',
  for (final size in pixelQwen35AcceptedSizes.where((n) => n > 0))
    'gpu-size-$size',
  for (final size in pixelQwen35RefusedSizes) 'gpu-refuse-$size',
  'cpu-size-32',
  'vulkan-zero-layers-size-32',
  'gpu-default.C04.post-refusal',
  'media.image',
  'media.audio',
  'media.video',
  'speculation.legacy',
  for (final strategy in SpeculativeDecodingStrategy.values)
    'speculation.${strategy.name}',
  'speculation.mixed',
  'speculation.external-pre-io',
  'embedding.single',
  'embedding.batch',
  'embedding.content',
  'embedding.content-batch',
];
