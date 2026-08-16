import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';

import 'live_speech_transcription_service_stub.dart'
    if (dart.library.io) 'live_speech_transcription_service_io.dart';

/// One replaceable live-transcription update.
class LiveSpeechTranscriptUpdate {
  /// Stable transcript prefix.
  final String confirmedText;

  /// Replaceable hypothesis for the current inference window.
  final String pendingText;

  /// Audio duration accepted by the native session.
  final Duration acceptedAudioDuration;

  /// Whether this update completes the stream.
  final bool isFinal;

  /// Creates a live transcript update.
  const LiveSpeechTranscriptUpdate({
    required this.confirmedText,
    required this.pendingText,
    required this.acceptedAudioDuration,
    required this.isFinal,
  });

  /// Current display text with confirmed and pending regions joined once.
  String get text => <String>[
    confirmedText.trim(),
    pendingText.trim(),
  ].where((part) => part.isNotEmpty).join(' ');
}

/// Terminal result from a live microphone transcription task.
class LiveSpeechTranscriptionResult {
  /// Final confirmed transcript.
  final String text;

  /// Audio duration accepted by the native session.
  final Duration acceptedAudioDuration;

  /// Creates a live transcription result.
  const LiveSpeechTranscriptionResult({
    required this.text,
    required this.acceptedAudioDuration,
  });
}

/// Active microphone and LiteRT-LM ASR session.
abstract class LiveSpeechTranscriptionTask {
  /// Confirmed and pending transcript updates.
  Stream<LiveSpeechTranscriptUpdate> get updates;

  /// Terminal completion, error, or cancellation.
  Future<LiveSpeechTranscriptionResult> get done;

  /// Stops capture and flushes the final partial window.
  Future<void> stop();

  /// Cancels capture and native inference without producing a draft.
  Future<void> cancel();
}

/// Captures mono PCM and runs the synchronous LiteRT-LM ASR session in a
/// worker isolate.
abstract class LiveSpeechTranscriptionService {
  /// Creates the platform implementation.
  factory LiveSpeechTranscriptionService() =>
      createLiveSpeechTranscriptionService();

  /// Whether microphone streaming and worker isolates are supported.
  bool get isSupported;

  /// Starts live transcription with a locally installed model and tokenizer.
  Future<LiveSpeechTranscriptionTask> start({
    required String modelPath,
    required String tokenizerPath,
    required LiteRtLmAsrModelPreset preset,
  });

  /// Releases the recorder and any active task.
  Future<void> dispose();
}

/// Converts little-endian signed PCM16 bytes to normalized float samples.
Float32List pcm16BytesToFloat32(Uint8List bytes) {
  if (bytes.length.isOdd) {
    throw const FormatException('PCM16 input must contain complete samples.');
  }
  final data = ByteData.sublistView(bytes);
  final samples = Float32List(bytes.length ~/ 2);
  for (var index = 0; index < samples.length; index++) {
    samples[index] = data.getInt16(index * 2, Endian.little) / 32768.0;
  }
  return samples;
}

/// Reassembles arbitrary byte chunks into complete little-endian PCM16
/// samples without dropping a split sample at a chunk boundary.
class Pcm16ByteStreamAligner {
  int? _pendingByte;

  /// Adds one byte chunk and returns the complete PCM16 sample bytes now
  /// available. The returned length is always even.
  Uint8List add(Uint8List bytes) {
    if (bytes.isEmpty) {
      return Uint8List(0);
    }
    final pending = _pendingByte;
    if (pending == null && bytes.length.isEven) {
      return bytes;
    }

    final joined = Uint8List(bytes.length + (pending == null ? 0 : 1));
    var offset = 0;
    if (pending != null) {
      joined[0] = pending;
      offset = 1;
      _pendingByte = null;
    }
    joined.setRange(offset, joined.length, bytes);
    if (joined.length.isOdd) {
      _pendingByte = joined.last;
      return Uint8List.sublistView(joined, 0, joined.length - 1);
    }
    return joined;
  }

  /// Verifies that the source stream ended on a complete PCM16 sample.
  void finish() {
    if (_pendingByte != null) {
      throw const FormatException(
        'PCM16 microphone stream ended with an incomplete sample.',
      );
    }
  }
}
