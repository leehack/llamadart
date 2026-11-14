import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:record/record.dart';

import '../../app/platform_file_helper.dart';
import '../../app/studio_dependencies.dart';
import '../../app/studio_theme.dart';
import '../../widgets/code_syntax_highlighter.dart';
import '../../widgets/model_load_progress_banner.dart';
import '../../widgets/store_widgets.dart';
import '../../widgets/studio_motion.dart';

part 'notebook_panels.dart';
part 'notebook_layout.dart';
part 'notebook_rag_panel.dart';

/// Dedicated NotebookLM-style Multimodal Notebook workspace (`StudioWorkspace.notes`).
///
/// Combines live 16 kHz mono WAV microphone recording, local ASR transcription
/// (`Qwen3-ASR`), PNG/JPEG image & Markdown/code imports, `EmbeddingGemma 2`
/// multimodal vector indexing, optional `BGE Reranker` Stage-2 refinement, and
/// streaming source-grounded Q&A powered by the local Chat LLM.
class NotebookWorkspaceView extends StatefulWidget {
  /// Creates a [NotebookWorkspaceView].
  const NotebookWorkspaceView({super.key});

  @override
  State<NotebookWorkspaceView> createState() => _NotebookWorkspaceViewState();
}

class _NotebookWorkspaceViewState extends State<NotebookWorkspaceView> {
  final TextEditingController _searchCtrl = TextEditingController();
  final TextEditingController _titleCtrl = TextEditingController();
  final TextEditingController _tagsCtrl = TextEditingController();
  final TextEditingController _bodyCtrl = TextEditingController();
  final TextEditingController _transcriptCtrl = TextEditingController();

  final AudioPlayer _audioPlayer = AudioPlayer();
  final AudioRecorder _recorder = AudioRecorder();
  final Set<String> _tempPlaybackPaths = <String>{};

  StreamSubscription<void>? _playerCompleteSub;
  StreamSubscription<PlayerState>? _playerStateSub;
  final Stopwatch _recordingWatch = Stopwatch();
  Timer? _autoSaveTimer;
  StudioDependencies? _deps;

  String? _syncedNoteId;
  bool _noteDirty = false;
  int _noteEditRevision = 0;
  Future<void> _noteSaveQueue = Future<void>.value();
  bool _isRecordingMic = false;
  String? _playingNoteId;
  int _playbackSequence = 0;
  String? _cachedImageKey;
  Uint8List? _cachedImageBytes;
  String? _loadingImageKey;

