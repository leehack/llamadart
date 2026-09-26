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
`speechCleanupCycles` (8) cancel/dispose/load/generate cycles.
`speech-results.json` reports the bounds under `bounds`, and
`immediate_cancel_latency_bound`, `cancel_latency_bound`, `peak_memory_bound`
and `leak_slope_bound` are ordinary checks that fail the run when a budget is
exceeded. The budgets are `speechImmediateCancelLatencyBudgetMs`,
`speechCancelLatencyBudgetMs`, `speechPeakFootprintGrowthBudget` and
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

Peak memory is the largest whole-process memory footprint sampled after the
checks between `generate` and `peak_memory_bound`, as a multiple of the
footprint sampled right after `generate`. Each of those checks contributes one
sample, covering heterogeneous phases such as `bytes_input`, both cancellations,
the edge fixtures, `reload`, the cleanup cycles and the latency bounds, so the
peak is the maximum over all of them, not over generations alone. The baseline
follows the first generation rather than load, so memory that generation first
brings in is not counted as growth.

The peak ratio is not applied on Linux CUDA, where it records `SKIP` with a
reason and `bounds.peak_footprint_bytes.applies` is `false`. There the weights
stay in device memory, so the resident set after `generate` was only about
1.13 GB. Each reload then added 0-100 MB of host memory until the total leveled
off at 1.13-1.16x, which failed 1.10x without a leak
([#686](https://github.com/leehack/llamadart/issues/686)). Every other
operating system and backend pair, including any the runner does not know, gets
the ratio.

`leak_slope_bound` runs on every backend. It skips the first
`speechLeakWarmupCycles` (1) cycles, then fails if the footprint grew by more
than `speechLeakCycleGrowthBytes` (7 MiB) in every one of the next
`speechLeakWindowCycles` (7) cycles. A plateau, a one-off spike or growth in
steps with a flat cycle between them passes; a steady leak of more than 7 MiB
per cycle fails. The constants come from resident set measurements taken
before the bounds used the footprint:

- 7 MiB is half the smallest per-cycle growth of the LiteRT ASR leak in
  [#634](https://github.com/leehack/llamadart/issues/634): 14.0 MiB across 12
  warm cycles on macOS arm64.
- The longest run of consecutive steps above 7 MiB in 46 recorded `stt` and
  `tts` runs without a known leak is 4 (macOS, Linux and Windows; CPU, Metal
  and CUDA). It occurred three times: in a macOS `tts` run recovering from memory
  pressure, in a Linux CUDA `tts` run, and in a Linux x64 CPU `tts` run whose
  resident set climbed for four cycles and then stopped. A 5-cycle window
  would leave one cycle of margin. 7 leaves three, at a cost of two cycles
  per run: about 30 s for `tts` on Linux x64 CPU and about 75 s on Linux
  arm64 CPU, the slowest recorded, which stays inside the 15-minute deadline.
- With `reload`, the warm-up cycle covers the first two reloads, which took
  the largest step in six of nine recorded Linux CUDA `tts` runs.

The slope bound alone does not catch a leak of 7 MiB or less per cycle, a leak
that releases memory in any window cycle, or growth that arrives in one jump. On
Linux, the #634 LiteRT ASR resident set growth is one jump of about 85 MiB at
`cancel`, then 0.7 MiB per cycle; only the peak ratio fails it. On Linux CUDA,
where the ratio is not applied, a leak like that would pass.

The footprint counts native and Dart allocations together. Each report names
its counter in `measurement`:

| Platform | Counter |
| --- | --- |
| macOS, iOS | `task_info(TASK_VM_INFO).phys_footprint` |
| Linux, Android | `RssAnon` + `VmSwap` from `/proc/self/status` |
| Windows | `PrivateUsage` from `GetProcessMemoryInfo` |

Each counts the process's private memory and not clean file-backed pages such
as the mmapped weights. The resident set the bounds used before counts pages
only while they stay in memory. Under memory pressure on macOS its sample
after `generate` came out up to 2 GB low, more than the whole `tts` model
file, and the peak ratio failed at 1.11-1.49x without a leak
([#633](https://github.com/leehack/llamadart/issues/633)). On macOS arm64,
`phys_footprint` held within 0.5% while compressing 4 GiB of dirty memory cut
the process's resident set from 4277 MiB to 139 MiB, and did not move while
`msync(MS_INVALIDATE)` dropped 512 MiB of mapped file pages. Counts differ
between operating systems, so ratios and deltas compare only within one.
There is no counter without `dart:io` or on other operating systems, and a
call that fails yields no sample. If any sample taken before
`peak_memory_bound` is unavailable, both memory bounds record `SKIP` with a
reason and their `bounds` entries report `measured` as `false`; they never
pass silently.
`interrupt_memory_bound` follows the same rule for the samples before it.

## Interrupt and truncation checks

The `tts` pack adds `unload_during_synthesis`, `dispose_during_synthesis`,
`decode_cancel` and `interrupt_memory_bound` after `leak_slope_bound`; the
`stt` pack adds `max_output_tokens_truncation` and
`context_size_truncation`. Each asserts its precondition in its own row and
records its budget there, not under `bounds`:

- `unload_during_synthesis` and `dispose_during_synthesis` require a progress
  event reporting a frame, and the task unfinished, before the call. The task
  must then end cancelled with no final audio within
  `speechCancelLatencyBudgetMs` of the call, and a synthesis after the reload
  must pass.
- `decode_cancel` first cancels `speechDecodeCancelOverheadRuns` syntheses
  capped at `speechDecodeCancelFrameCap` frames as soon as each is handed
  back, and takes the largest latency among them as the fixed cost of a
  cancellation. It then times the audio decode of
  `speechDecodeCancelReferenceRuns` uncancelled capped syntheses, from the
  progress event reporting the cap to the terminal state, running half before
  and half after one more synthesis. That one is cancelled
  `speechDecodeCancelLeadFraction` of the shortest earlier decode after that
  event. The margin is `speechDecodeCancelNoiseMultiple` times the spread of
  all reference decodes, and at least `speechDecodeCancelMarginFloorFraction`
  of the shortest. Timed from that event, the cancelled synthesis must end
  more than the margin sooner than the shortest reference, or the check
  fails; it also fails if the cancelled synthesis emits a final result. It
  records `NOT_RUN` with a `not_run_reason` and the measured numbers when the
  latest normal synthesis does not exceed the cap, a probe does not end
  cancelled, a reference does not stop at the cap, the cancellation does not
  reach a synthesis that has reported the cap at its scheduled lead, or the
  shortest reference decode left after the cancellation, less the overhead,
  is within the margin. In that last case even an immediate cancellation
  could not pass. `NOT_RUN` leaves `functional_pass` false.
- `interrupt_memory_bound` divides the largest footprint sampled after the
  three checks above by the one sampled after `leak_slope_bound`, against
  `speechPeakFootprintGrowthBudget`. Each of those checks reloads the model.
  Running them after the lifecycle bounds keeps their reloads out of those
  bounds, puts the lifecycle's reloads in their baseline, and still fails
  growth they add. Like `peak_memory_bound`, it records `SKIP` with the
  `speechPeakRatioExemption` reason on Linux CUDA and keeps its numbers,
  since reload overhead there exceeds the ratio without a leak. The
  interrupt checks run once each, so they get no slope bound: on Linux CUDA
  they have no memory bound.
- `max_output_tokens_truncation` sets `maxOutputTokens` to
  `speechTruncationTokenFraction` of the reference's token count, rounded
  down, and requires the latest complete transcript to tokenize to more.
  `context_size_truncation` loads a `speechTruncationContextSize` context,
  with `maxOutputTokens` no smaller, and sends the 33-second fixture. Both
  must fail with `LlamaSpeechTranscriptTruncatedException` at that limit and a
  partial transcript that is a strict word prefix of the expected one, its
  last word possibly cut short, and the next recognition on the same engine
  must reproduce the reference.
