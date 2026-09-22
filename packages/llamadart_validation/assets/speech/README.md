# Speech fixtures

`jfk.wav` is the familiar excerpt from John F. Kennedy's January 20, 1961
inaugural address, distributed as the `samples/jfk.wav` fixture in whisper.cpp.
The US federal government speech is public domain. Its exact bytes and reference
words are locked in `stt.json`; the reference ignores punctuation/case only.
No personal microphone recordings are included.

The Qwen3-ASR and Qwen3-TTS model/projector locks match the maintained chat-app
catalog. Model files are downloaded separately, never included in the app or
repository. Model licenses remain with the linked upstream repositories.

The fixture reference is a transcription oracle, not proof of exact-model
qualification. A failed transcription remains a failure; do not revise the
reference or threshold to match the output of a failing run.

The `stt` pack also builds four edge fixtures in process, so no extra audio is
stored: digital silence, plus three derived from `jfk.wav` — a truncated RIFF
whose header declares more audio than the bytes carry, a stereo 44.1 kHz
re-encode, and a 33-second concatenation crossing the projector's 30-second
`audio_chunk_len`. Their required outcomes are measured behavior, not
aspiration, except that the truncated RIFF may equally be rejected with a typed
`LlamaAudioFormatException` should decoding start validating the header.
`speech-results.json` records each generated fixture's SHA-256 under
`edge_fixtures`, keyed by the same id as its check.

## Cancellation and cleanup bounds

After the single-shot lifecycle checks, every run repeats three
cancel/dispose/load/generate cycles, so the bounds below are asserted over
repeated calls rather than one. `speech-results.json` reports them under
`bounds`, and `immediate_cancel_latency_bound`, `cancel_latency_bound` and
`peak_memory_bound` are ordinary checks that fail the run when a budget is
exceeded.

The single-shot checks and every cycle each cancel twice, so each latency bound
holds four samples per run:

- `cancel_immediate` cancels as soon as the task is handed back, without
  yielding first; the dedicated LiteRT adapter pushes no PCM before it. The
  adapter must report `cancel_immediate`.
- `cancel` cancels work that is already running. The GGUF adapter these packs
  use waits half of the run's most recent completed generation; the dedicated
  LiteRT adapter pushes PCM until the first partial transcript arrives, or until
  the fixture is exhausted, and also requires that at least one PCM chunk was
  accepted. The adapter must report `cancel_in_flight`, which it sets only when
  the task had not reached a terminal state at that moment. That rules out
  cancelling a task that had already finished, but cannot rule out one whose
  generation had not yet begun.

Both record the wait as `cancel_after_ms`, and the cancelled task must emit no
result. Cancellation latency is the interval from `cancel()` to the task's
terminal state, timed by the adapter that issues it. It bounds when the task
becomes terminal to its caller, not when native decoding stops.

Measured on macOS arm64 (Apple M4 Max) over 30 runs, 10 per `stt` backend and 5
per `tts` backend, with a one-minute load average of 8.05-18.00:

| pack / backend | immediate | in flight | in flight issued at | one generation |
| --- | --- | --- | --- | --- |
| `stt` / Metal | 0.266-1.485 ms | 0.244-2.413 ms | 76.2-86.7 ms | 149.3-229.0 ms |
| `stt` / CPU | 0.264-0.880 ms | 98.312-129.741 ms | 279.0-312.3 ms | 545.5-663.7 ms |
| `tts` / Metal | 0.100-1.503 ms | 0.451-21.641 ms | 624.6-860.1 ms | 1061.5-1714.1 ms |
| `tts` / CPU | 0.106-1.614 ms | 1012.341-1212.949 ms | 1140.2-1220.7 ms | 2205.1-2436.5 ms |