  @override
  void initState() {
    super.initState();
    _playerCompleteSub = _audioPlayer.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() => _playingNoteId = null);
      }
    });
    _playerStateSub = _audioPlayer.onPlayerStateChanged.listen((
      PlayerState state,
    ) {
      if (!mounted) {
        return;
      }
      if ((state == PlayerState.stopped || state == PlayerState.completed) &&
          _playingNoteId != null) {
        setState(() => _playingNoteId = null);
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _deps = StudioScope.of(context);
  }

  @override
  void dispose() {
    _autoSaveTimer?.cancel();
    if (_noteDirty && _deps != null) {
      unawaited(_saveCurrentNote(_deps!, updateUi: false));
    }
    _searchCtrl.dispose();
    _titleCtrl.dispose();
    _tagsCtrl.dispose();
    _bodyCtrl.dispose();
    _transcriptCtrl.dispose();
    unawaited(_playerCompleteSub?.cancel() ?? Future<void>.value());
    unawaited(_playerStateSub?.cancel() ?? Future<void>.value());
    unawaited(_audioPlayer.dispose());
    unawaited(_recorder.dispose());
    for (final path in _tempPlaybackPaths) {
      unawaited(StudioPlatformFileHelper.deleteFileIfExists(path));
    }
    super.dispose();
  }

  Uint8List? _decodedImageFor(StudioDependencies deps, StudioNote note) {
    if (!note.hasImage) {
      _cachedImageKey = null;
      _cachedImageBytes = null;
      _loadingImageKey = null;
      return null;
    }
    final key =
        '${note.id}|${note.imageLocalPath ?? ''}|${note.imageBase64?.length ?? 0}';
    if (_cachedImageKey == key) {
      return _cachedImageBytes;
    }
    final encoded = note.imageBase64;
    if (encoded != null && encoded.isNotEmpty) {
      _cachedImageKey = key;
      _loadingImageKey = null;
      try {
        _cachedImageBytes = base64Decode(encoded);
      } catch (_) {
        _cachedImageBytes = null;
      }
      return _cachedImageBytes;
    }
    if (_loadingImageKey != key) {
      _loadingImageKey = key;
      unawaited(
        deps.notebookController.readNoteImageBytes(note).then((
          Uint8List? bytes,
        ) {
          if (!mounted || _loadingImageKey != key) {
            return;
          }
          setState(() {
            _cachedImageKey = key;
            _cachedImageBytes = bytes;
            _loadingImageKey = null;
          });
        }),
      );
    }
    return _cachedImageKey == key ? _cachedImageBytes : null;
  }

  static List<String> _parseCsvTags(String raw) {
    return raw
        .split(',')
        .map((String t) => t.trim())
        .where((String t) => t.isNotEmpty)
        .toSet()
        .toList(growable: false);
  }

  void _markNoteDirty(StudioDependencies deps) {
    final wasDirty = _noteDirty;
    _noteEditRevision++;
    _noteDirty = true;
    if (!wasDirty && mounted) {
      setState(() {});
    }
    _autoSaveTimer?.cancel();
    _autoSaveTimer = Timer(const Duration(milliseconds: 600), () {
      if (mounted) {
        unawaited(_saveCurrentNote(deps));
      }
    });
  }

  void _syncSelectedNoteControllers(StudioNote? selected) {
    if (selected == null) {
      if (_syncedNoteId != null) {
        _autoSaveTimer?.cancel();
        _syncedNoteId = null;
        _noteDirty = false;
        _titleCtrl.clear();
        _tagsCtrl.clear();
        _bodyCtrl.clear();
        _transcriptCtrl.clear();
      }
      return;
    }
    if (_syncedNoteId != selected.id) {
      _autoSaveTimer?.cancel();
      _syncedNoteId = selected.id;
      _noteDirty = false;
      _titleCtrl.text = selected.title;
      _tagsCtrl.text = selected.tags.join(', ');
      _bodyCtrl.text = selected.content;
      _transcriptCtrl.text = selected.transcript ?? '';
    } else if (!_noteDirty) {
      if (_titleCtrl.text != selected.title) {
        _titleCtrl.text = selected.title;
      }
      if (_bodyCtrl.text != selected.content) {
        _bodyCtrl.text = selected.content;
      }
      final tagsJoined = selected.tags.join(', ');
      if (_tagsCtrl.text != tagsJoined) {
        _tagsCtrl.text = tagsJoined;
      }
      final nextTranscript = selected.transcript ?? '';
      if (_transcriptCtrl.text != nextTranscript) {
        _transcriptCtrl.text = nextTranscript;
      }
    }
  }

  Future<void> _saveCurrentNote(
    StudioDependencies deps, {
    bool updateUi = true,
  }) async {
    _autoSaveTimer?.cancel();
    final targetId =
        _syncedNoteId ?? deps.notebookController.state.selectedNote?.id;
    if (targetId == null || !_noteDirty) {
      return;
    }
    final revision = _noteEditRevision;
    final title = _titleCtrl.text.trim().isEmpty
        ? 'Untitled Note'
        : _titleCtrl.text.trim();
    final content = _bodyCtrl.text;
    final tags = _parseCsvTags(_tagsCtrl.text);
    final transcript = _transcriptCtrl.text.trim();
    // Keep the draft protected from store snapshots until its write completes.
    // Serialize writes so an older save cannot overwrite a newer edit.
    _noteSaveQueue = _noteSaveQueue.catchError((Object _) {}).then((_) async {
      await deps.notebookController.updateNote(
        targetId,
        title: title,
        content: content,
        tags: tags,
        transcript: transcript.isEmpty ? null : transcript,
        clearTranscript: transcript.isEmpty,
      );
      if (_syncedNoteId == targetId && _noteEditRevision == revision) {
        _noteDirty = false;
        if (updateUi && mounted) {
          setState(() {});
        }
      }
    });
    await _noteSaveQueue;
    // A source switch must also persist edits made while its save was pending.
    if (mounted &&
        _syncedNoteId == targetId &&
        _noteDirty &&
        _noteEditRevision != revision) {
      await _saveCurrentNote(deps, updateUi: updateUi);
    }
  }

  Future<void> _toggleMicRecording(StudioDependencies deps) async {
    if (_isRecordingMic) {
      final recordedPath = await _recorder.stop();
      _recordingWatch.stop();
      final durationMs = _recordingWatch.elapsedMilliseconds;
      _recordingWatch.reset();
      if (mounted) {
        setState(() => _isRecordingMic = false);
      }
      if (recordedPath == null || recordedPath.isEmpty) {
        return;
      }
      final bytes = await StudioPlatformFileHelper.readBytesFromPath(
        recordedPath,
      );
      if (bytes == null || bytes.isEmpty) {
        return;
      }
      await _saveCurrentNote(deps);
      final now = DateTime.now();
      final hh = now.hour.toString().padLeft(2, '0');
      final mm = now.minute.toString().padLeft(2, '0');
      final created = await deps.notebookController.createNote(
        title: 'Voice Memo ($hh:$mm)',
        content: '',
        tags: const <String>['voice', 'recording'],
        sourceKind: StudioNoteSourceKind.audio,
        sourceFileName: 'voice_memo_$hh$mm.wav',
        audioWavBytes: bytes,
        audioDurationMs: durationMs > 0 ? durationMs : null,
      );
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(
              'Captured "${created.title}" (${(bytes.length / 1024).toStringAsFixed(0)} KB WAV)',
            ),
          ),
        );
      }
      return;
    }

    if (deps.isWeb) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(
            content: Text(
              'Live microphone WAV capture is available on native apps.',
            ),
          ),
        );
      }
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
    _recordingWatch
      ..reset()
      ..start();
    await _recorder.start(
      const RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: 16000,
        numChannels: 1,
        bitRate: 256000,
      ),
      path: tempPath,
    );
    if (mounted) {
      setState(() => _isRecordingMic = true);
    }
  }

  Future<void> _importImageNote(StudioDependencies deps) async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>['png', 'jpg', 'jpeg'],
      withData: true,
    );
    final file = res?.files.firstOrNull;
    if (file == null) {
      return;
    }
    var bytes = file.bytes;
    if (bytes == null && file.path != null) {
      bytes = await StudioPlatformFileHelper.readBytesFromPath(file.path!);
    }
    if (bytes == null || bytes.isEmpty) {
      return;
    }
    final lower = file.name.toLowerCase();
    final mime = lower.endsWith('.png') ? 'image/png' : 'image/jpeg';
    await _saveCurrentNote(deps);
    await deps.notebookController.createNote(
      title: file.name.replaceAll(RegExp(r'\.[^.]+$'), ''),
      content: 'Visual reference imported from ${file.name}.',
      tags: const <String>['image', 'multimodal'],
      sourceKind: StudioNoteSourceKind.image,
      sourceFileName: file.name,
      imageBytes: bytes,
      imageMimeType: mime,
    );
  }

  Future<void> _importTextOrAudioFile(StudioDependencies deps) async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>[
        'md',
        'txt',
        'dart',
        'json',
        'yaml',
        'yml',
        'wav',
      ],
      withData: true,
    );
    final file = res?.files.firstOrNull;
    if (file == null) {
      return;
    }
    var bytes = file.bytes;
    if (bytes == null && file.path != null) {
      bytes = await StudioPlatformFileHelper.readBytesFromPath(file.path!);
    }
    if (bytes == null || bytes.isEmpty) {
      return;
    }
    await _saveCurrentNote(deps);
    final lower = file.name.toLowerCase();
    if (lower.endsWith('.wav')) {
      await deps.notebookController.createNote(
        title: file.name.replaceAll(RegExp(r'\.[^.]+$'), ''),
        content: '',
        tags: const <String>['audio'],
        sourceKind: StudioNoteSourceKind.audio,
        sourceFileName: file.name,
        audioWavBytes: bytes,
      );
      return;
    }
    final text = utf8.decode(bytes, allowMalformed: true);
    await deps.notebookController.createNote(
      title: file.name,
      content: text,
      tags: const <String>['file'],
      sourceKind: StudioNoteSourceKind.file,
      sourceFileName: file.name,
    );
  }

  Future<void> _playOrStopNoteAudio(
    StudioDependencies deps,
    StudioNote note,
  ) async {
    if (!note.hasAudio) {
      return;
    }
    final seq = ++_playbackSequence;
    if (_playingNoteId == note.id) {
      try {
        await _audioPlayer.stop();
      } catch (_) {}
      if (mounted && _playbackSequence == seq) {
        setState(() => _playingNoteId = null);
      }
      return;
    }
    if (_playingNoteId != null) {
      try {
        await _audioPlayer.stop();
      } catch (_) {}
    }
    if (!mounted || _playbackSequence != seq) {
      return;
    }
    setState(() => _playingNoteId = note.id);
    try {
      final localAudioPath = note.audioLocalPath;
      if (!deps.isWeb &&
          localAudioPath != null &&
          localAudioPath.trim().isNotEmpty) {
        await _audioPlayer.play(
          DeviceFileSource(localAudioPath, mimeType: 'audio/wav'),
        );
        return;
      }
      final wavBytes = await deps.notebookController.readNoteAudioBytes(note);
      if (wavBytes == null || wavBytes.isEmpty) {
        throw StateError('Audio attachment bytes unavailable.');
      }
      final wavPath = await StudioPlatformFileHelper.writeTempWavFile(
        wavBytes,
        clipId: 'note_${note.id}',
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
        await _audioPlayer.play(BytesSource(wavBytes, mimeType: 'audio/wav'));
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      if (_playbackSequence == seq) {
        setState(() => _playingNoteId = null);
      }
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text('Audio playback failed: ${humanizeStudioError(error)}'),
        ),
      );
    }
  }

  Future<void> _sendVaultToChat(StudioDependencies deps) async {
    await _saveCurrentNote(deps);
    final ragPrompt = deps.notebookController.buildRagChatPrompt(
      _searchCtrl.text,
    );
    deps.chatController.setComposerDraft(ragPrompt);
    deps.shellController.selectWorkspace(StudioWorkspace.chat);
  }

  static IconData _iconForKind(StudioNoteSourceKind kind) => switch (kind) {
    StudioNoteSourceKind.text => Icons.description_outlined,
    StudioNoteSourceKind.audio => Icons.mic_none_rounded,
    StudioNoteSourceKind.image => Icons.image_outlined,
    StudioNoteSourceKind.file => Icons.code_rounded,
  };

  @override
  Widget build(BuildContext context) {
    final deps = StudioScope.of(context);
    final palette = StudioPalette.of(context);

    return StoreBuilder<ModelHubState>(
      store: deps.modelHubController.store,
      builder: (BuildContext context, ModelHubState hubState) {
        return StoreBuilder<StudioRuntimeSnapshot>(
          store: deps.modelHubController.runtimeStore,
          builder: (BuildContext context, StudioRuntimeSnapshot runtime) {
            return StoreBuilder<LabModelState>(
              store: deps.labModelCoordinator.store,
              builder: (BuildContext context, LabModelState labState) {
                return StoreBuilder<NotebookState>(
                  store: deps.notebookController.store,
                  builder: (BuildContext context, NotebookState state) {
                    _syncSelectedNoteControllers(state.selectedNote);
                    final embedders =
                        deps.notebookController.availableEmbedders;
                    final orderedNotes = state.orderedNotes;
                    final selectedNote = state.selectedNote;
                    final activeLoadingModel =
                        state.loadingModel ?? labState.loadingModel;
                    final isBusy = state.isBusy || labState.isLoadingModel;
                    final errorMessage =
                        state.errorMessage ?? labState.errorMessage;

                    return _buildNotebookLayout(
                      context,
                      deps,
                      palette,
                      hubState,
                      runtime,
                      labState,
                      state,
                      embedders: embedders,
                      orderedNotes: orderedNotes,
                      selectedNote: selectedNote,
                      activeLoadingModel: activeLoadingModel,
                      isBusy: isBusy,
                      errorMessage: errorMessage,
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }
}
