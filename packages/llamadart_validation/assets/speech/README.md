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

Cancellation latency is the interval from `cancel()` to the task's terminal
state, timed by the adapter that issues it. The budget is 50 ms, derived from 80
`stt` cancellations over 20 runs on macOS arm64 (10 Metal, 10 CPU) spanning
0.259-1.587 ms. The headroom is about 31x the worst case, enough for host
scheduling jitter yet far below one generation on that host (201-633 ms), so a
cancellation that waits for in-flight inference still fails.

The `tts` pack does not meet that budget: its cancellations measured
1245-1278 ms on Metal and 2231-2565 ms on CPU, which over 30 cleanup cycles was
93-104% of the generation that followed them in the same run. The same ratio for
`stt` is 0.04-0.31%. Cancellation is honoured, in that no audio is emitted and
the task completes as cancelled, but it does not shorten the wait. That is a
recorded product gap, not a budget to raise.

Peak memory is the largest whole-process resident set sampled after any check
following the first generation, as a multiple of the resident set sampled
immediately after it. The budget is 1.10x, derived from 30 runs across both
packs and both backends spanning 1.0002x-1.0111x. Growth over a whole run was
1.2-26.1 MiB against baselines of 1.86-5.31 GiB, so the budget leaves room for
allocator and heap variation while still failing on any retention above about
190 MiB against the smallest baseline measured here. Resident memory is sampled
after the first generation rather than after load because the model pages in
lazily: on `tts` the resident set rises from 2.4 GiB after load to 3.9 GiB after
the first synthesis.

Resident memory comes from `dart:io` `ProcessInfo.currentRss`. It counts native
and Dart allocations together, what it counts is platform dependent, and it does
not exist without `dart:io`. When the probe reports nothing usable, the memory
check records `SKIP` with a reason and `bounds.peak_resident_bytes.measured` is
`false`; it never passes silently.

Both budgets are evidence from one host, not a portable service level. A run
that exceeds them elsewhere is a finding to investigate, not a number to raise.
