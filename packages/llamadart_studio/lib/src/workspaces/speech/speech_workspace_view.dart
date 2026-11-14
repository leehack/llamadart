import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:record/record.dart';

import '../../app/platform_file_helper.dart';
import '../../app/studio_dependencies.dart';
import '../../app/studio_theme.dart';
import '../../widgets/model_load_progress_banner.dart';
import '../../widgets/store_widgets.dart';
import '../../widgets/studio_motion.dart';

part 'speech_stt_card.dart';

/// Dedicated Speech Studio workspace for Neural TTS (`Qwen3-TTS` + speaker
/// reference voice cloning) and Neural STT (`Qwen3-ASR` & `Moonshine Tiny`).
class SpeechWorkspaceView extends StatefulWidget {
  /// Creates a [SpeechWorkspaceView].
  const SpeechWorkspaceView({super.key});

  @override
  State<SpeechWorkspaceView> createState() => _SpeechWorkspaceViewState();
}

class _SpeechWorkspaceViewState extends State<SpeechWorkspaceView> {
  final TextEditingController _ttsPromptCtrl = TextEditingController(
    text: 'Welcome to llamadart Studio. Neural speech synthesis is running 100% locally on your device.',
  );
  final TextEditingController _sttContextCtrl = TextEditingController();
  final AudioPlayer _audioPlayer = AudioPlayer();
  final AudioRecorder _recorder = AudioRecorder();
  final Set<String> _tempPlaybackPaths = <String>{};

  StreamSubscription<void>? _playerCompleteSub;
  StreamSubscription<PlayerState>? _playerStateSub;
  StudioModelDescriptor? _selectedTtsDescriptor;
  StudioModelDescriptor? _selectedSttDescriptor;
  String _ttsLanguage = 'Auto';
  double _ttsTemperature = 0.8;
  String? _speakerRefName;
  String? _speakerRefPath;
  Uint8List? _speakerRefBytes;
  bool _isRecordingMic = false;
  String? _playingClipId;
  int _playbackSequence = 0;

  static const List<String> _languages = <String>[
    'Auto',
    'English',
    'Korean',
    'Japanese',
    'Chinese',
    'Spanish',
    'French',
    'German',
  ];

