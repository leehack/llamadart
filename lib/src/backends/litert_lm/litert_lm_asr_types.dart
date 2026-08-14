import 'dart:typed_data';

/// LiteRT-LM ASR model families whose runtime metadata is versioned by the
/// native bridge.
enum LiteRtLmAsrModelPreset {
  /// NVIDIA Parakeet TDT 0.6B v3.
  parakeetTdt0_6bV3,

  /// NVIDIA Parakeet CTC 0.6B.
  parakeetCtc0_6b,

  /// Useful Sensors Moonshine Tiny.
  moonshineTiny,

  /// OpenAI Whisper Tiny.
  whisperTiny,

  /// Qwen3-ASR 0.6B.
  qwen3Asr0_6b,
}

/// LiteRT accelerator used for a dedicated ASR model.
///
/// Dedicated ASR is CPU-only in the currently validated v0.16 runtime. GPU
/// and NPU values can be added after their model/runtime combinations pass the
/// same real-model correctness gates.
enum LiteRtLmAsrBackend {
  /// XNNPACK CPU execution.
  cpu,
}

/// Configuration for a dedicated LiteRT-LM ASR session.
class LiteRtLmAsrRuntimeConfig {
  /// Local `.tflite` speech-recognition model path.
  final String modelPath;

  /// Local tokenizer JSON path matching [modelPath].
  final String tokenizerPath;

  /// Model-family metadata preset.
  final LiteRtLmAsrModelPreset modelPreset;

  /// Requested accelerator.
  final LiteRtLmAsrBackend backend;

  /// Native CPU worker count.
  final int numberOfThreads;

  /// Maximum queued audio before native push backpressure is reported.
  final Duration maxBufferedAudio;

  /// Fraction of each inference window retained for transcript reconciliation.
  final double overlapRatio;

  /// Creates a LiteRT-LM ASR runtime configuration.
  const LiteRtLmAsrRuntimeConfig({
    required this.modelPath,
    required this.tokenizerPath,
    required this.modelPreset,
    this.backend = LiteRtLmAsrBackend.cpu,
    this.numberOfThreads = 4,
    this.maxBufferedAudio = const Duration(seconds: 30),
    this.overlapRatio = 0.4,
  });
}

/// Result of pushing PCM into a bounded native ASR session.
class LiteRtLmAsrPushResult {
  /// Number of samples accepted from the beginning of the supplied buffer.
  final int acceptedSamples;

  /// Whether the unaccepted suffix must be retried after processing a window.
  final bool wouldBlock;

  /// Creates a push result.
  const LiteRtLmAsrPushResult({
    required this.acceptedSamples,
    required this.wouldBlock,
  });
}

/// Native ASR processing state.
enum LiteRtLmAsrProcessState {
  /// A transcript update is available.
  update,

  /// More PCM must be pushed before another inference window can run.
  needsMoreAudio,

  /// The final result was already returned.
  endOfStream,
}

/// One native ASR processing result.
class LiteRtLmAsrProcessResult {
  /// Flow-control state.
  final LiteRtLmAsrProcessState state;

  /// Newly confirmed text that will not be revised by later windows.
  final String confirmedText;

  /// Current tentative text that may be replaced by the next update.
  final String unconfirmedText;

  /// Whether this update completes the input stream.
  final bool isFinal;

  /// Creates a processing result.
  const LiteRtLmAsrProcessResult({
    required this.state,
    this.confirmedText = '',
    this.unconfirmedText = '',
    this.isFinal = false,
  });
}

/// Synchronous low-level session implemented by the native runtime.
///
/// Calls that run inference may block and should be owned by a worker isolate.
abstract interface class LiteRtLmAsrRuntimeSession {
  /// Pushes mono 16 kHz float PCM into the bounded native queue.
  LiteRtLmAsrPushResult pushAudio(Float32List samples);

  /// Marks the input complete so a partial final window can be processed.
  void finishAudio();

  /// Runs at most one inference window.
  LiteRtLmAsrProcessResult processNext();

  /// Requests cancellation between native inference windows.
  void cancel();

  /// Resets transcript and audio state for a new stream.
  void reset();

  /// Releases native session resources.
  void dispose();
}
