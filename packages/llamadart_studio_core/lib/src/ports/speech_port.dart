import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';
import 'package:meta/meta.dart';

import 'model_storage_port.dart';

/// Synthesized speech clip produced by [StudioSpeechPort].
@immutable
class StudioSynthesizedClip {
  /// Creates a [StudioSynthesizedClip].
  const StudioSynthesizedClip({
    required this.wavBytes,
    required this.duration,
    required this.sampleRateHz,
    required this.framesGenerated,
    this.truncated = false,
  });

  /// Standard 16-bit PCM WAV bytes ready for playback or saving.
  final Uint8List wavBytes;

  /// Audio playback duration.
  final Duration duration;

  /// Sample rate in Hertz.
  final int sampleRateHz;

  /// Codec frames generated.
  final int framesGenerated;

  /// Whether `maxFrames` truncated the output.
  final bool truncated;
}

/// Transcription result produced by [StudioSpeechPort].
@immutable
class StudioTranscriptResult {
  /// Creates a [StudioTranscriptResult].
  const StudioTranscriptResult({
    required this.text,
    required this.elapsedMs,
    this.detectedLanguage,
  });

  /// Recognized transcript text.
  final String text;

  /// Wall-clock transcription time in milliseconds.
  final int elapsedMs;

  /// Optional detected language code/name.
  final String? detectedLanguage;
}

/// Segregated neural Text-to-Speech port.
abstract interface class StudioTtsPort {
  /// Loads a TTS model from [assets].
  Future<TextToSpeechCapabilities> loadTtsModel({
    required ResolvedModelAssets assets,
    required bool isWeb,
  });

  /// Synthesizes [text] into a WAV audio clip, reporting frame progress via
  /// [onProgress].
  Future<StudioSynthesizedClip> synthesize({
    required String text,
    required bool isWeb,
    String? language,
    String? voice,
    Uint8List? speakerReferenceBytes,
    String? speakerReferencePath,
    double temperature = 0.8,
    void Function(int framesGenerated, TextToSpeechProgressPhase phase)?
    onProgress,
  });

  /// Cancels any active TTS synthesis task.
  void cancelSynthesis();

  /// Disposes loaded TTS engine resources.
  Future<void> dispose();
}

/// Segregated neural Speech-to-Text (ASR) port.
abstract interface class StudioSttPort {
  /// Loads an STT model from [assets].
  Future<SpeechToTextCapabilities> loadSttModel({
    required ResolvedModelAssets assets,
    required bool isWeb,
  });

  /// Transcribes an audio file or encoded byte buffer into text.
  Future<StudioTranscriptResult> transcribe({
    Uint8List? audioBytes,
    String? audioFilePath,
    String? contextPrompt,
  });

  /// Disposes loaded STT engine resources.
  Future<void> dispose();
}

/// Composite port wrapping both neural Text-to-Speech and Speech-to-Text
/// engines.
abstract interface class StudioSpeechPort
    implements StudioTtsPort, StudioSttPort {}
