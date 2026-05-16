// Pure helpers for the load path. Kept here (vs inlined in the service) so
// they can be unit-tested without going through `LlamaEngine.loadModel`,
// which is integration-level and needs a real model file.

import '../../core/models/config/flash_attention.dart';
import '../../core/models/config/kv_cache_type.dart';
import '../../core/models/config/llama_cpp_param_values.dart'
    as llama_cpp_values;
import '../../core/models/inference/model_params.dart';
import 'bindings.dart';

export '../../core/models/config/llama_cpp_param_values.dart'
    show resolveFlashAttention;

/// Maps llamadart's [KvCacheType] enum to llama.cpp's `ggml_type`. Pure
/// switch, no side effects.
ggml_type ggmlTypeFor(KvCacheType type) {
  return ggml_type.fromValue(llama_cpp_values.ggmlTypeValueFor(type));
}

/// Applies the user-controlled fields of [params] to a freshly-defaulted
/// `llama_model_params` struct. Pure function: caller is responsible for
/// initialising and freeing the struct.
void applyModelParams(llama_model_params mparams, ModelParams params) {
  mparams.use_mmap = params.useMmap;
  mparams.use_mlock = params.useMlock;
}

/// Applies the user-controlled fields of [params] to a `llama_context_params`
/// struct. Honours the `auto` → `enabled` flash-attention promotion via
/// [resolveFlashAttention]. Returns the resolved [FlashAttention] so the
/// caller can log whether a promotion occurred.
FlashAttention applyContextParams(
  llama_context_params ctxParams,
  ModelParams params,
) {
  final resolvedFlashAttn = llama_cpp_values.resolveFlashAttention(
    requested: params.flashAttention,
    cacheTypeK: params.cacheTypeK,
    cacheTypeV: params.cacheTypeV,
  );
  switch (resolvedFlashAttn) {
    case FlashAttention.auto:
      break;
    case FlashAttention.enabled:
      ctxParams.flash_attn_typeAsInt =
          llama_flash_attn_type.LLAMA_FLASH_ATTN_TYPE_ENABLED.value;
      break;
    case FlashAttention.disabled:
      ctxParams.flash_attn_typeAsInt =
          llama_flash_attn_type.LLAMA_FLASH_ATTN_TYPE_DISABLED.value;
      break;
  }
  ctxParams.type_kAsInt = ggmlTypeFor(params.cacheTypeK).value;
  ctxParams.type_vAsInt = ggmlTypeFor(params.cacheTypeV).value;
  if (params.kvUnified != null) {
    ctxParams.kv_unified = params.kvUnified!;
  }
  if (params.ropeFrequencyBase != null) {
    ctxParams.rope_freq_base = params.ropeFrequencyBase!;
  }
  if (params.ropeFrequencyScale != null) {
    ctxParams.rope_freq_scale = params.ropeFrequencyScale!;
  }
  return resolvedFlashAttn;
}
