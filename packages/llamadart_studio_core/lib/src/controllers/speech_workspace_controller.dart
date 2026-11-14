import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';
import 'package:meta/meta.dart';

import '../adapters/curated_studio_model_catalog.dart';
import '../domain/studio_model_descriptor.dart';
import '../ports/model_storage_port.dart';
import '../ports/speech_port.dart';
import '../ports/studio_context_ports.dart';
import '../reactive/state_store.dart';
import '../services/studio_error_formatter.dart';

/// Immutable state for the Speech Studio (TTS & STT) workspace.
@immutable
class SpeechWorkspaceState {
  /// Creates a [SpeechWorkspaceState].
  const SpeechWorkspaceState({
    this.activeTtsModel,
    this.activeSttModel,
    this.loadingTtsModel,
    this.loadingSttModel,
    this.ttsCapabilities,
    this.sttCapabilities,
    this.isLoadingTts = false,
    this.isLoadingStt = false,
    this.isSynthesizing = false,
    this.isTranscribing = false,
    this.framesGenerated = 0,
    this.ttsPhaseLabel,
    this.synthesizedHistory = const <StudioSynthesizedClipEntry>[],
    this.latestTranscript,
    this.errorMessage,
  });

  /// Loaded TTS model descriptor.
  final StudioModelDescriptor? activeTtsModel;

  /// Loaded STT model descriptor.
  final StudioModelDescriptor? activeSttModel;

  /// TTS model descriptor currently downloading or loading into memory.
  final StudioModelDescriptor? loadingTtsModel;

  /// STT model descriptor currently downloading or loading into memory.
  final StudioModelDescriptor? loadingSttModel;

  /// Capabilities of the loaded TTS engine.
  final TextToSpeechCapabilities? ttsCapabilities;

  /// Capabilities of the loaded STT engine.
  final SpeechToTextCapabilities? sttCapabilities;

  /// Whether a TTS model is downloading/loading.
  final bool isLoadingTts;

  /// Whether an STT model is downloading/loading.
  final bool isLoadingStt;

  /// Whether speech synthesis is running.
  final bool isSynthesizing;

  /// Whether speech transcription is running.
  final bool isTranscribing;

  /// Live codec frames generated in the active synthesis pass.
  final int framesGenerated;

  /// Active TTS phase description.
  final String? ttsPhaseLabel;

  /// Session history of synthesized WAV clips.
  final List<StudioSynthesizedClipEntry> synthesizedHistory;

  /// Most recent transcription result.
  final StudioTranscriptResult? latestTranscript;

  /// Optional error banner message.
  final String? errorMessage;

  /// Returns an updated copy of [SpeechWorkspaceState].
  SpeechWorkspaceState copyWith({
    StudioModelDescriptor? activeTtsModel,
    bool clearActiveTtsModel = false,
    StudioModelDescriptor? activeSttModel,
    bool clearActiveSttModel = false,
    StudioModelDescriptor? loadingTtsModel,
    bool clearLoadingTtsModel = false,
    StudioModelDescriptor? loadingSttModel,
    bool clearLoadingSttModel = false,
    TextToSpeechCapabilities? ttsCapabilities,
    SpeechToTextCapabilities? sttCapabilities,
    bool? isLoadingTts,
    bool? isLoadingStt,
    bool? isSynthesizing,
    bool? isTranscribing,
    int? framesGenerated,
    String? ttsPhaseLabel,
    bool clearTtsPhaseLabel = false,
    List<StudioSynthesizedClipEntry>? synthesizedHistory,
    StudioTranscriptResult? latestTranscript,
    String? errorMessage,
    bool clearErrorMessage = false,
  }) {
    return SpeechWorkspaceState(
      activeTtsModel: clearActiveTtsModel
          ? null
          : (activeTtsModel ?? this.activeTtsModel),
      activeSttModel: clearActiveSttModel
          ? null
          : (activeSttModel ?? this.activeSttModel),
      loadingTtsModel: clearLoadingTtsModel
          ? null
          : (loadingTtsModel ?? this.loadingTtsModel),
      loadingSttModel: clearLoadingSttModel
          ? null
          : (loadingSttModel ?? this.loadingSttModel),
      ttsCapabilities: ttsCapabilities ?? this.ttsCapabilities,
      sttCapabilities: sttCapabilities ?? this.sttCapabilities,
      isLoadingTts: isLoadingTts ?? this.isLoadingTts,
      isLoadingStt: isLoadingStt ?? this.isLoadingStt,
      isSynthesizing: isSynthesizing ?? this.isSynthesizing,
      isTranscribing: isTranscribing ?? this.isTranscribing,
      framesGenerated: framesGenerated ?? this.framesGenerated,
      ttsPhaseLabel: clearTtsPhaseLabel
          ? null
          : (ttsPhaseLabel ?? this.ttsPhaseLabel),
      synthesizedHistory: synthesizedHistory ?? this.synthesizedHistory,
      latestTranscript: latestTranscript ?? this.latestTranscript,
      errorMessage: clearErrorMessage
          ? null
          : (errorMessage ?? this.errorMessage),
    );
  }
}