The immediate budget is 500 ms. It covers the window of
[#595](https://github.com/leehack/llamadart/issues/595): `synthesize()` hands
the task back before the native backend has registered the synthesis, and a
cancellation issued there was dropped, so the synthesis ran to completion before
the task reported `cancelled`.
[#596](https://github.com/leehack/llamadart/pull/596) made the backend record
it instead. With the library changes of
[#596](https://github.com/leehack/llamadart/pull/596) reverted, immediate `tts`
cancellations took 1234.954-1278.821 ms on Metal and 2209.651-2362.579 ms on
CPU over three runs each, and failed this bound; on Metal
`cancel_latency_bound` still passed. The budget's lower side comes from
`llama_dart_tts_start`, which has no cancellation check. With the worker's
check for a cancellation that arrives before native setup removed, immediate
`tts` cancellations waited for that call and took 108.821-125.679 ms on Metal
and 197.250-216.120 ms on CPU, one run each. 500 ms is about 2.3x the worst of
those and 2.5x below the fastest dropped cancellation.

Of 64 immediate `tts` cancellations measured on this tree, 63 took
0.100-1.614 ms and one, on Metal, took 136.752 ms. That one was not reproduced:
in instrumented runs all 464 immediate cancellations, 64 from the pack and 400
issued back to back, reached the worker before `llama_dart_tts_init`. Its cause
is unconfirmed; it is why the budget is not 50 ms. Because 500 ms exceeds a
whole `stt` generation on Metal, it cannot tell a dropped `stt` cancellation
from an honoured one there.

The in-flight budget is also 500 ms, about 3.9x the worst of the 80 in-flight
`stt` cancellations, 129.741 ms on CPU. Because it exceeds a whole `stt`
generation on Metal, it cannot by itself tell a cancellation apart from a
generation left to finish there.

`tts` fails the in-flight budget on CPU in every run. How long an in-flight
`tts` cancellation takes depends on the native call it lands in, because
`llama_dart_tts_step` checks for cancellation only on entry. In instrumented
runs, two per backend, the final step of a completed synthesis took
370.2-445.1 ms on Metal and 1313.1-1405.5 ms on CPU. On CPU it began
909.0-1101.1 ms in, before the in-flight cancellations were issued at
1169.0-1259.8 ms, and none of those 8 reached the worker before it returned. On
Metal 7 of 8 reached the worker between steps and completed in
3.187-19.572 ms; the eighth, issued 905.0 ms into a synthesis that followed a
1804.7 ms first synthesis, arrived during the final step and took 354.012 ms.
The `tts` / CPU failure is a recorded product gap, not a budget to raise.

Peak memory is the largest whole-process resident set sampled after any check
that follows the first generation, up to and including
`immediate_cancel_latency_bound`, as a multiple of the resident set sampled
immediately after that generation. Every check in between contributes one
sample — 16 of them on `stt`, 11 on `tts` — covering heterogeneous phases such
as `bytes_input`, both cancellations, the edge fixtures, `reload`, the cleanup
cycles and the latency bounds. The peak is the maximum over all of them, not
over generations alone. The budget is 1.10x. Over the 30 runs above, growth
spanned 1.0025x-1.0266x, so the budget is about 3.8x the worst excess over
1.0x. Growth over a whole run was 13.8-95.3 MiB against baselines of
1.86-5.31 GiB, so the budget leaves room for allocator and heap variation while
still failing on any retention above about 190 MiB against the smallest
baseline measured here. Resident memory is sampled after the first generation
rather than after load because the model pages in lazily: on `tts` the resident
set rose from 2.41-2.42 GiB after load to 3.49-3.82 GiB after the first
synthesis on Metal, and from 3.04-3.05 GiB to 5.30-5.31 GiB on CPU.

Resident memory comes from `dart:io` `ProcessInfo.currentRss`. It counts native
and Dart allocations together, what it counts is platform dependent, and it does
not exist without `dart:io`. When the probe reports nothing usable, the memory
check records `SKIP` with a reason and `bounds.peak_resident_bytes.measured` is
`false`; it never passes silently.

The budgets are evidence from one host, not a portable service level. A run
that exceeds them elsewhere is a finding to investigate, not a number to raise.
