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
re-encode, and a 33-second concatenation. Their required outcomes are measured
behavior, not aspiration, except that the truncated RIFF may equally be
rejected with a typed `LlamaAudioFormatException` should decoding start
validating the header.
`speech-results.json` records each generated fixture's SHA-256 under
`edge_fixtures`, keyed by the same id as its check.

## Cancellation and cleanup bounds

After the single-shot lifecycle checks, a run whose `load` check passes repeats
`speechCleanupCycles` (6) cancel/dispose/load/generate cycles.
`speech-results.json` reports the bounds under `bounds`, and
`immediate_cancel_latency_bound`, `cancel_latency_bound`, `peak_memory_bound`
and `leak_slope_bound` are ordinary checks that fail the run when a budget is
exceeded. The budgets are `speechImmediateCancelLatencyBudgetMs`,
`speechCancelLatencyBudgetMs`, `speechPeakRssGrowthBudget` and
`speechLeakCycleGrowthBytes` in `lib/src/speech_runner.dart`.

The single-shot checks and every cycle each cancel twice:

- `cancel_immediate` cancels as soon as the task is handed back, without
  yielding first; the dedicated LiteRT adapter pushes no PCM before it. The
  adapter must report `cancel_immediate`. This is the window in which `tts`
  cancellations were dropped until
  [#596](https://github.com/leehack/llamadart/pull/596).
- `cancel` cancels after a wait. The GGUF adapter used by the `stt` and `tts`
  packs waits `speechCancelInFlightLeadFraction` of its most recent completed
  generation; the dedicated LiteRT adapter pushes PCM until the first partial
  transcript arrives, or until the fixture is exhausted. The adapter must
  report `cancel_in_flight`, which is true only if it had not seen the task
  finish when it cancelled; the dedicated LiteRT adapter also requires that at
  least one PCM chunk was accepted. It cannot show that the generation had
  begun.

Both record the time from the start of the call to the cancellation as
`cancel_after_ms`, and the cancelled task must emit no result. Cancellation
latency is the interval from `cancel()` to the task's terminal state, timed by
the adapter that issues it. It bounds when the task becomes terminal to its
caller, not when native work stops, so a cancellation honoured only after the
generation finishes can still pass either bound.

Peak memory is the largest whole-process resident set sampled after the checks
between `generate` and `peak_memory_bound`, as a multiple of the resident set
sampled right after `generate`. Each of those checks contributes one sample,
covering heterogeneous phases such as `bytes_input`, both cancellations, the
edge fixtures, `reload`, the cleanup cycles and the latency bounds, so the peak
is the maximum over all of them, not over generations alone. The baseline
follows the first generation rather than load, so memory that generation first
brings in is not counted as growth.

The peak ratio is not applied on Linux CUDA, where it records `SKIP` with a
reason and `bounds.peak_resident_bytes.applies` is `false`. There the weights
stay in device memory, so the resident set after `generate` is only about
1.13 GB. Each reload then adds 0-100 MB of host memory until the total levels
off at 1.13-1.16x, which fails 1.10x without a leak
([#686](https://github.com/leehack/llamadart/issues/686)). Every other
operating system and backend pair, including any the runner does not know, gets
the ratio.

`leak_slope_bound` runs on every backend. It skips the first
`speechLeakWarmupCycles` (1) cycles, then fails if the resident set grew by more
than `speechLeakCycleGrowthBytes` (7 MiB) in every one of the next
`speechLeakWindowCycles` (5) cycles. A plateau, a one-off spike or growth in
steps with a flat cycle between them passes; a steady leak of more than 7 MiB
per cycle fails. The constants come from measured runs:

- 7 MiB is half the smallest per-cycle growth of the LiteRT ASR leak in
  [#634](https://github.com/leehack/llamadart/issues/634): 14.0 MiB across 12
  warm cycles on macOS arm64.
- 5 cycles is one more than the longest run of consecutive steps above 7 MiB in
  37 recorded runs without a known leak (macOS, Linux and Windows; CPU, Metal
  and CUDA): 4, in a macOS `tts` run recovering from memory pressure. The
  seven Linux CUDA `tts` runs behind #686 reach 3.
- With `reload`, the warm-up cycle covers the first two reloads, which took
  the largest step in six of those seven Linux CUDA runs.

A leak that grows by 7 MiB or less per cycle, or that releases memory in any
window cycle, passes this bound; on backends that keep the peak ratio, that
ratio still applies.

Resident memory comes from `dart:io` `ProcessInfo.currentRss`. It counts native
and Dart allocations together, what it counts is platform dependent, and it does
not exist without `dart:io`. If any sample taken before `peak_memory_bound` is
unavailable, both memory bounds record `SKIP` with a reason and their
`bounds` entries report `measured` as `false`; they never pass silently.