/// Entry pairing synthesized WAV audio with prompt metadata.
@immutable
class StudioSynthesizedClipEntry {
  /// Creates a [StudioSynthesizedClipEntry].
  const StudioSynthesizedClipEntry({
    required this.id,
    required this.promptText,
    required this.clip,
    required this.createdAt,
    this.language,
  });

  /// Unique clip identifier.
  final String id;

  /// Input text synthesized.
  final String promptText;

  /// Generated WAV audio data.
  final StudioSynthesizedClip clip;

  /// Timestamp when created.
  final DateTime createdAt;

  /// Optional target language.
  final String? language;
}

/// Manages Neural Text-to-Speech and Speech-to-Text workflows in Speech Studio.
class SpeechWorkspaceController {
  int _clipSequence = 0;

  /// Creates a [SpeechWorkspaceController].
  ///
  /// Callers can pass a combined [speechPort] or segregated [ttsPort] /
  /// [sttPort] implementations.
  SpeechWorkspaceController({
    required StudioModelStoragePort storagePort,
    StudioSpeechPort? speechPort,
    StudioTtsPort? ttsPort,
    StudioSttPort? sttPort,
    StudioModelCatalog modelCatalog = const CuratedStudioModelCatalog(),
    required this.isWeb,
    required this.isMobile,
  }) : _storage = storagePort,
       _tts = ttsPort ?? speechPort,
       _stt = sttPort ?? speechPort,
       _catalog = modelCatalog {
    if (_tts == null && _stt == null) {
      throw ArgumentError(
        'Provide either speechPort or at least one of ttsPort / sttPort.',
      );
    }
  }

  final StudioModelStoragePort _storage;
  final StudioTtsPort? _tts;
  final StudioSttPort? _stt;
  final StudioModelCatalog _catalog;

  /// Whether running on WebGPU.
  final bool isWeb;

  /// Whether running on iOS/Android.
  final bool isMobile;

  final StateStore<SpeechWorkspaceState> _store =
      StateStore<SpeechWorkspaceState>(const SpeechWorkspaceState());

  /// Reactive Speech Studio store.
  ReadOnlyStore<SpeechWorkspaceState> get store => _store;

  /// Current Speech Studio state snapshot.
  SpeechWorkspaceState get state => _store.state;

  /// Available local + curated TTS models for the current host.
  List<StudioModelDescriptor> get availableTtsModels => <StudioModelDescriptor>[
    ..._storage.discoveredLocalModels.where(
      (StudioModelDescriptor m) =>
          m.supportsTextToSpeech &&
          m.isSupportedOn(isWeb: isWeb, isMobile: isMobile),
    ),
    ..._catalog
        .forCategory(
          StudioModelCategory.speech,
          isWeb: isWeb,
          isMobile: isMobile,
        )
        .where((StudioModelDescriptor m) => m.supportsTextToSpeech),
  ];

  /// Available local + curated STT models for the current host.
  List<StudioModelDescriptor> get availableSttModels => <StudioModelDescriptor>[
    ..._storage.discoveredLocalModels.where(
      (StudioModelDescriptor m) =>
          m.supportsSpeechToText &&
          m.isSupportedOn(isWeb: isWeb, isMobile: isMobile),
    ),
    ..._catalog
        .forCategory(
          StudioModelCategory.speech,
          isWeb: isWeb,
          isMobile: isMobile,
        )
        .where((StudioModelDescriptor m) => m.supportsSpeechToText),
  ];

