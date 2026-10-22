import '../../engine/engine_observer.dart';
import '../../exceptions.dart';
import '../config/flash_attention.dart';
import '../config/kv_cache_type.dart';
import 'model_params.dart';

/// The fields of [params] set away from their defaults that [runtime] does
/// not apply, natively or on the Web when [web] is true, each as a rejection
/// message names it.
///
/// [ModelParams.liteRtLmEmbeddingEngine] and LiteRT-LM LoRA limits are left
/// to the checks that already reject them with their own guidance.
List<String> modelParamsUnsupportedBy(
  ModelParams params,
  LlamaRuntime runtime, {
  required bool web,
}) => switch (runtime) {
  LlamaRuntime.llamaCpp => [
    ..._liteRtLmOnlyFields(params),
    if (web) ...[
      if (!params.useMmap) 'useMmap=false',
      if (params.useMlock) 'useMlock',
    ] else ...[
      if (params.preferMemory64 != null) 'preferMemory64',
      if (params.modelBytesHint != null) 'modelBytesHint',
    ],
  ],
  LlamaRuntime.liteRtLm => [
    if (params.contextSize <= 0) 'contextSize=${params.contextSize}',
    if (params.gpuLayers > 0 && params.gpuLayers != ModelParams.maxGpuLayers)
      'gpuLayers=${params.gpuLayers}',
    if (params.splitMode != ModelSplitMode.layer) 'splitMode',
    if (params.mainGpu != 0) 'mainGpu',
    if (web) ...[
      if (params.loras.isNotEmpty) 'loras',
      ..._liteRtLmNativeOnlyFields(params),
      if (params.numberOfThreads != 0) 'numberOfThreads',
    ],
    if (params.numberOfThreadsBatch != 0) 'numberOfThreadsBatch',
    if (params.batchSize > 0) 'batchSize',
    if (params.microBatchSize > 0) 'microBatchSize',
    if (params.maxParallelSequences != 1) 'maxParallelSequences',
    if (params.speculativeRollbackTokenMax != 0) 'speculativeRollbackTokenMax',
    if (!params.useMmap) 'useMmap=false',
    if (params.useMlock) 'useMlock',
    if (params.loadMtp) 'loadMtp',
    if (params.flashAttention != FlashAttention.auto) 'flashAttention',
    if (params.cacheTypeK != KvCacheType.f16) 'cacheTypeK',
    if (params.cacheTypeV != KvCacheType.f16) 'cacheTypeV',
    if (params.kvUnified != null) 'kvUnified',
    if (params.ropeFrequencyBase != null) 'ropeFrequencyBase',
    if (params.ropeFrequencyScale != null) 'ropeFrequencyScale',
    if (params.preferMemory64 != null) 'preferMemory64',
    if (params.modelBytesHint != null) 'modelBytesHint',
  ],
};

/// Throws [LlamaUnsupportedException] naming each field of [params] that
/// [runtime] would not apply, natively or on the Web when [web] is true,
/// instead of loading the model without it.
void checkModelParamsSupportedBy(
  ModelParams params,
  LlamaRuntime runtime, {
  required bool web,
}) {
  final unsupported = modelParamsUnsupportedBy(params, runtime, web: web);
  if (unsupported.isEmpty) return;
  throw LlamaUnsupportedException(
    unsupportedModelParamsMessage(unsupported, runtime, web: web),
  );
}

/// The message of the [LlamaUnsupportedException] for the [unsupported]
/// fields of a load in [runtime], natively or on the Web when [web] is true.
String unsupportedModelParamsMessage(
  List<String> unsupported,
  LlamaRuntime runtime, {
  required bool web,
}) {
  final fields = unsupported.join(', ');
  return switch ((runtime, web)) {
    (LlamaRuntime.llamaCpp, false) =>
      'llama.cpp does not apply these ModelParams natively: $fields. The '
          'liteRtLm* fields apply only to LiteRT-LM (.litertlm) models, and '
          'preferMemory64 and modelBytesHint only to llama.cpp on the Web. '
          'Leave them unset for this model.',
    (LlamaRuntime.llamaCpp, true) =>
      'llama.cpp on the Web does not apply these ModelParams: $fields. The '
          'liteRtLm* fields apply only to LiteRT-LM (.litertlm) models, and '
          'the Web runtime neither memory-maps nor locks model weights. '
          'Leave them unset for this model.',
    (LlamaRuntime.liteRtLm, false) =>
      'LiteRtLmBackend does not support llama.cpp-specific ModelParams: '
          '$fields. Supported LiteRT-LM load options are contextSize, '
          'chatTemplate, device or the deprecated liteRtLmBackend for '
          'explicit CPU/GPU/NPU selection, preferredBackend, all-or-CPU '
          'gpuLayers hints, numberOfThreads, one default-scale initial LoRA '
          'adapter, liteRtLmActivationDataType, liteRtLmPrefillChunkSize, '
          'liteRtLmParallelFileSectionLoading, liteRtLmDispatchLibDir, '
          'liteRtLmCacheDir, and liteRtLmMaxProgramCacheBytes.',
    (LlamaRuntime.liteRtLm, true) =>
      'LiteRtLmBackend web does not support these native or '
          'llama.cpp-specific ModelParams: $fields. Supported LiteRT-LM web '
          'load options are contextSize, chatTemplate, device or the '
          'deprecated liteRtLmBackend for CPU/GPU selection, '
          'preferredBackend, and all-or-CPU gpuLayers hints.',
  };
}

List<String> _liteRtLmOnlyFields(ModelParams params) => [
  if (params.liteRtLmBackend != LiteRtLmBackendPreference.auto)
    'liteRtLmBackend',
  ..._liteRtLmNativeOnlyFields(params),
];

List<String> _liteRtLmNativeOnlyFields(ModelParams params) => [
  if (params.liteRtLmActivationDataType != null) 'liteRtLmActivationDataType',
  if (params.liteRtLmPrefillChunkSize != null) 'liteRtLmPrefillChunkSize',
  if (params.liteRtLmParallelFileSectionLoading != null)
    'liteRtLmParallelFileSectionLoading',
  if (params.liteRtLmDispatchLibDir != null) 'liteRtLmDispatchLibDir',
  if (params.liteRtLmCacheDir != null) 'liteRtLmCacheDir',
  if (params.liteRtLmMaxProgramCacheBytes != null)
    'liteRtLmMaxProgramCacheBytes',
];
