# Native reranking qualification

`LlamaReranker` borrows a loaded native llama.cpp RANK context. The public
wrapper and optional `BackendReranking` SPI are additive: `LlamaEngine`, its
exported extensions and existing backend interfaces gain no members.

The runtime pin stays `llamadart-native v0.7.0-2`, upstream
`620d2225cc436ab0b001e3200e590e3b286ef9ab`. Pair framing matches that upstream's
`tools/server/server-common.cpp:format_prompt_rerank`; this is placeholder
substitution, not ordinary Jinja chat rendering. Output zero matches `/rerank`.
All `n_cls_out` values and optional labels are copied before another pass.
Native Qwen3 softmax is retained, and other scores are not normalized.

## Contract and validation boundaries

The first implementation requires complete pairs to fit the minimum of actual
context, per-sequence context, logical batch and micro-batch limits. It
preflights every pair before inference, packs independent sequence IDs within
that budget and uses sequential passes with one allocated sequence slot. No
long-prompt chunking, truncation, partial result, model instruction override,
media input or Web/LiteRT-LM reranking is provided. Raw `embed` continues to
reject RANK. Query/document text, duplicate indices and exact-score tie order
are preserved. `topN` limits returned rows, not scoring compute.

The worker waits for active generation before probes/scoring. Inference uses
`LlamaCppObjectCalls`' guarded tokenize/encode/decode/synchronize/memory clear;
metadata and output copies use its object-access facade. The existing short
metadata-access direct-C-exit limitation in `llama_cpp_exit_teardown.md` remains.
Cancellation is checked before inference, between passes and after a pass. The
caller retains its shared cancellation flag until reply or worker exit.

Default-CI tests use synthetic GGUFs and fake backends to cover token framing,
sequence IDs, classifier width, preflight, unsupported paths, cancellation,
reuse, immutable results and RPC buffer lifetime. They do not qualify a real
reranker. The local-only scenario compares both full class vectors and the
primary upstream server's output zero. Other platforms require separate
receipts; do not infer their qualification from the native API or a macOS run.

## Prepare exact upstream oracles

Use an existing llama.cpp checkout that contains the pinned commit. Build in
an ignored task-local folder; no source patches or installed runtime overrides
are needed. On macOS, the example below makes a CPU oracle without BLAS/Metal.

```bash
mkdir -p .dart_tool/rerank_oracle/source
# LLAMA_CPP_CHECKOUT names the existing upstream source checkout.
git -C "$LLAMA_CPP_CHECKOUT" archive 620d2225cc436ab0b001e3200e590e3b286ef9ab \
  | tar -x -C .dart_tool/rerank_oracle/source
cmake -S .dart_tool/rerank_oracle/source -B .dart_tool/rerank_oracle/build \
  -DCMAKE_BUILD_TYPE=Release -DGGML_METAL=OFF -DGGML_BLAS=OFF \
  -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_SERVER=ON \
  -DLLAMA_BUILD_COMMIT=620d2225cc436ab0b001e3200e590e3b286ef9ab \
  -DLLAMA_BUILD_NUMBER=0
cmake --build .dart_tool/rerank_oracle/build --target llama-server -j 8
clang++ -std=c++17 test/fixtures/reranking/upstream_oracle.cpp \
  -I .dart_tool/rerank_oracle/source/include \
  -I .dart_tool/rerank_oracle/source/ggml/include \
  -I .dart_tool/rerank_oracle/source/common \
  -I .dart_tool/rerank_oracle/source/vendor \
  .dart_tool/rerank_oracle/build/common/libllama-common-base.a \
  -L .dart_tool/rerank_oracle/build/bin -lllama \
  -Wl,-rpath,"$PWD/.dart_tool/rerank_oracle/build/bin" \
  -o .dart_tool/rerank_oracle/rerank-oracle
.dart_tool/rerank_oracle/build/bin/llama-server --version
```

The source fixture consumes the upstream API directly and emits full class
vectors and token IDs. Its commit field comes from the linked upstream build
metadata, not the test. The separate server comparison guards its output-zero
semantics. Keep the archive commit and configure/build logs with receipts.

## Exact model inventory

| Role | Model | SHA-256 |
| --- | --- | --- |
| Named template, two native classes (`yes`, `no`) | Qwen3-Reranker-0.6B Q8_0; cached GGUF with `qwen3.pooling_type=4` and `cls.output.weight [1024,2]` | `22c9979ce4fbcdc5acdc310c6641c32797eff1aa980b8f7a2db8a8ea23429a48` |
| Vocabulary fallback, one classifier output | `ggml-org/models`, revision `499bc8821c6b12b4e53c5bffcb21ec206f212d81`, `jina-reranker-v1-tiny-en/ggml-model-f16.gguf` (upstream's test preset) | `ad9f450c1053a431e2e3746d1f9f7768fb9183cf0796e046983a3449dca093c2` |

Use local files with these exact hashes. The scenario downloads nothing. The
cached Qwen file's original download revision is not asserted here; its hash,
metadata and native emissions identify the qualified artifact. It cannot
substitute for the single-output fallback model. BGE weights are not qualified
by these Qwen/Jina runs.

## Run at the frozen source head

Set `LLAMADART_RERANK_QWEN_MODEL` and `LLAMADART_RERANK_JINA_MODEL` to those
local GGUF files, `LLAMADART_RERANK_ORACLE` to the full-class executable and
`LLAMADART_RERANK_SERVER` to the exact built llama-server. Optional
`LLAMADART_RERANK_EVIDENCE_DIR` saves JSON receipts. Set
`LLAMADART_RERANK_BACKEND=metal` for a second macOS Metal run; default is CPU.

```bash
dart run tool/testing/run_local_e2e.dart --list
dart run tool/testing/run_local_e2e.dart --scenario native-reranking --dry-run
TMPDIR="$(mktemp -d)" dart run tool/testing/run_local_e2e.dart \
  --scenario native-reranking
```

The corpus covers relevant/irrelevant candidates, duplicates, Unicode,
special-token-looking user text and literal placeholders. Tests compare all
classes against direct upstream emissions, output zero against `/rerank`, and
single versus grouped native scoring with absolute tolerance `2e-4`. They also
exercise overflow without partial results, early cancellation, reuse, raw
embedding rejection and disposal. Synthetic tests cover deterministic exact
score ties and cancellation after a pass. This tolerance is a parity gate for
these artifacts, not a retrieval quality benchmark or a universal score scale.