  /// Downloads and loads [descriptor] as the active TTS model.
  Future<void> loadTtsModel(StudioModelDescriptor descriptor) async {
    final tts = _tts;
    if (tts == null) {
      _store.update(
        (SpeechWorkspaceState s) => s.copyWith(
          errorMessage: 'Text-to-Speech runtime is not configured.',
        ),
      );
      return;
    }
    _store.update(
      (SpeechWorkspaceState s) => s.copyWith(
        isLoadingTts: true,
        loadingTtsModel: descriptor,
        clearErrorMessage: true,
      ),
    );
    try {
      final assets = await _storage.ensureDownloaded(descriptor, isWeb: isWeb);
      final caps = await tts.loadTtsModel(assets: assets, isWeb: isWeb);
      _store.update(
        (SpeechWorkspaceState s) => s.copyWith(
          activeTtsModel: descriptor,
          ttsCapabilities: caps,
          isLoadingTts: false,
          clearLoadingTtsModel: true,
        ),
      );
    } catch (error) {
      _store.update(
        (SpeechWorkspaceState s) => s.copyWith(
          isLoadingTts: false,
          clearLoadingTtsModel: true,
          errorMessage: humanizeStudioError(error),
        ),
      );
    }
  }

  /// Downloads and loads [descriptor] as the active STT model.
  Future<void> loadSttModel(StudioModelDescriptor descriptor) async {
    final stt = _stt;
    if (stt == null) {
      _store.update(
        (SpeechWorkspaceState s) => s.copyWith(
          errorMessage: 'Speech-to-Text runtime is not configured.',
        ),
      );
      return;
    }
    _store.update(
      (SpeechWorkspaceState s) => s.copyWith(
        isLoadingStt: true,
        loadingSttModel: descriptor,
        clearErrorMessage: true,
      ),
    );
    try {
      final assets = await _storage.ensureDownloaded(descriptor, isWeb: isWeb);
      final caps = await stt.loadSttModel(assets: assets, isWeb: isWeb);
      _store.update(
        (SpeechWorkspaceState s) => s.copyWith(
          activeSttModel: descriptor,
          sttCapabilities: caps,
          isLoadingStt: false,
          clearLoadingSttModel: true,
        ),
      );
    } catch (error) {
      _store.update(
        (SpeechWorkspaceState s) => s.copyWith(
          isLoadingStt: false,
          clearLoadingSttModel: true,
          errorMessage: humanizeStudioError(error),
        ),
      );
    }
  }

  Future<void> _ensureCachedTtsLoaded() async {
    if (_store.state.activeTtsModel != null) {
      return;
    }
    for (final candidate in availableTtsModels) {
      if (await _storage.isCached(candidate, isWeb: isWeb)) {
        await loadTtsModel(candidate);
        return;
      }
    }
  }

  Future<void> _ensureCachedSttLoaded() async {
    if (_store.state.activeSttModel != null) {
      return;
    }
    for (final candidate in availableSttModels) {
      if (await _storage.isCached(candidate, isWeb: isWeb)) {
        await loadSttModel(candidate);
        return;
      }
    }
  }

