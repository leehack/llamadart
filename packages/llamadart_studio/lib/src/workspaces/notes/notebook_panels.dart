part of 'notebook_workspace_view.dart';

extension _NotebookPanels on _NotebookWorkspaceViewState {
  Widget _buildSourcesPanel(
    StudioDependencies deps,
    StudioPalette palette,
    List<StudioNote> orderedNotes,
    StudioNote? selectedNote,
  ) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: palette.surfaceElevated,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.borderSubtle),
      ),
      child: orderedNotes.isEmpty
          ? Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'No notebook sources yet. Record a voice memo, import an image/file, or add a note.',
                style: TextStyle(fontSize: 12, color: palette.textMuted),
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 2, 4, 8),
                  child: Text(
                    'SOURCES (${orderedNotes.length})',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.7,
                      color: palette.textMuted,
                    ),
                  ),
                ),
                for (final note in orderedNotes)
                  InkWell(
                    key: Key('vault_note_item_${note.id}'),
                    borderRadius: BorderRadius.circular(9),
                    onTap: () async {
                      await _saveCurrentNote(deps);
                      deps.notebookController.selectNote(note.id);
                    },
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: selectedNote?.id == note.id
                            ? palette.accentMuted
                            : palette.canvas,
                        borderRadius: BorderRadius.circular(9),
                        border: Border.all(
                          color: selectedNote?.id == note.id
                              ? palette.accent
                              : palette.borderSubtle,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              Icon(
                                _NotebookWorkspaceViewState._iconForKind(
                                  note.sourceKind,
                                ),
                                size: 14,
                                color:
                                    note.sourceKind ==
                                        StudioNoteSourceKind.audio
                                    ? palette.amber
                                    : (note.sourceKind ==
                                              StudioNoteSourceKind.image
                                          ? palette.teal
                                          : palette.textSecondary),
                              ),
                              const SizedBox(width: 6),
                              if (note.pinned)
                                Padding(
                                  padding: const EdgeInsets.only(right: 5),
                                  child: Icon(
                                    Icons.push_pin_rounded,
                                    size: 13,
                                    color: palette.amber,
                                  ),
                                ),
                              Expanded(
                                child: Text(
                                  note.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight: FontWeight.w700,
                                    color: palette.textPrimary,
                                  ),
                                ),
                              ),
                              if (note.isMultimodalIndexed)
                                Padding(
                                  padding: const EdgeInsets.only(right: 6),
                                  child: StudioPillBadge(
                                    label: 'MM',
                                    foreground: palette.accent,
                                    monospace: true,
                                  ),
                                ),
                              StatusPulseDot(
                                color: note.isIndexed
                                    ? palette.teal
                                    : palette.textMuted,
                              ),
                            ],
                          ),
                          const SizedBox(height: 3),
                          Text(
                            note.searchableText.replaceAll('\n', ' '),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: palette.textSecondary,
                            ),
                          ),
                          if (note.tags.isNotEmpty) ...<Widget>[
                            const SizedBox(height: 5),
                            Wrap(
                              spacing: 4,
                              runSpacing: 4,
                              children: <Widget>[
                                for (final t in note.tags.take(4))
                                  StudioPillBadge(
                                    label: '#$t',
                                    monospace: true,
                                  ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _buildEditorPanel(
    BuildContext context,
    StudioDependencies deps,
    StudioPalette palette,
    NotebookState state,
    StudioNote selectedNote,
  ) {
    final isPlaying = _playingNoteId == selectedNote.id;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: palette.surfaceElevated,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: palette.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              StudioPillBadge(
                label: selectedNote.sourceKind.label,
                foreground: palette.accent,
                monospace: true,
              ),
              const SizedBox(width: 8),
              if (selectedNote.isMultimodalIndexed)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: StudioPillBadge(
                    label: 'Multimodal Vector',
                    foreground: palette.teal,
                    monospace: true,
                  ),
                ),
              StudioPillBadge(
                key: const Key('notebook_save_status_badge'),
                label: _noteDirty ? 'Auto-saving…' : 'Saved',
                foreground: _noteDirty ? palette.amber : palette.teal,
                monospace: true,
              ),
              IconButton(
                tooltip: selectedNote.pinned ? 'Unpin note' : 'Pin note',
                onPressed: () => deps.notebookController.updateNote(
                  selectedNote.id,
                  pinned: !selectedNote.pinned,
                ),
                icon: Icon(
                  selectedNote.pinned
                      ? Icons.push_pin_rounded
                      : Icons.push_pin_outlined,
                  size: 18,
                  color: selectedNote.pinned
                      ? palette.amber
                      : palette.textMuted,
                ),
              ),
              IconButton(
                tooltip: 'Delete note',
                onPressed: () =>
                    deps.notebookController.deleteNote(selectedNote.id),
                icon: Icon(
                  Icons.delete_outline_rounded,
                  size: 18,
                  color: palette.textMuted,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('vault_note_title_input'),
            controller: _titleCtrl,
            onChanged: (_) => _markNoteDirty(deps),
            decoration: const InputDecoration(labelText: 'Source Title'),
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('vault_note_tags_input'),
            controller: _tagsCtrl,
            onChanged: (_) => _markNoteDirty(deps),
            decoration: const InputDecoration(
              labelText: 'Tags (comma-separated)',
            ),
          ),
          if (selectedNote.hasImage) ...<Widget>[
            const SizedBox(height: 10),
            Builder(
              builder: (BuildContext context) {
                final decodedImage = _decodedImageFor(deps, selectedNote);
                return Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxHeight: 200),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: palette.canvas,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: palette.borderSubtle),
                  ),
                  child: Stack(
                    alignment: Alignment.topRight,
                    children: <Widget>[
                      Center(
                        child: decodedImage == null
                            ? Text(
                                'Loading image preview…',
                                style: TextStyle(color: palette.textMuted),
                              )
                            : ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: Image.memory(
                                  decodedImage,
                                  fit: BoxFit.contain,
                                  gaplessPlayback: true,
                                  errorBuilder: (_, _, _) => Text(
                                    'Image preview unavailable',
                                    style: TextStyle(color: palette.textMuted),
                                  ),
                                ),
                              ),
                      ),
                      IconButton(
                        tooltip: 'Remove attached image',
                        onPressed: () => deps.notebookController.updateNote(
                          selectedNote.id,
                          clearImage: true,
                        ),
                        icon: const Icon(Icons.close_rounded, size: 16),
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
          if (selectedNote.hasAudio) ...<Widget>[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: palette.canvas,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: palette.borderSubtle),
              ),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  FilledButton.tonalIcon(
                    key: const Key('notebook_play_audio_button'),
                    onPressed: () => _playOrStopNoteAudio(deps, selectedNote),
                    icon: Icon(
                      isPlaying ? Icons.stop_rounded : Icons.play_arrow_rounded,
                      size: 18,
                    ),
                    label: Text(isPlaying ? 'Stop Audio' : 'Play Recording'),
                  ),
                  if (selectedNote.audioDurationMs != null)
                    StudioPillBadge(
                      label:
                          '${(selectedNote.audioDurationMs! / 1000.0).toStringAsFixed(1)}s · 16 kHz WAV',
                      monospace: true,
                    ),
                  if (!deps.isWeb)
                    OutlinedButton.icon(
                      key: const Key('notebook_transcribe_audio_button'),
                      onPressed: state.isTranscribingNote
                          ? null
                          : () => deps.notebookController.transcribeAudioNote(
                              selectedNote.id,
                            ),
                      icon: state.isTranscribingNote
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.subtitles_outlined, size: 16),
                      label: Text(
                        state.isTranscribingNote
                            ? 'Transcribing...'
                            : 'Transcribe (Local ASR)',
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('notebook_transcript_input'),
              controller: _transcriptCtrl,
              maxLines: 3,
              onChanged: (_) => _markNoteDirty(deps),
              decoration: const InputDecoration(
                labelText: 'Audio Transcript',
                hintText:
                    'Run local ASR transcription or type spoken notes here...',
              ),
            ),
          ],
          const SizedBox(height: 8),
          TextField(
            key: const Key('vault_note_content_input'),
            controller: _bodyCtrl,
            minLines: 10,
            maxLines: null,
            onChanged: (_) => _markNoteDirty(deps),
            decoration: const InputDecoration(labelText: 'Your notes'),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.end,
              children: <Widget>[
                OutlinedButton.icon(
                  onPressed: () => _sendVaultToChat(deps),
                  icon: const Icon(Icons.chat_bubble_outline_rounded, size: 15),
                  label: const Text('Ask Chat About Notes'),
                ),
                FilledButton.icon(
                  key: const Key('vault_save_note_button'),
                  onPressed: () async {
                    _noteDirty = true;
                    await _saveCurrentNote(deps);
                  },
                  icon: const Icon(Icons.save_outlined, size: 15),
                  label: const Text('Save Note'),
                ),
              ],
            ),
          ),
          if (state.relatedNotes.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            Text(
              'RELATED SOURCES (BY VECTOR SIMILARITY)',
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: palette.textMuted,
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: <Widget>[
                for (final rel in state.relatedNotes)
                  ActionChip(
                    avatar: Icon(
                      Icons.link_rounded,
                      size: 14,
                      color: palette.teal,
                    ),
                    label: Text(
                      '${rel.note.title} (${rel.cosineScore.toStringAsFixed(2)})',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11.5),
                    ),
                    onPressed: () async {
                      await _saveCurrentNote(deps);
                      deps.notebookController.selectNote(rel.note.id);
                    },
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
