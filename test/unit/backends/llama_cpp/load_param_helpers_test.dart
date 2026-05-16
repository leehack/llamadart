@TestOn('vm')
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:llamadart/src/backends/llama_cpp/bindings.dart';
import 'package:llamadart/src/backends/llama_cpp/load_param_helpers.dart';
import 'package:llamadart/src/core/models/config/flash_attention.dart';
import 'package:llamadart/src/core/models/config/kv_cache_type.dart';
import 'package:llamadart/src/core/models/inference/model_params.dart';
import 'package:test/test.dart';

void main() {
  group('ggmlTypeFor', () {
    test('f16 → GGML_TYPE_F16', () {
      expect(ggmlTypeFor(KvCacheType.f16), ggml_type.GGML_TYPE_F16);
    });

    test('q8_0 → GGML_TYPE_Q8_0', () {
      expect(ggmlTypeFor(KvCacheType.q8_0), ggml_type.GGML_TYPE_Q8_0);
    });

    test('q4_0 → GGML_TYPE_Q4_0', () {
      expect(ggmlTypeFor(KvCacheType.q4_0), ggml_type.GGML_TYPE_Q4_0);
    });
  });

  group('resolveFlashAttention', () {
    test('auto + F16/F16 → auto (no promotion needed)', () {
      expect(
        resolveFlashAttention(
          requested: FlashAttention.auto,
          cacheTypeK: KvCacheType.f16,
          cacheTypeV: KvCacheType.f16,
        ),
        FlashAttention.auto,
      );
    });

    test('auto + Q8_0 K → enabled (auto-promote)', () {
      expect(
        resolveFlashAttention(
          requested: FlashAttention.auto,
          cacheTypeK: KvCacheType.q8_0,
          cacheTypeV: KvCacheType.f16,
        ),
        FlashAttention.enabled,
      );
    });

    test('auto + Q4_0 V → enabled (auto-promote)', () {
      expect(
        resolveFlashAttention(
          requested: FlashAttention.auto,
          cacheTypeK: KvCacheType.f16,
          cacheTypeV: KvCacheType.q4_0,
        ),
        FlashAttention.enabled,
      );
    });

    test('auto + Q8_0 K/V → enabled (auto-promote)', () {
      expect(
        resolveFlashAttention(
          requested: FlashAttention.auto,
          cacheTypeK: KvCacheType.q8_0,
          cacheTypeV: KvCacheType.q8_0,
        ),
        FlashAttention.enabled,
      );
    });

    test('explicit enabled passes through unchanged regardless of KV', () {
      for (final k in KvCacheType.values) {
        for (final v in KvCacheType.values) {
          expect(
            resolveFlashAttention(
              requested: FlashAttention.enabled,
              cacheTypeK: k,
              cacheTypeV: v,
            ),
            FlashAttention.enabled,
            reason: 'enabled should stay enabled for k=$k v=$v',
          );
        }
      }
    });

    test(
      'explicit disabled passes through unchanged for F16 (no promotion)',
      () {
        // The disabled+non-F16 combination is rejected by ModelParams's
        // constructor; this helper isn't responsible for that validation.
        // For F16/F16, disabled is legal and should pass through.
        expect(
          resolveFlashAttention(
            requested: FlashAttention.disabled,
            cacheTypeK: KvCacheType.f16,
            cacheTypeV: KvCacheType.f16,
          ),
          FlashAttention.disabled,
        );
      },
    );
  });

  group('applyModelParams', () {
    test('writes use_mmap and use_mlock from params', () {
      final m = calloc<llama_model_params>();
      try {
        applyModelParams(m.ref, ModelParams(useMmap: false, useMlock: true));
        expect(m.ref.use_mmap, isFalse);
        expect(m.ref.use_mlock, isTrue);
      } finally {
        calloc.free(m);
      }
    });

    test('default ModelParams writes mmap=true, mlock=false', () {
      final m = calloc<llama_model_params>();
      try {
        applyModelParams(m.ref, ModelParams());
        expect(m.ref.use_mmap, isTrue);
        expect(m.ref.use_mlock, isFalse);
      } finally {
        calloc.free(m);
      }
    });
  });

  group('applyContextParams', () {
    test('writes type_k/type_v from cacheTypeK/V', () {
      final c = calloc<llama_context_params>();
      try {
        applyContextParams(
          c.ref,
          ModelParams(
            cacheTypeK: KvCacheType.q8_0,
            cacheTypeV: KvCacheType.q4_0,
            flashAttention: FlashAttention.enabled,
          ),
        );
        expect(c.ref.type_kAsInt, ggml_type.GGML_TYPE_Q8_0.value);
        expect(c.ref.type_vAsInt, ggml_type.GGML_TYPE_Q4_0.value);
      } finally {
        calloc.free(c);
      }
    });

    test('explicit FA enabled writes ENABLED', () {
      final c = calloc<llama_context_params>();
      try {
        applyContextParams(
          c.ref,
          ModelParams(flashAttention: FlashAttention.enabled),
        );
        expect(
          c.ref.flash_attn_typeAsInt,
          llama_flash_attn_type.LLAMA_FLASH_ATTN_TYPE_ENABLED.value,
        );
      } finally {
        calloc.free(c);
      }
    });

    test('explicit FA disabled (with F16 KV) writes DISABLED', () {
      final c = calloc<llama_context_params>();
      try {
        applyContextParams(
          c.ref,
          ModelParams(flashAttention: FlashAttention.disabled),
        );
        expect(
          c.ref.flash_attn_typeAsInt,
          llama_flash_attn_type.LLAMA_FLASH_ATTN_TYPE_DISABLED.value,
        );
      } finally {
        calloc.free(c);
      }
    });

    test('FA auto + Q8 KV auto-promotes to ENABLED in the struct', () {
      final c = calloc<llama_context_params>();
      try {
        final resolved = applyContextParams(
          c.ref,
          ModelParams(
            cacheTypeK: KvCacheType.q8_0,
            cacheTypeV: KvCacheType.q8_0,
          ),
        );
        expect(resolved, FlashAttention.enabled);
        expect(
          c.ref.flash_attn_typeAsInt,
          llama_flash_attn_type.LLAMA_FLASH_ATTN_TYPE_ENABLED.value,
        );
      } finally {
        calloc.free(c);
      }
    });

    test('null kvUnified leaves struct field unchanged', () {
      final c = calloc<llama_context_params>();
      try {
        c.ref.kv_unified = false;
        applyContextParams(c.ref, ModelParams());
        expect(c.ref.kv_unified, isFalse);
      } finally {
        calloc.free(c);
      }
    });

    test('non-null kvUnified writes the value', () {
      final c = calloc<llama_context_params>();
      try {
        applyContextParams(c.ref, ModelParams(kvUnified: true));
        expect(c.ref.kv_unified, isTrue);
      } finally {
        calloc.free(c);
      }
    });

    test('null ropeFrequencyBase / Scale leaves struct fields unchanged', () {
      final c = calloc<llama_context_params>();
      try {
        c.ref.rope_freq_base = 12345.0;
        c.ref.rope_freq_scale = 0.5; // fp32-exact value
        applyContextParams(c.ref, ModelParams());
        expect(c.ref.rope_freq_base, 12345.0);
        expect(c.ref.rope_freq_scale, 0.5);
      } finally {
        calloc.free(c);
      }
    });

    test('non-null rope frequencies write through', () {
      final c = calloc<llama_context_params>();
      try {
        applyContextParams(
          c.ref,
          ModelParams(
            ropeFrequencyBase: 500000.0,
            ropeFrequencyScale: 0.25, // fp32-exact value
          ),
        );
        expect(c.ref.rope_freq_base, 500000.0);
        expect(c.ref.rope_freq_scale, 0.25);
      } finally {
        calloc.free(c);
      }
    });

    test('returns the resolved FlashAttention value', () {
      final c = calloc<llama_context_params>();
      try {
        expect(
          applyContextParams(
            c.ref,
            ModelParams(flashAttention: FlashAttention.enabled),
          ),
          FlashAttention.enabled,
        );
      } finally {
        calloc.free(c);
      }
    });
  });
}
