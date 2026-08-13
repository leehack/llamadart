import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:llamadart/llamadart.dart';
import 'package:provider/provider.dart';

import '../providers/chat_provider.dart';
import '../services/clipboard_attachment_service.dart';
import '../services/speech_playback_service.dart';
import 'tool_declarations_dialog.dart';

class ChatInput extends StatefulWidget {
  final VoidCallback onSend;
  final TextEditingController controller;
  final FocusNode focusNode;

  /// Optional playback adapter used by deterministic widget tests.
  final SpeechPlaybackService? speechPlaybackService;

  const ChatInput({
    super.key,
    required this.onSend,
    required this.controller,
    required this.focusNode,
    this.speechPlaybackService,
  });

  @override
  State<ChatInput> createState() => _ChatInputState();
}

class _ChatInputState extends State<ChatInput> {
  final ClipboardAttachmentService _clipboardAttachments =
      ClipboardAttachmentService();
  bool _hasDraftText = false;
  late final SpeechPlaybackService _speechPlayer;
  StreamSubscription<void>? _speechCompleteSubscription;
  bool _isPlayingSpeech = false;
  bool _speechPlaybackStopScheduled = false;
  TextToSpeechResult? _playingSpeechResult;
  String? _textToSpeechLanguage;
  SpeechAudioInput? _speakerReference;
  String? _speakerReferenceName;

  @override
  void initState() {
    super.initState();
    _hasDraftText = widget.controller.text.trim().isNotEmpty;
    _speechPlayer = widget.speechPlaybackService ?? SpeechPlaybackService();
    _speechCompleteSubscription = _speechPlayer.onComplete.listen((_) {
      if (mounted) {
        setState(() {
          _isPlayingSpeech = false;
          _playingSpeechResult = null;
        });
      }
    });
    widget.controller.addListener(_onTextChanged);
    _clipboardAttachments.registerPasteEventListener(_onPasteEvent);
  }

