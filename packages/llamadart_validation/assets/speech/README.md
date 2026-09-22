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
cancel/dispose/load/generate cycles, so the two bounds below are asserted over
repeated calls rather than one. `speech-results.json` reports them under
`bounds`, and `cancel_latency_bound` and `peak_memory_bound` are ordinary checks
that fail the run when a budget is exceeded.

Every cancellation is issued into a generation that is already running. The
adapter waits half of the run's most recent completed generation, records that
wait as `cancel_after_ms`, and sets `cancel_in_flight` only when the task had
not reached a terminal state at that moment; the cancelled task must also emit
no result. A run whose adapter reports otherwise fails, so a cancellation timed
before its generation started cannot be reported as one.

Cancellation latency is the interval from `cancel()` to the task's terminal
state, timed by the adapter that issues it. It bounds when the task becomes
terminal to its caller, not when native decoding stops. The budget is 500 ms,
derived from 80 `stt` cancellations over 20 runs on macOS arm64 (10 Metal, 10
CPU) spanning 0.100-218.102 ms, so about 2.3x the worst case. The CPU backend
sets it alone: its 40 cancellations spanned 104.287-218.102 ms, against
0.100-2.576 ms on Metal. Because 500 ms exceeds a whole `stt` generation on
Metal here (142.9-341.3 ms), the budget cannot by itself tell a cancellation
apart from a generation left to finish.

The `tts` pack meets the budget on Metal and not on CPU. Its 20 Metal
cancellations, issued 623.8-756.4 ms into syntheses of 1059.3-1510.3 ms,
completed in 0.717-21.402 ms. Its 20 CPU cancellations, issued
1143.7-1227.0 ms into syntheses of 2235.0-2450.0 ms, completed in
30.318-1275.427 ms, with 19 of the 20 above 985 ms — about the synthesis time
left when they were issued. Cancellation is honoured there, in that no
audio is emitted and the task completes as cancelled, but on CPU it does not
shorten the wait. That is a recorded product gap, not a budget to raise.

How promptly a `tts` cancellation is honoured depends on where in the synthesis
it lands, so these latencies are tied to the half-generation wait above, not to
cancellation in general.

Peak memory is the largest whole-process resident set sampled after any check
that follows the first generation, up to and including `cancel_latency_bound`,
as a multiple of the resident set sampled immediately after that generation.
Every check in between contributes one sample — 14 of them on `stt`, 9 on `tts`
— covering heterogeneous phases such as `bytes_input`, `cancel`, the edge
fixtures, `reload`, the cleanup cycles and the latency bound. The peak is the
maximum over all of them, not over generations alone. The budget is 1.10x,
derived from 30 runs across both packs and both backends spanning
1.0025x-1.0130x, so about 7.7x the worst excess over 1.0x. Growth over a whole
run was 4.9-32.3 MiB against baselines of 1.86-5.31 GiB, so the budget leaves
room for allocator and heap variation while still failing on any retention above
about 190 MiB against the smallest baseline measured here. Resident memory is
sampled after the first generation rather than after load because the model
pages in lazily: on `tts` the resident set rises from 2.4 GiB after load to
3.8 GiB after the first synthesis.

Resident memory comes from `dart:io` `ProcessInfo.currentRss`. It counts native
and Dart allocations together, what it counts is platform dependent, and it does
not exist without `dart:io`. When the probe reports nothing usable, the memory
check records `SKIP` with a reason and `bounds.peak_resident_bytes.measured` is
`false`; it never passes silently.

Both budgets are evidence from one host, not a portable service level. A run
that exceeds them elsewhere is a finding to investigate, not a number to raise.
