# Moonshine overlap replay

`asr_overlap.cc` feeds three constructed, untimed word windows into the
unmodified upstream `TimestampTextMerger`. They reproduce the exact duplicated
fragment reported in [#673](https://github.com/leehack/llamadart/issues/673);
they are not captured decoder emissions or a real-model qualification.

Verified source: LiteRT-LM v0.18.0,
[`b2f686e2ed4718fb84ec398a61dd59ca0f0aff27`](https://github.com/google-ai-edge/LiteRT-LM/tree/b2f686e2ed4718fb84ec398a61dd59ca0f0aff27/omni/asr).
`stateless_decoder.cc` emits null timestamps for Moonshine.
`timestamp_text_merger.cc` falls back to word-count overlap and pivot estimates.
With the same word windows, 0.4 repeats `tree can do for you`; 0.6 produces the
complete transcript once. `levenshtein_text_merger.cc` was also evaluated and
rejected: its first-match alignment drops valid words in this fixture.

The consumer fix changes only the omitted Moonshine overlap setting to 0.6.
Explicit settings and other presets are retained. A single window is decoded
from the same PCM and flushed unchanged; the replay includes legitimate
repeated words as a negative control. This does not repair arbitrary merger
errors in the native runtime.

Run the durable replay with a C++17 compiler, current Abseil with status macros,
`pkg-config`, and an upstream v0.18.0 source checkout (no model weights):

```sh
LLAMADART_LITERT_LM_SOURCE=/path/to/LiteRT-LM \
  dart test -p vm -j 1 --run-skipped --tags local-only \
  test/integration/backends/litert_lm/litert_lm_asr_overlap_test.dart
```

Set `PKG_CONFIG_PATH` if Abseil is outside pkg-config's search path. The test
uses a temporary header to forward LiteRT's status-assignment macro to the
identical Abseil operation; upstream merger sources are compiled unchanged.
