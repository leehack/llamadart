part of 'notebook_workspace_view.dart';

extension _NotebookLayout on _NotebookWorkspaceViewState {
  Widget _buildNotebookLayout(
    BuildContext context,
    StudioDependencies deps,
    StudioPalette palette,
    ModelHubState hubState,
    StudioRuntimeSnapshot runtime,
    LabModelState labState,
    NotebookState state, {
    required List<StudioModelDescriptor> embedders,
    required List<StudioNote> orderedNotes,
    required StudioNote? selectedNote,
    required StudioModelDescriptor? activeLoadingModel,
    required bool isBusy,
    required String? errorMessage,
  }) {
    return ListView(
      key: const Key('notebook_workspace_scroll'),
      padding: const EdgeInsets.all(20),
      children: <Widget>[
        Text(
          'Notes',
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w700,
            color: palette.textPrimary,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'A quiet place to collect ideas and write.',
          style: TextStyle(color: palette.textSecondary),
        ),
        const SizedBox(height: 20),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            OutlinedButton.icon(
              key: const Key('vault_new_note_button'),
              onPressed: () async {
                await _saveCurrentNote(deps);
                await deps.notebookController.createNote(
                  title: 'Untitled Note',
                  content: '',
                );
              },
              icon: const Icon(Icons.note_add_outlined, size: 16),
              label: const Text('New Note'),
            ),
            OutlinedButton.icon(
              key: const Key('notebook_record_audio_button'),
              style: _isRecordingMic
                  ? OutlinedButton.styleFrom(
                      foregroundColor: palette.danger,
                      side: BorderSide(color: palette.danger),
                    )
                  : null,
              onPressed: isBusy ? null : () => _toggleMicRecording(deps),
              icon: Icon(
                _isRecordingMic
                    ? Icons.stop_circle_rounded
                    : Icons.mic_none_rounded,
                size: 16,
              ),
              label: Text(_isRecordingMic ? 'Stop Recording' : 'Record Mic'),
            ),
            if (!deps.isWeb) ...<Widget>[
              OutlinedButton.icon(
                key: const Key('notebook_import_image_button'),
                onPressed: isBusy ? null : () => _importImageNote(deps),
                icon: const Icon(Icons.add_photo_alternate_outlined, size: 16),
                label: const Text('Import Image'),
              ),
              OutlinedButton.icon(
                key: const Key('notebook_import_file_button'),
                onPressed: isBusy ? null : () => _importTextOrAudioFile(deps),
                icon: const Icon(Icons.upload_file_outlined, size: 16),
                label: const Text('Import File'),
              ),
            ],
          ],
        ),
        const SizedBox(height: 16),
        if (activeLoadingModel != null) ...<Widget>[
          ModelLoadProgressBanner(
            descriptor: activeLoadingModel,
            onCancel: deps.notebookController.cancelModelLoad,
          ),
          const SizedBox(height: 12),
        ],
        if (errorMessage != null) ...<Widget>[
          Text(errorMessage, style: TextStyle(color: palette.danger)),
          const SizedBox(height: 12),
        ],
        LayoutBuilder(
          builder: (BuildContext context, BoxConstraints box) {
            final sources = ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 420),
              child: SingleChildScrollView(
                child: _buildSourcesPanel(
                  deps,
                  palette,
                  orderedNotes,
                  selectedNote,
                ),
              ),
            );
            final editor = selectedNote == null
                ? Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Create a note or choose a source to start writing.',
                      style: TextStyle(color: palette.textSecondary),
                    ),
                  )
                : _buildEditorPanel(
                    context,
                    deps,
                    palette,
                    state,
                    selectedNote,
                  );
            if (box.maxWidth >= 800) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  SizedBox(width: 250, child: sources),
                  const SizedBox(width: 24),
                  Expanded(child: editor),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                ExpansionTile(
                  key: const Key('notebook_sources_section'),
                  tilePadding: EdgeInsets.zero,
                  title: Text('Sources (${orderedNotes.length})'),
                  subtitle: selectedNote == null
                      ? null
                      : Text(
                          selectedNote.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                  children: <Widget>[sources],
                ),
                const SizedBox(height: 16),
                editor,
              ],
            );
          },
        ),
        const SizedBox(height: 24),
        ExpansionTile(
          key: const Key('notebook_ask_section'),
          tilePadding: EdgeInsets.zero,
          leading: const Icon(Icons.auto_awesome_outlined),
          title: const Text('Ask notebook'),
          subtitle: Text(
            state.isAnsweringNotebook
                ? 'Answering…'
                : 'Find connections and answers in your sources',
          ),
          children: <Widget>[
            _buildRagCapturePanel(
              context,
              deps,
              palette,
              state,
              runtime,
              isBusy: isBusy,
            ),
            const SizedBox(height: 12),
            ExpansionTile(
              key: const Key('notebook_search_settings'),
              tilePadding: const EdgeInsets.symmetric(horizontal: 16),
              leading: const Icon(Icons.tune_rounded),
              title: const Text('Search settings'),
              subtitle: Text(
                '${state.indexedNoteCount}/${state.notes.length} sources indexed',
              ),
              childrenPadding: const EdgeInsets.all(16),
              children: <Widget>[
                if (embedders.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 12),
                  LayoutBuilder(
                    builder: (BuildContext context, BoxConstraints chipBox) {
                      final maxChipLabelWidth = math.min(
                        270.0,
                        math.max(90.0, chipBox.maxWidth - 72.0),
                      );
                      return Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: embedders.map((StudioModelDescriptor m) {
                          final loaded =
                              labState
                                  .loadedLabModels[StudioModelSpecialty
                                      .embedding]
                                  ?.id ==
                              m.id;
                          final loadingThis = activeLoadingModel?.id == m.id;
                          final installed = hubState.cachedModelIds.contains(
                            m.id,
                          );
                          return ActionChip(
                            key: Key('notebook_embedder_chip_${m.id}'),
                            avatar: loadingThis
                                ? SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: palette.accent,
                                    ),
                                  )
                                : Icon(
                                    loaded
                                        ? Icons.check_circle_rounded
                                        : (installed
                                              ? Icons.bolt_rounded
                                              : Icons
                                                    .download_for_offline_outlined),
                                    size: 16,
                                    color: loaded
                                        ? palette.teal
                                        : (installed
                                              ? palette.accent
                                              : palette.textSecondary),
                                  ),
                            label: ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth: maxChipLabelWidth,
                              ),
                              child: Text(
                                '${m.name} (${m.sizeLabel(isWeb: deps.isWeb)})',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 11.5),
                              ),
                            ),
                            onPressed: isBusy
                                ? null
                                : () => deps.notebookController.loadLabModel(m),
                          );
                        }).toList(),
                      );
                    },
                  ),
                ],
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    FilledButton.tonalIcon(
                      key: const Key('vault_index_notes_button'),
                      onPressed: isBusy
                          ? null
                          : () async {
                              await _saveCurrentNote(deps);
                              await deps.notebookController.indexNotes();
                            },
                      icon: const Icon(Icons.hub_outlined, size: 16),
                      label: Text(
                        state.isEvaluating ? 'Indexing...' : 'Index Notes',
                      ),
                    ),
                    FilterChip(
                      key: const Key('vault_rerank_switch'),
                      label: const Text('Two-Stage Rerank'),
                      selected: state.rerankVaultHits,
                      onSelected: deps.notebookController.setRerankVaultHits,
                    ),
                    if (state.lastSearchElapsedMs != null)
                      StudioPillBadge(
                        label: '${state.lastSearchElapsedMs} ms',
                        monospace: true,
                      ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}
