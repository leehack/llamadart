import 'dart:async';
import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';

import '../../domain/studio_model_descriptor.dart';
import '../../ports/model_storage_port.dart';
import '../../ports/speech_port.dart';

/// Production [StudioSpeechPort] powered by `llamadart`'s [TextToSpeechEngine]
/// and [SpeechToTextEngine].
class DirectLlamaSpeechPort implements StudioSpeechPort {
  /// Creates a [DirectLlamaSpeechPort].
  DirectLlamaSpeechPort();

  TextToSpeechEngine? _ttsEngine;
  SpeechToTextEngine? _sttEngine;
  TextToSpeechTask? _activeTtsTask;

  @override
  Future<TextToSpeechCapabilities> loadTtsModel({
    required ResolvedModelAssets assets,
    required bool isWeb,
  }) async {
    await _ttsEngine?.dispose();
    _ttsEngine = null;
    final projector = assets.companionSources['projector'];
    final engine = await TextToSpeechEngine.load(
      TextToSpeechModel(
        assets.primarySource,
        projector: projector,
        adapter: const Qwen3TtsAdapter(),
      ),
      params: LlamaCppModelParams(
        contextSize: assets.descriptor.preset.contextSize,
        modelBytesHint: isWeb
            ? assets.descriptor.effectiveSizeBytes(isWeb: true)
            : null,
      ),
      backend: LlamaBackend.withTextHistory(),
    );
    _ttsEngine = engine;
    return engine.capabilities;
  }

  @override
  Future<SpeechToTextCapabilities> loadSttModel({
    required ResolvedModelAssets assets,
    required bool isWeb,
  }) async {
    await _sttEngine?.dispose();
    _sttEngine = null;

    final descriptor = assets.descriptor;
    final SpeechToTextModel sttModel;
    if (descriptor.specialty == StudioModelSpecialty.liteRtAsr) {
      final preset =
          descriptor.liteRtAsrPreset ?? LiteRtLmAsrModelPreset.moonshineTiny;
      sttModel = SpeechToTextModel(
        assets.primarySource,
        tokenizer: assets.companionSources['tokenizer'],
        adapter: LiteRtLmAsrAdapter(preset),
      );
    } else {
      sttModel = SpeechToTextModel(
        assets.primarySource,
        projector: assets.companionSources['projector'],
        adapter: const Qwen3AsrAdapter(),
      );
    }

    final engine = await SpeechToTextEngine.load(
      sttModel,
      params: descriptor.specialty == StudioModelSpecialty.liteRtAsr
          ? null
          : LlamaCppModelParams(
              contextSize: descriptor.preset.contextSize,
              modelBytesHint: isWeb
                  ? descriptor.effectiveSizeBytes(isWeb: true)
                  : null,
            ),
      backend: LlamaBackend.withTextHistory(),
    );
    _sttEngine = engine;
    return engine.capabilities;
  }

  @override
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
  }) async {
    final engine = _ttsEngine;
    if (engine == null) {
      throw LlamaStateException('Load a TTS model before synthesizing.');
    }

    SpeechAudioInput? speakerRef;
    if (speakerReferenceBytes != null && speakerReferenceBytes.isNotEmpty) {
      speakerRef = SpeechAudioBytesInput(speakerReferenceBytes);
    } else if (!isWeb &&
        speakerReferencePath != null &&
        speakerReferencePath.isNotEmpty) {
      speakerRef = SpeechAudioFileInput(speakerReferencePath);
    }

    final cleanLang = (language == null || language.trim().isEmpty)
        ? null
        : language.trim();
    final cleanVoice =
        (speakerRef != null || voice == null || voice.trim().isEmpty)
        ? null
        : voice.trim();

    final task = await engine.synthesize(
      TextToSpeechRequest(
        text: text,
        language: cleanLang,
        voice: cleanVoice,
        speakerReference: speakerRef,
        maxFrames: isWeb ? 128 : 512,
        temperature: temperature,
      ),
    );
    _activeTtsTask = task;

    final sub = task.events.listen((TextToSpeechEvent event) {
      if (event is TextToSpeechProgressEvent && onProgress != null) {
        onProgress(event.framesGenerated, event.phase);
      }
    });

    try {
      final result = await task.result;
      return StudioSynthesizedClip(
        wavBytes: result.toWavBytes(),
        duration: result.duration,
        sampleRateHz: result.sampleRateHz,
        framesGenerated: result.framesGenerated,
        truncated: result.truncated,
      );
    } finally {
      await sub.cancel();
      if (identical(_activeTtsTask, task)) {
        _activeTtsTask = null;
      }
    }
  }

  @override
  void cancelSynthesis() {
    _activeTtsTask?.cancel();
  }

  @override
  Future<StudioTranscriptResult> transcribe({
    Uint8List? audioBytes,
    String? audioFilePath,
    String? contextPrompt,
  }) async {
    final engine = _sttEngine;
    if (engine == null) {
      throw LlamaStateException(
        'Load a Speech-to-Text model before transcribing.',
      );
    }

    final SpeechAudioInput input;
    if (audioFilePath != null && audioFilePath.isNotEmpty) {
      input = SpeechAudioFileInput(audioFilePath);
    } else if (audioBytes != null && audioBytes.isNotEmpty) {
      input = SpeechAudioBytesInput(audioBytes);
    } else {
      throw LlamaArgumentException('Provide an audio file or byte clip.');
    }

    final watch = Stopwatch()..start();
    final result = await engine.transcribeOnce(
      SpeechToTextRequest(
        audio: input,
        contextPrompt: (contextPrompt == null || contextPrompt.trim().isEmpty)
            ? null
            : contextPrompt.trim(),
      ),
    );
    watch.stop();

    return StudioTranscriptResult(
      text: result.text,
      elapsedMs: watch.elapsedMilliseconds,
      detectedLanguage: result.language,
    );
  }

  @override
  Future<void> dispose() async {
    _activeTtsTask?.cancel();
    _activeTtsTask = null;
    await _ttsEngine?.dispose();
    _ttsEngine = null;
    await _sttEngine?.dispose();
    _sttEngine = null;
  }
}