  /// Synthesizes [text] into WAV audio.
  Future<StudioSynthesizedClipEntry?> synthesizeText({
    required String text,
    String? language,
    String? voice,
    Uint8List? speakerReferenceBytes,
    String? speakerReferencePath,
    double temperature = 0.8,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || _store.state.isSynthesizing) {
      return null;
    }
    final tts = _tts;
    if (tts == null) {
      _store.update(
        (SpeechWorkspaceState s) => s.copyWith(
          errorMessage: 'Text-to-Speech runtime is not configured.',
        ),
      );
      return null;
    }
    await _ensureCachedTtsLoaded();
    if (_store.state.errorMessage != null &&
        _store.state.activeTtsModel == null) {
      return null;
    }
    _store.update(
      (SpeechWorkspaceState s) => s.copyWith(
        isSynthesizing: true,
        framesGenerated: 0,
        ttsPhaseLabel: 'Processing prompt...',
        clearErrorMessage: true,
      ),
    );

    try {
      final clip = await tts.synthesize(
        text: trimmed,
        isWeb: isWeb,
        language: language,
        voice: voice,
        speakerReferenceBytes: speakerReferenceBytes,
        speakerReferencePath: speakerReferencePath,
        temperature: temperature,
        onProgress: (int frames, TextToSpeechProgressPhase phase) {
          _store.update(
            (SpeechWorkspaceState s) => s.copyWith(
              framesGenerated: frames,
              ttsPhaseLabel: phase == TextToSpeechProgressPhase.processingPrompt
                  ? 'Encoding text & speaker reference...'
                  : 'Generating codec frames ($frames)...',
            ),
          );
        },
      );
      final entry = StudioSynthesizedClipEntry(
        id: 'tts_${DateTime.now().microsecondsSinceEpoch}_${++_clipSequence}',
        promptText: trimmed,
        clip: clip,
        createdAt: DateTime.now(),
        language: language,
      );
      _store.update(
        (SpeechWorkspaceState s) => s.copyWith(
          isSynthesizing: false,
          clearTtsPhaseLabel: true,
          synthesizedHistory: <StudioSynthesizedClipEntry>[
            entry,
            ...s.synthesizedHistory,
          ].take(maxHistoryItems).toList(growable: false),
        ),
      );
      return entry;
    } catch (error) {
      _store.update(
        (SpeechWorkspaceState s) => s.copyWith(
          isSynthesizing: false,
          clearTtsPhaseLabel: true,
          errorMessage: humanizeStudioError(error),
        ),
      );
      return null;
    }
  }

  /// Maximum synthesized WAV clips retained in RAM per session.
  static const int maxHistoryItems = 24;

  /// Removes a single synthesized clip from the in-memory session history.
  void removeSynthesizedClip(String clipId) {
    _store.update(
      (SpeechWorkspaceState s) => s.copyWith(
        synthesizedHistory: s.synthesizedHistory
            .where((StudioSynthesizedClipEntry c) => c.id != clipId)
            .toList(growable: false),
      ),
    );
  }

  /// Clears all synthesized clips from the in-memory session history.
  void clearSynthesizedHistory() {
    _store.update(
      (SpeechWorkspaceState s) =>
          s.copyWith(synthesizedHistory: const <StudioSynthesizedClipEntry>[]),
    );
  }

  /// Cancels active speech synthesis.
  void cancelSynthesis() {
    _tts?.cancelSynthesis();
  }

  /// Transcribes an audio file or byte buffer.
  Future<StudioTranscriptResult?> transcribeAudio({
    Uint8List? audioBytes,
    String? audioFilePath,
    String? contextPrompt,
  }) async {
    if (_store.state.isTranscribing) {
      return null;
    }
    final stt = _stt;
    if (stt == null) {
      _store.update(
        (SpeechWorkspaceState s) => s.copyWith(
          errorMessage: 'Speech-to-Text runtime is not configured.',
        ),
      );
      return null;
    }
    await _ensureCachedSttLoaded();
    if (_store.state.errorMessage != null &&
        _store.state.activeSttModel == null) {
      return null;
    }
    _store.update(
      (SpeechWorkspaceState s) =>
          s.copyWith(isTranscribing: true, clearErrorMessage: true),
    );
    try {
      final result = await stt.transcribe(
        audioBytes: audioBytes,
        audioFilePath: audioFilePath,
        contextPrompt: contextPrompt,
      );
      _store.update(
        (SpeechWorkspaceState s) =>
            s.copyWith(isTranscribing: false, latestTranscript: result),
      );
      return result;
    } catch (error) {
      _store.update(
        (SpeechWorkspaceState s) => s.copyWith(
          isTranscribing: false,
          errorMessage: humanizeStudioError(error),
        ),
      );
      return null;
    }
  }

  /// Unloads active TTS and STT engines from memory.
  Future<void> unloadModels() async {
    await _tts?.dispose();
    if (_stt != null && !identical(_stt, _tts)) {
      await _stt.dispose();
    }
    _store.update(
      (SpeechWorkspaceState s) =>
          s.copyWith(clearActiveTtsModel: true, clearActiveSttModel: true),
    );
  }

  /// Disposes internal reactive state.
  Future<void> dispose() => _store.dispose();
}