  @override
  void initState() {
    super.initState();
    _playerCompleteSub = _audioPlayer.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() => _playingClipId = null);
      }
    });
    _playerStateSub = _audioPlayer.onPlayerStateChanged.listen((
      PlayerState state,
    ) {
      if (!mounted) {
        return;
      }
      if ((state == PlayerState.stopped || state == PlayerState.completed) &&
          _playingClipId != null) {
        setState(() => _playingClipId = null);
      }
    });
  }

  PageStorageBucket? _draftBucket;
  bool _draftRestored = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _draftBucket = PageStorage.maybeOf(context);
    if (_draftRestored) return;
    _draftRestored = true;
    final draft = _draftBucket?.readState(
      context,
      identifier: 'speech_draft',
    ) as Map<String, Object?>?;
    if (draft == null) return;
    _ttsPromptCtrl.value = draft['_ttsPromptCtrl']! as TextEditingValue;
    _sttContextCtrl.value = draft['_sttContextCtrl']! as TextEditingValue;
    _selectedTtsDescriptor =
        draft['_selectedTtsDescriptor'] as StudioModelDescriptor?;
    _selectedSttDescriptor =
        draft['_selectedSttDescriptor'] as StudioModelDescriptor?;
    _ttsLanguage = draft['_ttsLanguage'] as String;
    _ttsTemperature = draft['_ttsTemperature'] as double;
    _speakerRefName = draft['_speakerRefName'] as String?;
    _speakerRefPath = draft['_speakerRefPath'] as String?;
    _speakerRefBytes = draft['_speakerRefBytes'] as Uint8List?;
  }

  @override
  void deactivate() {
    _draftBucket?.writeState(context, <String, Object?>{
      '_ttsPromptCtrl': _ttsPromptCtrl.value,
      '_sttContextCtrl': _sttContextCtrl.value,
      '_selectedTtsDescriptor': _selectedTtsDescriptor,
      '_selectedSttDescriptor': _selectedSttDescriptor,
      '_ttsLanguage': _ttsLanguage,
      '_ttsTemperature': _ttsTemperature,
      '_speakerRefName': _speakerRefName,
      '_speakerRefPath': _speakerRefPath,
      '_speakerRefBytes': _speakerRefBytes,
    }, identifier: 'speech_draft');
    super.deactivate();
  }

  @override
  void dispose() {
    _ttsPromptCtrl.dispose();
    _sttContextCtrl.dispose();
    unawaited(_playerCompleteSub?.cancel() ?? Future<void>.value());
    unawaited(_playerStateSub?.cancel() ?? Future<void>.value());
    unawaited(_audioPlayer.dispose());
    unawaited(_recorder.dispose());
    for (final path in _tempPlaybackPaths) {
      unawaited(StudioPlatformFileHelper.deleteFileIfExists(path));
    }
    super.dispose();
  }

  Future<void> _pickSpeakerReference() async {
    final deps = StudioScope.of(context);
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>['wav', 'mp3', 'm4a', 'flac'],
      withData: true,
    );
    final file = res?.files.firstOrNull;
    if (file == null) {
      return;
    }
    setState(() {
      _speakerRefName = file.name;
      _speakerRefPath = deps.isWeb ? null : file.path;
      _speakerRefBytes = file.bytes;
    });
  }

  Future<void> _playOrStopClip(StudioSynthesizedClipEntry entry) async {
    final seq = ++_playbackSequence;
    if (_playingClipId == entry.id) {
      try {
        await _audioPlayer.stop();
      } catch (_) {
        // Ignore stop errors while resetting playback state.
      }
      if (mounted && _playbackSequence == seq) {
        setState(() => _playingClipId = null);
      }
      return;
    }

    if (_playingClipId != null) {
      try {
        await _audioPlayer.stop();
      } catch (_) {
        // Best-effort stop before switching clips.
      }
    }
    if (!mounted || _playbackSequence != seq) {
      return;
    }

    setState(() => _playingClipId = entry.id);
    try {
      final wavPath = await StudioPlatformFileHelper.writeTempWavFile(
        entry.clip.wavBytes,
        clipId: entry.id,
      );
      if (!mounted || _playbackSequence != seq) {
        return;
      }
      if (wavPath != null) {
        _tempPlaybackPaths.add(wavPath);
        await _audioPlayer.play(
          DeviceFileSource(wavPath, mimeType: 'audio/wav'),
        );
      } else {
        await _audioPlayer.play(
          BytesSource(entry.clip.wavBytes, mimeType: 'audio/wav'),
        );
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      if (_playbackSequence == seq) {
        setState(() => _playingClipId = null);
      }
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text('Audio playback failed: $error')));
    }
  }

  Future<void> _saveWavClip(StudioSynthesizedClipEntry entry) async {
    final path = await FilePicker.platform.saveFile(
      dialogTitle: 'Export Synthesized WAV',
      fileName: '${entry.id}.wav',
      bytes: entry.clip.wavBytes,
    );
    if (path != null && path.isNotEmpty) {
      await StudioPlatformFileHelper.writeBytesToPath(
        path,
        entry.clip.wavBytes,
      );
    }
  }

  Future<void> _pickAndTranscribeFile() async {
    final deps = StudioScope.of(context);
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>['wav', 'mp3', 'm4a', 'flac', 'ogg'],
      withData: true,
    );
    final file = res?.files.firstOrNull;
    if (file == null) {
      return;
    }
    await deps.speechController.transcribeAudio(
      audioBytes: file.bytes,
      audioFilePath: deps.isWeb ? null : file.path,
      contextPrompt: _sttContextCtrl.text.trim().isEmpty
          ? null
          : _sttContextCtrl.text.trim(),
    );
  }

  Future<void> _toggleMicRecording() async {
    final deps = StudioScope.of(context);
    if (_isRecordingMic) {
      final recordedPath = await _recorder.stop();
      setState(() => _isRecordingMic = false);
      if (recordedPath == null || recordedPath.isEmpty) {
        return;
      }
      final bytes = await StudioPlatformFileHelper.readBytesFromPath(
        recordedPath,
      );
      await deps.speechController.transcribeAudio(
        audioBytes: bytes,
        audioFilePath: deps.isWeb ? null : recordedPath,
        contextPrompt: _sttContextCtrl.text.trim().isEmpty
            ? null
            : _sttContextCtrl.text.trim(),
      );
      return;
    }

    if (!await _recorder.hasPermission()) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(content: Text('Microphone permission denied')),
        );
      }
      return;
    }
    final tempPath = await StudioPlatformFileHelper.createTempRecordingPath();
    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
      ),
      path: tempPath,
    );
    setState(() => _isRecordingMic = true);
  }

  @override
  Widget build(BuildContext context) {
    final deps = StudioScope.of(context);
    final palette = StudioPalette.of(context);

    return StoreBuilder<ModelHubState>(
      store: deps.modelHubController.store,
      builder: (BuildContext context, ModelHubState hubState) {
        final ttsCatalog = deps.speechController.availableTtsModels;
        final sttCatalog = deps.speechController.availableSttModels;
        final cachedIds = hubState.cachedModelIds;

        if (_selectedTtsDescriptor == null ||
            !ttsCatalog.any(
              (StudioModelDescriptor m) => m.id == _selectedTtsDescriptor!.id,
            )) {
          _selectedTtsDescriptor =
              ttsCatalog
                  .where((StudioModelDescriptor m) => cachedIds.contains(m.id))
                  .firstOrNull ??
              ttsCatalog.firstOrNull;
        } else {
          _selectedTtsDescriptor = ttsCatalog.firstWhere(
            (StudioModelDescriptor m) => m.id == _selectedTtsDescriptor!.id,
          );
        }
        if (_selectedSttDescriptor == null ||
            !sttCatalog.any(
              (StudioModelDescriptor m) => m.id == _selectedSttDescriptor!.id,
            )) {
          _selectedSttDescriptor =
              sttCatalog
                  .where((StudioModelDescriptor m) => cachedIds.contains(m.id))
                  .firstOrNull ??
              sttCatalog.firstOrNull;
        } else {
          _selectedSttDescriptor = sttCatalog.firstWhere(
            (StudioModelDescriptor m) => m.id == _selectedSttDescriptor!.id,
          );
        }

        return StoreBuilder<SpeechWorkspaceState>(
          store: deps.speechController.store,
          builder: (BuildContext context, SpeechWorkspaceState speechState) {
            return ListView(
              padding: const EdgeInsets.all(22),
              children: <Widget>[
                Text(
                  'Speech Studio',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: palette.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Neural Text-to-Speech synthesis with voice cloning and low-latency Speech-to-Text transcription.',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: palette.textSecondary,
                  ),
                ),
                if (speechState.loadingTtsModel != null) ...<Widget>[
                  const SizedBox(height: 12),
                  ModelLoadProgressBanner(
                    descriptor: speechState.loadingTtsModel!,
                  ),
                ],
                if (speechState.loadingSttModel != null) ...<Widget>[
                  const SizedBox(height: 12),
                  ModelLoadProgressBanner(
                    descriptor: speechState.loadingSttModel!,
                  ),
                ],
                if (speechState.errorMessage != null) ...<Widget>[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: palette.danger.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      speechState.errorMessage!,
                      style: TextStyle(fontSize: 12, color: palette.danger),
                    ),
                  ),
                ],
                const SizedBox(height: 18),
                LayoutBuilder(
                  builder: (BuildContext context, BoxConstraints constraints) {
                    final sideBySide = constraints.maxWidth >= 900;
                    final ttsPanel = _buildTtsCard(context, deps, speechState);
                    final sttPanel = _buildSttCard(context, deps, speechState);
                    if (sideBySide) {
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Expanded(child: ttsPanel),
                          const SizedBox(width: 16),
                          Expanded(child: sttPanel),
                        ],
                      );
                    }
                    return Column(
                      children: <Widget>[
                        ttsPanel,
                        const SizedBox(height: 16),
                        sttPanel,
                      ],
                    );
                  },
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildTtsCard(
    BuildContext context,
    StudioDependencies deps,
    SpeechWorkspaceState state,
  ) {
    final palette = StudioPalette.of(context);
    final models = deps.speechController.availableTtsModels;

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: palette.surfaceElevated,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: palette.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.record_voice_over_outlined, color: palette.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Neural Text-to-Speech',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: palette.textPrimary,
                  ),
                ),
              ),
              if (state.activeTtsModel != null)
                StudioPillBadge(
                  label: 'Ready',
                  foreground: palette.teal,
                  monospace: true,
                ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: DropdownButtonFormField<StudioModelDescriptor>(
                  key: ValueKey<String?>(_selectedTtsDescriptor?.id),
                  initialValue: _selectedTtsDescriptor,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'TTS Engine'),
                  items: models
                      .map(
                        (
                          StudioModelDescriptor m,
                        ) => DropdownMenuItem<StudioModelDescriptor>(
                          value: m,
                          child: Text(
                            '${m.name} (${m.sizeLabel(isWeb: deps.isWeb)})${deps.modelHubController.state.cachedModelIds.contains(m.id) ? ' · Installed' : ''}',
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12.5),
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: (StudioModelDescriptor? m) =>
                      setState(() => _selectedTtsDescriptor = m),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonal(
                onPressed: state.isLoadingTts || _selectedTtsDescriptor == null
                    ? null
                    : () => deps.speechController.loadTtsModel(
                        _selectedTtsDescriptor!,
                      ),
                child: Text(state.isLoadingTts ? 'Loading...' : 'Load'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _ttsPromptCtrl,
            maxLines: 4,
            decoration: const InputDecoration(labelText: 'Text to Synthesize'),
          ),
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints voiceBox) {
              final stackVoiceRow = voiceBox.maxWidth < 400;
              final languageDropdown = DropdownButtonFormField<String>(
                initialValue: _ttsLanguage,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Language'),
                items: _languages
                    .map(
                      (String lang) => DropdownMenuItem<String>(
                        value: lang,
                        child: Text(
                          lang,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12.5),
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (String? v) {
                  if (v != null) {
                    setState(() => _ttsLanguage = v);
                  }
                },
              );
              final cloneButton = OutlinedButton.icon(
                onPressed: _pickSpeakerReference,
                icon: const Icon(Icons.mic_external_on_outlined, size: 16),
                label: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: stackVoiceRow ? double.infinity : 155,
                  ),
                  child: Text(
                    _speakerRefName ?? 'Clone Voice WAV',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              );
              if (stackVoiceRow) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    languageDropdown,
                    const SizedBox(height: 8),
                    cloneButton,
                  ],
                );
              }
              return Row(
                children: <Widget>[
                  Expanded(child: languageDropdown),
                  const SizedBox(width: 10),
                  Flexible(flex: 0, child: cloneButton),
                ],
              );
            },
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  'Expressiveness',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: palette.textSecondary),
                ),
              ),
              Text(
                _ttsTemperature.toStringAsFixed(2),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: palette.accent,
                  fontFamilyFallback: StudioTheme.monoFontFallback,
                ),
              ),
            ],
          ),
          Slider(
            value: _ttsTemperature,
            min: 0.2,
            max: 1.2,
            divisions: 20,
            onChanged: (double v) => setState(() => _ttsTemperature = v),
          ),
          if (state.isSynthesizing) ...<Widget>[
            Text(
              state.ttsPhaseLabel ?? 'Synthesizing...',
              style: TextStyle(fontSize: 12, color: palette.teal),
            ),
            const SizedBox(height: 6),
            const LinearProgressIndicator(),
            const SizedBox(height: 8),
          ],
          Align(
            alignment: Alignment.centerRight,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                if (state.isSynthesizing)
                  TextButton(
                    onPressed: deps.speechController.cancelSynthesis,
                    child: const Text('Cancel'),
                  ),
                FilledButton.icon(
                  onPressed: state.isSynthesizing
                      ? null
                      : () => deps.speechController.synthesizeText(
                          text: _ttsPromptCtrl.text,
                          language: _ttsLanguage == 'Auto'
                              ? null
                              : _ttsLanguage.toLowerCase(),
                          speakerReferenceBytes: _speakerRefBytes,
                          speakerReferencePath: _speakerRefPath,
                          temperature: _ttsTemperature,
                        ),
                  icon: const Icon(Icons.spatial_audio_off_outlined, size: 16),
                  label: const Text('Synthesize WAV'),
                ),
              ],
            ),
          ),
          if (state.synthesizedHistory.isNotEmpty) ...<Widget>[
            Divider(height: 24, color: palette.borderSubtle),
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    'RECENT CLIPS (${state.synthesizedHistory.length})',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.7,
                      color: palette.textMuted,
                    ),
                  ),
                ),
                TextButton.icon(
                  key: const Key('clear_tts_history_button'),
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: deps.speechController.clearSynthesizedHistory,
                  icon: const Icon(Icons.delete_sweep_outlined, size: 15),
                  label: const Text('Clear'),
                ),
              ],
            ),
            Material(
              type: MaterialType.transparency,
              child: Column(
                children: <Widget>[
                  for (final clipEntry in state.synthesizedHistory)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      leading: IconButton(
                        onPressed: () => _playOrStopClip(clipEntry),
                        icon: Icon(
                          _playingClipId == clipEntry.id
                              ? Icons.stop_circle_rounded
                              : Icons.play_circle_fill_rounded,
                          color: palette.accent,
                        ),
                      ),
                      title: Text(
                        clipEntry.promptText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12.5),
                      ),
                      subtitle: Text(
                        '${(clipEntry.clip.duration.inMilliseconds / 1000).toStringAsFixed(1)}s · ${clipEntry.clip.sampleRateHz} Hz',
                        style: TextStyle(
                          fontSize: 11,
                          color: palette.textMuted,
                          fontFamilyFallback: StudioTheme.monoFontFallback,
                        ),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          IconButton(
                            tooltip: 'Save WAV',
                            visualDensity: VisualDensity.compact,
                            onPressed: () => _saveWavClip(clipEntry),
                            icon: const Icon(Icons.download_rounded, size: 17),
                          ),
                          IconButton(
                            key: Key('remove_tts_clip_${clipEntry.id}'),
                            tooltip: 'Remove clip',
                            visualDensity: VisualDensity.compact,
                            onPressed: () => deps.speechController
                                .removeSynthesizedClip(clipEntry.id),
                            icon: Icon(
                              Icons.delete_outline_rounded,
                              size: 16,
                              color: palette.textMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _updateState(VoidCallback fn) {
    if (mounted) {
      setState(fn);
    }
  }
}