  @override
  void didUpdateWidget(covariant ChatInput oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onTextChanged);
      widget.controller.addListener(_onTextChanged);
      _onTextChanged();
    }
  }

  @override
  void dispose() {
    _clipboardAttachments.unregisterPasteEventListener(_onPasteEvent);
    widget.controller.removeListener(_onTextChanged);
    unawaited(_speechCompleteSubscription?.cancel());
    unawaited(_speechPlayer.dispose());
    super.dispose();
  }

  void _onTextChanged() {
    final hasText = widget.controller.text.trim().isNotEmpty;
    if (hasText == _hasDraftText || !mounted) return;

    setState(() {
      _hasDraftText = hasText;
    });
  }

  bool _supportsDesktopShortcuts(TargetPlatform platform) {
    return platform == TargetPlatform.macOS ||
        platform == TargetPlatform.windows ||
        platform == TargetPlatform.linux;
  }

  bool _allowsImage(ChatProvider provider) {
    return provider.supportsVision ||
        (provider.canAttachMedia &&
            !provider.supportsVision &&
            !provider.supportsAudio);
  }

  Future<void> _onPasteEvent(ClipboardPasteReader readClipboard) async {
    if (!mounted || !widget.focusNode.hasFocus) {
      return;
    }
    final provider = context.read<ChatProvider>();
    if (!provider.canAttachMedia) {
      return;
    }

    try {
      final allowImage = _allowsImage(provider);
      final allowAudio = provider.supportsAudio;
      final content = _clipboardAttachments.selectSupportedContent(
        await readClipboard(allowImage: allowImage, allowAudio: allowAudio),
        allowImage: allowImage,
        allowAudio: allowAudio,
      );
      await _handlePasteContent(provider, content, allowTextFallback: true);
    } catch (error) {
      _showClipboardError(error);
    }
  }

  Future<void> _pasteFromSystemClipboard(
    ChatProvider provider, {
    required bool allowTextFallback,
    required bool showUnsupportedMessage,
  }) async {
    try {
      final content = await _clipboardAttachments.readSystemClipboard(
        allowImage: _allowsImage(provider),
        allowAudio: provider.supportsAudio,
        allowText: allowTextFallback,
      );
      if (!mounted) {
        return;
      }
      if (content == null) {
        if (showUnsupportedMessage) {
          _showMessage('Clipboard access is not available on this platform.');
        }
        return;
      }
      final handled = await _handlePasteContent(
        provider,
        content,
        allowTextFallback: allowTextFallback,
      );
      if (!handled && showUnsupportedMessage) {
        _showMessage('Clipboard has no supported image or audio attachment.');
      }
    } catch (error) {
      _showClipboardError(error);
    }
  }

  Future<bool> _handlePasteContent(
    ChatProvider provider,
    ClipboardPasteContent content, {
    required bool allowTextFallback,
  }) async {
    final attachment = content.attachment;
    if (attachment != null) {
      final staged = switch (attachment.kind) {
        ClipboardAttachmentKind.image => await provider.stageImageAttachment(
          attachment.bytes,
        ),
        ClipboardAttachmentKind.audio => provider.stageAudioAttachment(
          attachment.bytes,
        ),
      };
      if (staged) {
        return true;
      }
    }

    final text = content.plainText;
    if (allowTextFallback && text != null) {
      _insertTextAtSelection(text);
      return true;
    }
    return false;
  }

  void _insertTextAtSelection(String text) {
    final value = widget.controller.value;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    final nextText = value.text.replaceRange(
      selection.start,
      selection.end,
      text,
    );
    widget.controller.value = value.copyWith(
      text: nextText,
      selection: TextSelection.collapsed(offset: selection.start + text.length),
      composing: TextRange.empty,
    );
  }

  void _showClipboardError(Object error) {
    if (!mounted) {
      return;
    }
    final message = error is ClipboardAttachmentException
        ? error.message
        : 'Could not read the clipboard attachment.';
    _showMessage(message);
  }

  void _showMessage(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _submit(ChatProvider provider) async {
    if (!provider.supportsTextToSpeech) {
      widget.onSend();
      return;
    }
    final text = widget.controller.text.trim();
    if (text.isEmpty) {
      return;
    }
    final accepted = await provider.synthesizeSpeech(
      text,
      language: _textToSpeechLanguage,
      speakerReference: provider.recordedSpeakerReference ?? _speakerReference,
    );
    if (!mounted || !accepted) {
      return;
    }
    widget.controller.clear();
    widget.focusNode.requestFocus();
    final result = provider.textToSpeechResult;
    if (result != null) {
      await _playSynthesizedSpeech(result, replaceCurrent: true);
    }
  }

  Future<void> _pickSpeakerReference() async {
    try {
      final selection = await FilePicker.platform.pickFiles(
        type: FileType.audio,
        allowMultiple: false,
        withData: kIsWeb,
      );
      if (!mounted || selection == null || selection.files.isEmpty) {
        return;
      }
      final file = selection.files.single;
      final path = file.path;
      final bytes = file.bytes;
      final SpeechAudioInput? input = path != null && path.isNotEmpty
          ? SpeechAudioFileInput(path)
          : bytes != null && bytes.isNotEmpty
          ? SpeechAudioBytesInput(bytes)
          : null;
      if (input == null) {
        _showMessage('Could not read the selected speaker reference.');
        return;
      }
      setState(() {
        _speakerReference = input;
        _speakerReferenceName = file.name;
      });
      context.read<ChatProvider>().clearRecordedSpeakerReference();
    } catch (_) {
      _showMessage('Could not open the speaker reference audio.');
    }
  }

  Future<void> _startSpeakerReferenceRecording(ChatProvider provider) async {
    await provider.startAudioRecording(
      purpose: ChatAudioRecordingPurpose.speakerReference,
    );
    if (!mounted ||
        provider.audioRecordingState != ChatAudioRecordingState.recording ||
        provider.audioRecordingPurpose !=
            ChatAudioRecordingPurpose.speakerReference) {
      return;
    }
    setState(() {
      _speakerReference = null;
      _speakerReferenceName = null;
    });
    provider.clearRecordedSpeakerReference();
  }

  Future<void> _playSynthesizedSpeech(
    TextToSpeechResult result, {
    bool replaceCurrent = false,
  }) async {
    try {
      if (_isPlayingSpeech) {
        await _stopSynthesizedSpeechPlayback();
        if (!replaceCurrent) {
          return;
        }
      }
      await _speechPlayer.playWav(result.toWavBytes());
      if (mounted) {
        setState(() {
          _isPlayingSpeech = true;
          _playingSpeechResult = result;
        });
      }
    } catch (_) {
      _showMessage('Could not play the synthesized audio.');
    }
  }

  Future<void> _stopSynthesizedSpeechPlayback() async {
    await _speechPlayer.stop();
    if (mounted) {
      setState(() {
        _isPlayingSpeech = false;
        _playingSpeechResult = null;
      });
    }
  }

  void _synchronizeSynthesizedSpeechPlayback(TextToSpeechResult? result) {
    if (!_isPlayingSpeech ||
        identical(result, _playingSpeechResult) ||
        _speechPlaybackStopScheduled) {
      return;
    }
    _speechPlaybackStopScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        await _stopSynthesizedSpeechPlayback();
      } finally {
        _speechPlaybackStopScheduled = false;
      }
    });
  }

  Future<void> _clearSynthesizedSpeech(ChatProvider provider) async {
    if (_isPlayingSpeech) {
      await _stopSynthesizedSpeechPlayback();
    }
    provider.clearSynthesizedSpeech();
  }

  Future<void> _saveSynthesizedSpeech(TextToSpeechResult result) async {
    try {
      final savedPath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save synthesized speech',
        fileName: 'llamadart-speech.wav',
        type: FileType.custom,
        allowedExtensions: const <String>['wav'],
        bytes: result.toWavBytes(),
      );
      if (mounted && savedPath != null) {
        _showMessage('Saved synthesized speech.');
      }
    } catch (_) {
      _showMessage('Could not save the synthesized WAV file.');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ChatProvider>(
      builder: (context, provider, _) {
        _synchronizeSynthesizedSpeechPlayback(provider.textToSpeechResult);
        final isGenerating = provider.isGenerating;
        final hasActiveAudioRecording = provider.hasActiveAudioRecording;
        final isReady = provider.isReady;
        final stagedParts = provider.stagedParts;
        final hasAttachments = stagedParts.isNotEmpty;
        final canSubmit =
            !isGenerating &&
            !hasActiveAudioRecording &&
            isReady &&
            (provider.supportsTextToSpeech
                ? _hasDraftText && provider.canSynthesizeSpeech
                : (_hasDraftText || hasAttachments));
        final sendActionLabel = isGenerating
            ? provider.isSynthesizingSpeech
                  ? 'Cancel speech synthesis'
                  : 'Stop generation'
            : provider.supportsTextToSpeech
            ? 'Synthesize speech'
            : 'Send message';
        final colorScheme = Theme.of(context).colorScheme;
        final platform = Theme.of(context).platform;
        final width = MediaQuery.sizeOf(context).width;
        final isDesktop = width >= 900;
        final useDesktopShortcuts =
            isDesktop && _supportsDesktopShortcuts(platform);
        final usesMetaPaste =
            platform == TargetPlatform.macOS || platform == TargetPlatform.iOS;
        final safeBottom = MediaQuery.paddingOf(context).bottom;
        final microphoneActionLabel =
            provider.settings.modelSupportsSpeechToText
            ? 'Record for transcription.'
            : 'Ask with voice. Records up to 30 seconds.';
        final VoidCallback? startAudioRecordingAction =
            provider.canStartAudioRecording
            ? () => unawaited(provider.startAudioRecording())
            : null;
        final shortcutBindings = <ShortcutActivator, VoidCallback>{
          const SingleActivator(
            LogicalKeyboardKey.enter,
            control: true,
            includeRepeats: false,
          ): () {
            if (canSubmit) {
              unawaited(_submit(provider));
            }
          },
          const SingleActivator(
            LogicalKeyboardKey.enter,
            meta: true,
            includeRepeats: false,
          ): () {
            if (canSubmit) {
              unawaited(_submit(provider));
            }
          },
          if (!kIsWeb && provider.canAttachMedia) ...{
            if (usesMetaPaste)
              const SingleActivator(
                LogicalKeyboardKey.keyV,
                meta: true,
                includeRepeats: false,
              ): () => unawaited(
                _pasteFromSystemClipboard(
                  provider,
                  allowTextFallback: true,
                  showUnsupportedMessage: false,
                ),
              ),
            if (!usesMetaPaste)
              const SingleActivator(
                LogicalKeyboardKey.keyV,
                control: true,
                includeRepeats: false,
              ): () => unawaited(
                _pasteFromSystemClipboard(
                  provider,
                  allowTextFallback: true,
                  showUnsupportedMessage: false,
                ),
              ),
          },
        };

        return Container(
          padding: EdgeInsets.fromLTRB(
            isDesktop ? 22 : 12,
            10,
            isDesktop ? 22 : 12,
            (isDesktop ? 14 : 10) + safeBottom,
          ),
          child: Align(
            alignment: Alignment.bottomCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 920),
              child: Container(
                padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(isDesktop ? 20 : 18),
                  border: Border.all(
                    color: colorScheme.outlineVariant.withValues(alpha: 0.5),
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (provider.toolsEnabled) ...[
                      _buildFunctionCallingRow(context, provider),
                      const SizedBox(height: 10),
                    ],
                    if (provider.supportsTextToSpeech) ...[
                      _buildTextToSpeechOptions(context, provider),
                      const SizedBox(height: 8),
                    ],
                    if (provider.textToSpeechResult != null ||
                        provider.textToSpeechError != null) ...[
                      _buildTextToSpeechOutput(context, provider),
                      const SizedBox(height: 8),
                    ],
                    if (hasActiveAudioRecording) ...[
                      _buildAudioRecordingRow(context, provider),
                      const SizedBox(height: 8),
                    ],
                    if (hasAttachments)
                      _buildStagedPartsStrip(context, provider, stagedParts),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        if (provider.canAttachMedia && !hasActiveAudioRecording)
                          _buildAttachmentMenu(context, provider),
                        if (provider.supportsMicrophoneRecording)
                          Semantics(
                            label: microphoneActionLabel,
                            button: true,
                            enabled: provider.canStartAudioRecording,
                            onTap: startAudioRecordingAction,
                            excludeSemantics: true,
                            child: IconButton(
                              key: const ValueKey<String>(
                                'record_audio_button',
                              ),
                              tooltip:
                                  provider.settings.modelSupportsSpeechToText
                                  ? 'Record for transcription'
                                  : 'Ask with voice',
                              onPressed: startAudioRecordingAction,
                              icon: Icon(
                                Icons.mic_none_rounded,
                                color: provider.canStartAudioRecording
                                    ? colorScheme.primary
                                    : null,
                              ),
                            ),
                          ),
                        Expanded(
                          child: CallbackShortcuts(
                            bindings: shortcutBindings,
                            child: TextField(
                              controller: widget.controller,
                              focusNode: widget.focusNode,
                              enabled: isReady && !hasActiveAudioRecording,
                              maxLines: 6,
                              minLines: 1,
                              textCapitalization: TextCapitalization.sentences,
                              textInputAction: useDesktopShortcuts
                                  ? TextInputAction.newline
                                  : TextInputAction.send,
                              onSubmitted: (_) {
                                if (!useDesktopShortcuts && canSubmit) {
                                  unawaited(_submit(provider));
                                }
                              },
                              decoration: InputDecoration(
                                hintText: provider.supportsTextToSpeech
                                    ? 'Enter text to speak…'
                                    : 'Ask anything…',
                                border: InputBorder.none,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 12,
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        AnimatedContainer(
                          duration: const Duration(milliseconds: 180),
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: isGenerating
                                ? colorScheme.errorContainer
                                : canSubmit
                                ? colorScheme.primary
                                : colorScheme.surfaceContainerHighest,
                            shape: BoxShape.circle,
                          ),
                          child: IconButton(
                            tooltip: sendActionLabel,
                            onPressed: isGenerating
                                ? () => provider.stopGeneration()
                                : (canSubmit
                                      ? () => unawaited(_submit(provider))
                                      : null),
                            icon: isGenerating
                                ? Icon(
                                    Icons.stop_rounded,
                                    color: colorScheme.onErrorContainer,
                                    semanticLabel: kIsWeb
                                        ? null
                                        : sendActionLabel,
                                  )
                                : Icon(
                                    provider.supportsTextToSpeech
                                        ? Icons.graphic_eq_rounded
                                        : Icons.arrow_upward_rounded,
                                    color: canSubmit
                                        ? colorScheme.onPrimary
                                        : colorScheme.onSurfaceVariant,
                                    semanticLabel: kIsWeb
                                        ? null
                                        : sendActionLabel,
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildTextToSpeechOptions(
    BuildContext context,
    ChatProvider provider,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final progress = provider.textToSpeechProgress;
    final progressLabel = progress == null
        ? provider.isSynthesizingSpeech
              ? 'Preparing speech synthesis…'
              : 'Dedicated Qwen3-TTS mode'
        : progress.phase == TextToSpeechProgressPhase.processingPrompt
        ? 'Processing text…'
        : 'Generating audio · ${progress.framesGenerated} frames';
    final controlsEnabled =
        !provider.isSynthesizingSpeech && !provider.hasActiveAudioRecording;
    final recordedReference = provider.recordedSpeakerReference;
    final hasSpeakerReference =
        recordedReference != null || _speakerReference != null;
    const languages = <String>[
      'Auto',
      'English',
      'Chinese',
      'Japanese',
      'Korean',
      'German',
      'French',
      'Russian',
      'Portuguese',
      'Spanish',
      'Italian',
    ];

    return Container(
      key: const ValueKey<String>('text_to_speech_options'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: colorScheme.primaryContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.graphic_eq_rounded,
                size: 18,
                color: colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  progressLabel,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              PopupMenuButton<String>(
                tooltip: 'Choose synthesis language',
                enabled: !provider.isSynthesizingSpeech,
                onSelected: (value) {
                  setState(() {
                    _textToSpeechLanguage = value == 'Auto' ? null : value;
                  });
                },
                itemBuilder: (context) => languages
                    .map(
                      (language) => PopupMenuItem<String>(
                        value: language,
                        child: Text(language),
                      ),
                    )
                    .toList(growable: false),
                child: Chip(
                  avatar: const Icon(Icons.language_rounded, size: 17),
                  label: Text(_textToSpeechLanguage ?? 'Auto language'),
                ),
              ),
              InputChip(
                key: const ValueKey<String>('speaker_reference_chip'),
                avatar: const Icon(Icons.record_voice_over_outlined, size: 17),
                label: Text(
                  recordedReference != null
                      ? 'Recorded reference'
                      : _speakerReferenceName ?? 'Add speaker reference',
                ),
                onPressed: !controlsEnabled
                    ? null
                    : () => unawaited(_pickSpeakerReference()),
                onDeleted: !hasSpeakerReference || !controlsEnabled
                    ? null
                    : () {
                        setState(() {
                          _speakerReference = null;
                          _speakerReferenceName = null;
                        });
                        provider.clearRecordedSpeakerReference();
                      },
              ),
              if (provider.supportsSpeakerReferenceRecording)
                ActionChip(
                  key: const ValueKey<String>(
                    'record_speaker_reference_button',
                  ),
                  avatar: const Icon(Icons.mic_none_rounded, size: 17),
                  label: const Text('Record reference'),
                  onPressed: provider.canRecordSpeakerReference
                      ? () =>
                            unawaited(_startSpeakerReferenceRecording(provider))
                      : null,
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTextToSpeechOutput(BuildContext context, ChatProvider provider) {
    final colorScheme = Theme.of(context).colorScheme;
    final result = provider.textToSpeechResult;
    final error = provider.textToSpeechError;
    final duration = result?.duration ?? Duration.zero;
    final durationLabel = duration.inSeconds >= 60
        ? '${duration.inMinutes}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}'
        : '${duration.inSeconds}.${(duration.inMilliseconds % 1000 ~/ 100)} s';

    return Container(
      key: const ValueKey<String>('text_to_speech_output'),
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: error == null
            ? colorScheme.secondaryContainer.withValues(alpha: 0.4)
            : colorScheme.errorContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(14),
      ),
      child: error != null
          ? Row(
              children: [
                Icon(Icons.error_outline_rounded, color: colorScheme.error),
                const SizedBox(width: 8),
                Expanded(child: Text(error)),
                IconButton(
                  tooltip: 'Dismiss',
                  onPressed: () => unawaited(_clearSynthesizedSpeech(provider)),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            )
          : Row(
              children: [
                Icon(Icons.audio_file_rounded, color: colorScheme.secondary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Speech ready · $durationLabel · '
                    '${result!.sampleRateHz ~/ 1000} kHz '
                    '${result.channelCount == 1 ? 'mono' : '${result.channelCount} channel'} WAV',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                IconButton(
                  key: const ValueKey<String>('play_synthesized_speech_button'),
                  tooltip: _isPlayingSpeech ? 'Stop playback' : 'Play speech',
                  onPressed: () => unawaited(_playSynthesizedSpeech(result)),
                  icon: Icon(
                    _isPlayingSpeech
                        ? Icons.stop_rounded
                        : Icons.play_arrow_rounded,
                  ),
                ),
                IconButton(
                  key: const ValueKey<String>('save_synthesized_speech_button'),
                  tooltip: 'Save WAV',
                  onPressed: () => unawaited(_saveSynthesizedSpeech(result)),
                  icon: const Icon(Icons.download_rounded),
                ),
                IconButton(
                  tooltip: 'Clear speech output',
                  onPressed: () => unawaited(_clearSynthesizedSpeech(provider)),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
    );
  }

  Widget _buildStagedPartsStrip(
    BuildContext context,
    ChatProvider provider,
    List<LlamaContentPart> stagedParts,
  ) {
    final colorScheme = Theme.of(context).colorScheme;

    return Container(
      height: 84,
      margin: const EdgeInsets.only(bottom: 12),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: stagedParts.length,
        separatorBuilder: (context, index) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final part = stagedParts[index];
          return Stack(
            children: [
              Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: colorScheme.outlineVariant),
                ),
                clipBehavior: Clip.antiAlias,
                child: _buildPartPreview(part),
              ),
              Positioned(
                top: 2,
                right: 2,
                child: IconButton.filledTonal(
                  style: IconButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.all(2),
                    minimumSize: const Size(24, 24),
                  ),
                  onPressed: () => provider.removeStagedPart(index),
                  icon: const Icon(
                    Icons.close_rounded,
                    size: 14,
                    semanticLabel: kIsWeb ? null : 'Remove attachment',
                  ),
                  tooltip: 'Remove attachment',
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildFunctionCallingRow(BuildContext context, ChatProvider provider) {
    final colorScheme = Theme.of(context).colorScheme;
    final canUseTemplateTools = provider.templateSupportsTools;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colorScheme.surface.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: colorScheme.outlineVariant.withValues(alpha: 0.4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Function calling',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                ),
              ),
              TextButton(
                onPressed: () => showToolDeclarationsDialog(context, provider),
                child: const Text('Edit'),
              ),
              Switch.adaptive(
                value: provider.toolsEnabled,
                onChanged: canUseTemplateTools
                    ? (value) => provider.updateToolsEnabled(value)
                    : null,
              ),
            ],
          ),
          Text(
            provider.toolsEnabled
                ? '${provider.declaredToolCount} declaration(s) loaded'
                : 'Disabled',
            style: TextStyle(
              fontSize: 11,
              color: colorScheme.onSurfaceVariant.withValues(alpha: 0.92),
            ),
          ),
          if (!canUseTemplateTools)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                'This model template does not support tools.',
                style: TextStyle(
                  fontSize: 11,
                  color: colorScheme.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          if (provider.toolDeclarationsError != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                provider.toolDeclarationsError!,
                style: TextStyle(
                  fontSize: 11,
                  color: colorScheme.error,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildAttachmentMenu(BuildContext context, ChatProvider provider) {
    final colorScheme = Theme.of(context).colorScheme;
    final showFallbackImage =
        provider.canAttachMedia &&
        !provider.supportsVision &&
        !provider.supportsAudio;

    return PopupMenuButton<String>(
      icon: Icon(
        Icons.add_circle_outline_rounded,
        color: colorScheme.primary,
        semanticLabel: kIsWeb ? null : 'Add attachment',
      ),
      tooltip: 'Add attachment',
      onSelected: (value) {
        if (value == 'paste') {
          unawaited(
            _pasteFromSystemClipboard(
              provider,
              allowTextFallback: false,
              showUnsupportedMessage: true,
            ),
          );
        } else if (value == 'image') {
          provider.pickImage();
        } else if (value == 'audio') {
          provider.pickAudio();
        } else if (value == 'transcribe_audio') {
          unawaited(provider.pickAudioForTranscription());
        }
      },
      itemBuilder: (context) => [
        const PopupMenuItem(
          value: 'paste',
          child: Row(
            children: [
              Icon(Icons.content_paste_rounded),
              SizedBox(width: 12),
              Expanded(child: Text('Paste attachment')),
            ],
          ),
        ),
        if (provider.supportsVision || showFallbackImage)
          const PopupMenuItem(
            value: 'image',
            child: Row(
              children: [
                Icon(Icons.image_outlined),
                SizedBox(width: 12),
                Expanded(child: Text('Attach Image')),
              ],
            ),
          ),
        if (provider.supportsAudio)
          const PopupMenuItem(
            value: 'audio',
            child: Row(
              children: [
                Icon(Icons.audiotrack_outlined),
                SizedBox(width: 12),
                Expanded(child: Text('Attach Audio')),
              ],
            ),
          ),
        if (provider.canTranscribeAudio)
          const PopupMenuItem(
            value: 'transcribe_audio',
            child: Row(
              children: [
                Icon(Icons.transcribe_outlined),
                SizedBox(width: 12),
                Expanded(child: Text('Transcribe Audio')),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildAudioRecordingRow(BuildContext context, ChatProvider provider) {
    final colorScheme = Theme.of(context).colorScheme;
    final state = provider.audioRecordingState;
    final isRecording = state == ChatAudioRecordingState.recording;
    final isStarting = state == ChatAudioRecordingState.starting;
    final isVoiceQuestion =
        provider.audioRecordingPurpose ==
        ChatAudioRecordingPurpose.voiceQuestion;
    final isSpeakerReference =
        provider.audioRecordingPurpose ==
        ChatAudioRecordingPurpose.speakerReference;
    final maximumDuration = isVoiceQuestion
        ? ChatProvider.maxVoiceQuestionRecordingDuration
        : isSpeakerReference
        ? ChatProvider.maxSpeakerReferenceRecordingDuration
        : ChatProvider.maxAudioRecordingDuration;
    final status = switch (state) {
      ChatAudioRecordingState.starting => 'Requesting microphone access…',
      ChatAudioRecordingState.recording =>
        isVoiceQuestion
            ? 'Recording voice question '
                  '${_formatRecordingDuration(provider.audioRecordingElapsed)} / '
                  '${_formatRecordingDuration(maximumDuration)}'
            : isSpeakerReference
            ? 'Recording speaker reference '
                  '${_formatRecordingDuration(provider.audioRecordingElapsed)} / '
                  '${_formatRecordingDuration(maximumDuration)}'
            : 'Recording for transcription '
                  '${_formatRecordingDuration(provider.audioRecordingElapsed)} / '
                  '${_formatRecordingDuration(maximumDuration)}',
      ChatAudioRecordingState.stopping =>
        isVoiceQuestion
            ? 'Preparing voice question…'
            : isSpeakerReference
            ? 'Preparing speaker reference…'
            : 'Finishing recording…',
      ChatAudioRecordingState.cancelling => 'Discarding recording…',
      ChatAudioRecordingState.idle => '',
    };
    final semanticStatus = switch (state) {
      ChatAudioRecordingState.starting =>
        isVoiceQuestion
            ? 'Requesting microphone access for a voice question'
            : isSpeakerReference
            ? 'Requesting microphone access for a speaker reference'
            : 'Requesting microphone access for transcription',
      ChatAudioRecordingState.recording =>
        isVoiceQuestion
            ? 'Recording voice question. Maximum 30 seconds.'
            : isSpeakerReference
            ? 'Recording speaker reference. Maximum 30 seconds.'
            : 'Microphone recording for transcription in progress',
      ChatAudioRecordingState.stopping =>
        isVoiceQuestion
            ? 'Preparing recorded voice question'
            : isSpeakerReference
            ? 'Preparing recorded speaker reference'
            : 'Finishing microphone recording',
      ChatAudioRecordingState.cancelling => 'Discarding microphone recording',
      ChatAudioRecordingState.idle => '',
    };

    return Semantics(
      liveRegion: true,
      label: semanticStatus,
      child: Container(
        key: const ValueKey<String>('audio_recording_status'),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: colorScheme.errorContainer.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(12),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            Widget statusIndicator() => isRecording
                ? Icon(
                    Icons.fiber_manual_record_rounded,
                    size: 16,
                    color: colorScheme.error,
                  )
                : SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: colorScheme.error,
                    ),
                  );

            Widget statusText() => Text(
              status,
              style: TextStyle(
                color: colorScheme.onErrorContainer,
                fontWeight: FontWeight.w600,
              ),
            );

            final actions = <Widget>[
              if (isStarting || isRecording)
                TextButton(
                  key: const ValueKey<String>('discard_audio_recording_button'),
                  onPressed: () => unawaited(provider.cancelAudioRecording()),
                  child: const Text('Discard'),
                ),
              if (isRecording)
                FilledButton.tonalIcon(
                  key: ValueKey<String>(
                    isVoiceQuestion
                        ? 'stop_and_ask_audio_button'
                        : isSpeakerReference
                        ? 'stop_and_use_speaker_reference_button'
                        : 'stop_and_transcribe_audio_button',
                  ),
                  onPressed: () => unawaited(
                    isVoiceQuestion
                        ? provider.stopAudioRecordingAndAsk()
                        : isSpeakerReference
                        ? provider.stopAudioRecordingForSpeakerReference()
                        : provider.stopAudioRecordingAndTranscribe(),
                  ),
                  icon: const Icon(Icons.stop_rounded, size: 18),
                  label: Text(
                    isVoiceQuestion
                        ? 'Stop & ask'
                        : isSpeakerReference
                        ? 'Stop & use'
                        : 'Stop & transcribe',
                  ),
                ),
            ];

            if (constraints.maxWidth < 520) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      statusIndicator(),
                      const SizedBox(width: 8),
                      Expanded(child: statusText()),
                    ],
                  ),
                  if (actions.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Wrap(spacing: 4, children: actions),
                    ),
                  ],
                ],
              );
            }

            return Row(
              children: [
                statusIndicator(),
                const SizedBox(width: 8),
                Expanded(child: statusText()),
                if (actions.isNotEmpty) Wrap(spacing: 4, children: actions),
              ],
            );
          },
        ),
      ),
    );
  }

  String _formatRecordingDuration(Duration duration) {
    final totalSeconds = duration.inSeconds;
    final minutes = totalSeconds ~/ 60;
    final seconds = totalSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  Widget _buildPartPreview(LlamaContentPart part) {
    if (part is LlamaImageContent) {
      if (!kIsWeb && part.path != null) {
        return Image.file(File(part.path!), fit: BoxFit.cover);
      } else if (part.bytes != null) {
        return Image.memory(part.bytes!, fit: BoxFit.cover);
      }
    } else if (part is LlamaAudioContent) {
      return const Center(child: Icon(Icons.audiotrack, size: 32));
    }
    return const Center(child: Icon(Icons.description, size: 32));
  }
}
