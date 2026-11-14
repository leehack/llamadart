part of 'speech_workspace_view.dart';

extension _SpeechSttCardExtension on _SpeechWorkspaceViewState {
  Widget _buildSttCard(
    BuildContext context,
    StudioDependencies deps,
    SpeechWorkspaceState state,
  ) {
    final palette = StudioPalette.of(context);
    final models = deps.speechController.availableSttModels;

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
              Icon(Icons.graphic_eq_rounded, color: palette.teal),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Speech-to-Text (ASR)',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: palette.textPrimary,
                  ),
                ),
              ),
              if (state.activeSttModel != null)
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
                  key: ValueKey<String?>(_selectedSttDescriptor?.id),
                  initialValue: _selectedSttDescriptor,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'ASR Engine'),
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
                      _updateState(() => _selectedSttDescriptor = m),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton.tonal(
                onPressed: state.isLoadingStt || _selectedSttDescriptor == null
                    ? null
                    : () => deps.speechController.loadSttModel(
                        _selectedSttDescriptor!,
                      ),
                child: Text(state.isLoadingStt ? 'Loading...' : 'Load'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _sttContextCtrl,
            decoration: const InputDecoration(
              labelText: 'Optional Domain Vocabulary Hint',
              hintText: 'e.g. llamadart, GGUF, Metal, KV cache...',
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: <Widget>[
              FilledButton.icon(
                onPressed: state.isTranscribing ? null : _toggleMicRecording,
                icon: Icon(
                  _isRecordingMic ? Icons.stop_rounded : Icons.mic_rounded,
                  size: 17,
                ),
                label: Text(
                  _isRecordingMic ? 'Stop & Transcribe' : 'Record Mic',
                ),
              ),
              OutlinedButton.icon(
                onPressed: state.isTranscribing ? null : _pickAndTranscribeFile,
                icon: const Icon(Icons.audio_file_outlined, size: 17),
                label: const Text('Transcribe Audio File'),
              ),
            ],
          ),
          if (state.isTranscribing) ...<Widget>[
            const SizedBox(height: 12),
            const LinearProgressIndicator(),
          ],
          if (state.latestTranscript != null) ...<Widget>[
            const SizedBox(height: 16),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: palette.canvas,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: palette.borderSubtle),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  SizedBox(
                    width: double.infinity,
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: <Widget>[
                        StudioPillBadge(
                          label: '${state.latestTranscript!.elapsedMs} ms',
                          foreground: palette.teal,
                          monospace: true,
                        ),
                        Wrap(
                          spacing: 4,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: <Widget>[
                            IconButton(
                              tooltip: 'Copy transcript',
                              visualDensity: VisualDensity.compact,
                              onPressed: () => Clipboard.setData(
                                ClipboardData(
                                  text: state.latestTranscript!.text,
                                ),
                              ),
                              icon: const Icon(Icons.copy_rounded, size: 15),
                            ),
                            TextButton.icon(
                              onPressed: () async {
                                final text = state.latestTranscript!.text;
                                deps.shellController.selectWorkspace(
                                  StudioWorkspace.chat,
                                );
                                await deps.chatController.sendMessage(text);
                              },
                              icon: const Icon(Icons.send_rounded, size: 14),
                              label: const Text('Send to Chat'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 6),
                  SelectableText(
                    state.latestTranscript!.text,
                    style: TextStyle(
                      fontSize: 13.5,
                      height: 1.5,
                      color: palette.textPrimary,
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
}
