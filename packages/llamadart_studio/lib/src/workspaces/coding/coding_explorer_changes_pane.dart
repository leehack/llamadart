part of 'coding_workspace_view.dart';

extension _CodingExplorerChangesPane on _CodingWorkspaceViewState {
  Widget _buildExplorerPane(
    BuildContext context,
    StudioDependencies deps,
    StudioPalette palette,
    CodingWorkspaceState codingState, {
    bool? forceChangesTab,
  }) {
    final showChanges = forceChangesTab ?? _showEditsInExplorer;
    final compact = _compactLayout;
    if (compact &&
        !showChanges &&
        _showFileDetail &&
        codingState.selectedFileSlice != null) {
      final slice = codingState.selectedFileSlice!;
      return PopScope<void>(
        canPop:
            _compactSection != _CompactCodingSection.files ||
            codingState.pendingShellApproval != null,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop &&
              _compactSection == _CompactCodingSection.files &&
              codingState.pendingShellApproval == null) {
            _updateState(() => _showFileDetail = false);
          }
        },
        child: LayoutBuilder(
          builder: (context, box) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: box.maxHeight * 0.55),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          TextButton.icon(
                            key: const Key('coding_back_to_files'),
                            style: TextButton.styleFrom(
                              minimumSize: const Size(48, 48),
                            ),
                            onPressed: () =>
                                _updateState(() => _showFileDetail = false),
                            icon: const Icon(Icons.arrow_back_rounded),
                            label: const Text('Files'),
                          ),
                          Expanded(
                            child: Tooltip(
                              message: slice.relativePath,
                              child: Text(
                                slice.relativePath,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      SwitchListTile.adaptive(
                        key: const Key('coding_use_context'),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                        ),
                        title: const Text('Use as context'),
                        value: codingState.includeSelectedFileContext,
                        onChanged:
                            deps.codingController.setIncludeSelectedFileContext,
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                child: Container(
                  key: const Key('coding_file_syntax_preview'),
                  color: palette.canvas,
                  child: SyntaxCodeView(
                    code: slice.content,
                    filePath: slice.relativePath,
                    startLine: slice.startLine,
                    showLineNumbers: true,
                    showHeader: box.maxHeight > 180,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, box) => Container(
        decoration: BoxDecoration(
          color: palette.sidebar,
          border: Border(right: BorderSide(color: palette.borderSubtle)),
        ),
        child: Column(
          children: <Widget>[
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: compact ? box.maxHeight * 0.6 : box.maxHeight,
              ),
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      if (forceChangesTab == null)
                        Row(
                          children: <Widget>[
                            Expanded(
                              child: SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: Row(
                                  children: <Widget>[
                                    ChoiceChip(
                                      visualDensity: VisualDensity.standard,
                                      label: const Text(
                                        'Explorer',
                                        style: TextStyle(fontSize: 11.5),
                                      ),
                                      selected: !showChanges,
                                      onSelected: (_) => _updateState(
                                        () => _showEditsInExplorer = false,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    ChoiceChip(
                                      visualDensity: VisualDensity.standard,
                                      label: Text(
                                        'Changes (${codingState.recentChanges.length})',
                                        style: const TextStyle(fontSize: 11.5),
                                      ),
                                      selected: showChanges,
                                      onSelected: (_) => _updateState(
                                        () => _showEditsInExplorer = true,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Refresh directory',
                              visualDensity: VisualDensity.standard,
                              onPressed: deps.codingController.refreshExplorer,
                              icon: const Icon(Icons.refresh_rounded, size: 17),
                            ),
                          ],
                        ),
                      if (!showChanges) ...<Widget>[
                        const SizedBox(height: 6),
                        Row(
                          children: <Widget>[
                            if (codingState.currentSubdir.isNotEmpty)
                              IconButton(
                                tooltip: 'Parent directory',
                                visualDensity: VisualDensity.standard,
                                onPressed: () {
                                  final parts = codingState.currentSubdir.split(
                                    '/',
                                  );
                                  parts.removeLast();
                                  deps.codingController.openDirectory(
                                    parts.join('/'),
                                  );
                                },
                                icon: const Icon(
                                  Icons.arrow_upward_rounded,
                                  size: 16,
                                ),
                              ),
                            Expanded(
                              child: TextFormField(
                                key: ValueKey(
                                  'coding_file_filter_${codingState.workspaceRoot}',
                                ),
                                initialValue: codingState.fileFilter,
                                onChanged: deps.codingController.setFileFilter,
                                style: const TextStyle(fontSize: 12),
                                decoration: InputDecoration(
                                  hintText: codingState.currentSubdir.isEmpty
                                      ? 'Filter workspace files...'
                                      : '/${codingState.currentSubdir} · Filter...',
                                  prefixIcon: const Icon(
                                    Icons.search_rounded,
                                    size: 15,
                                  ),
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 10,
                                    vertical: 8,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            Divider(height: 1, color: palette.borderSubtle),
            if (showChanges)
              Expanded(
                child: codingState.recentChanges.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(
                            'File writes and patches applied by the coding agent appear here.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 12,
                              color: palette.textMuted,
                            ),
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.all(10),
                        itemCount: codingState.recentChanges.length,
                        itemBuilder: (BuildContext context, int i) {
                          final change = codingState.recentChanges[i];
                          final diffText = change.unifiedDiff.isNotEmpty
                              ? change.unifiedDiff
                              : (change.beforePreview.isNotEmpty ||
                                        change.afterPreview.isNotEmpty
                                    ? '${change.beforePreview.isNotEmpty ? '- ${change.beforePreview.replaceAll('\n', '\n- ')}\n' : ''}+ ${change.afterPreview.replaceAll('\n', '\n+ ')}'
                                    : '');
                          return Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.all(10),
                            decoration: BoxDecoration(
                              color: palette.surfaceElevated,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: change.reverted
                                    ? palette.borderSubtle
                                    : (change.kind == CodingChangeKind.created
                                          ? palette.teal.withValues(alpha: 0.35)
                                          : palette.borderSubtle),
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Row(
                                  children: <Widget>[
                                    StudioPillBadge(
                                      label: change.kind.name.toUpperCase(),
                                      foreground:
                                          change.kind ==
                                              CodingChangeKind.created
                                          ? palette.teal
                                          : palette.accent,
                                      monospace: true,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: InkWell(
                                        onTap: () => _openFileAndReveal(
                                          change.relativePath,
                                        ),
                                        child: ConstrainedBox(
                                          constraints: const BoxConstraints(
                                            minHeight: 48,
                                          ),
                                          child: Align(
                                            alignment: Alignment.centerLeft,
                                            child: Text(
                                              change.relativePath,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w600,
                                                decoration: change.reverted
                                                    ? TextDecoration.lineThrough
                                                    : null,
                                                color: change.reverted
                                                    ? palette.textMuted
                                                    : palette.textPrimary,
                                                fontFamilyFallback: StudioTheme
                                                    .monoFontFallback,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    if (change.reverted) ...<Widget>[
                                      const SizedBox(width: 6),
                                      StudioPillBadge(
                                        label: 'REVERTED',
                                        foreground: palette.textMuted,
                                        monospace: true,
                                      ),
                                    ] else if (change.canRevert) ...<Widget>[
                                      const SizedBox(width: 6),
                                      TextButton.icon(
                                        key: Key('coding_revert_change_$i'),
                                        style: TextButton.styleFrom(
                                          visualDensity: VisualDensity.standard,
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 6,
                                            vertical: 2,
                                          ),
                                          minimumSize: const Size(48, 48),
                                          tapTargetSize:
                                              MaterialTapTargetSize.shrinkWrap,
                                        ),
                                        onPressed: () => deps.codingController
                                            .revertChange(change.id),
                                        icon: Icon(
                                          Icons.undo_rounded,
                                          size: 13,
                                          color: palette.amber,
                                        ),
                                        label: Text(
                                          'Revert',
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                            color: palette.amber,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                                if (diffText.isNotEmpty) ...<Widget>[
                                  const SizedBox(height: 6),
                                  Container(
                                    width: double.infinity,
                                    constraints: const BoxConstraints(
                                      maxHeight: 130,
                                    ),
                                    decoration: BoxDecoration(
                                      color: palette.canvas,
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: palette.borderSubtle,
                                      ),
                                    ),
                                    child: SingleChildScrollView(
                                      child: SyntaxCodeView(
                                        code: diffText,
                                        language: 'diff',
                                        showLineNumbers: false,
                                        fontSize: 10.5,
                                        padding: const EdgeInsets.all(6),
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          );
                        },
                      ),
              )
            else ...<Widget>[
              Expanded(
                flex: 5,
                child: codingState.workspaceRoot == null
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text(
                            'Open a local project folder to inspect files and enable repository tools.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 12,
                              color: palette.textMuted,
                            ),
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 6,
                        ),
                        itemCount: codingState.filteredFiles.length,
                        itemBuilder: (BuildContext context, int i) {
                          final entry = codingState.filteredFiles[i];
                          final selected =
                              entry.relativePath ==
                              codingState.selectedFilePath;
                          return InkWell(
                            key: Key('coding_file_${entry.relativePath}'),
                            borderRadius: BorderRadius.circular(8),
                            onTap: () {
                              if (entry.isDirectory) {
                                deps.codingController.openDirectory(
                                  entry.relativePath,
                                );
                              } else {
                                _openFileAndReveal(entry.relativePath);
                              }
                            },
                            child: Container(
                              constraints: const BoxConstraints(minHeight: 48),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: selected
                                    ? palette.accentMuted
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Row(
                                children: <Widget>[
                                  Icon(
                                    entry.isDirectory
                                        ? Icons.folder_outlined
                                        : Icons.description_outlined,
                                    size: 15,
                                    color: entry.isDirectory
                                        ? palette.amber
                                        : palette.textSecondary,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      entry.name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: selected
                                            ? FontWeight.w700
                                            : FontWeight.w500,
                                        color: selected
                                            ? palette.textPrimary
                                            : palette.textSecondary,
                                        fontFamilyFallback:
                                            StudioTheme.monoFontFallback,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
              if (!compact &&
                  codingState.selectedFileSlice != null) ...<Widget>[
                Divider(height: 1, color: palette.borderSubtle),
                Container(
                  padding: const EdgeInsets.fromLTRB(12, 8, 8, 6),
                  color: palette.surfaceElevated,
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          codingState.selectedFileSlice!.relativePath,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            color: palette.textPrimary,
                            fontFamilyFallback: StudioTheme.monoFontFallback,
                          ),
                        ),
                      ),
                      Tooltip(
                        message: 'Use as context',
                        child: Switch.adaptive(
                          value: codingState.includeSelectedFileContext,
                          onChanged: deps
                              .codingController
                              .setIncludeSelectedFileContext,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  flex: 5,
                  child: Container(
                    key: const Key('coding_file_syntax_preview'),
                    width: double.infinity,
                    color: palette.canvas,
                    child: SyntaxCodeView(
                      code: codingState.selectedFileSlice!.content,
                      filePath: codingState.selectedFileSlice!.relativePath,
                      startLine: codingState.selectedFileSlice!.startLine,
                      showLineNumbers: true,
                      showHeader: true,
                      fontSize: 11,
                    ),
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}
