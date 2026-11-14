part of 'model_hub_workspace_view.dart';

extension _ModelHubStorage on _ModelHubWorkspaceViewState {
  Future<void> _showCacheManagerSheet(BuildContext context) async {
    final deps = StudioScope.of(context);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => StudioScope(
        deps: deps,
        child: _ModelStorageSheet(onAddFolder: _pickAndAddModelFolder),
      ),
    );
  }
}

class _StoredModelFile {
  const _StoredModelFile({
    required this.name,
    required this.path,
    required this.bytes,
    this.cacheKey,
  });

  final String name;
  final String path;
  final int? bytes;
  final String? cacheKey;
}

String _storageBytes(int? bytes) {
  if (bytes == null) return 'Size unknown';
  if (bytes >= 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GiB';
  }
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
}

class _ModelStorageSheet extends StatefulWidget {
  const _ModelStorageSheet({required this.onAddFolder});

  final Future<void> Function(BuildContext) onAddFolder;

  @override
  State<_ModelStorageSheet> createState() => _ModelStorageSheetState();
}

class _ModelStorageSheetState extends State<_ModelStorageSheet> {
  String _query = '';
  bool _largestFirst = true;
  bool _refreshing = false;
  String? _removingKey;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      await StudioScope.of(context).modelHubController.refreshCacheInventory();
      if (mounted) setState(() => _error = null);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not refresh model storage. Try again.');
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  bool _storageBusy(StudioDependencies deps) {
    final runtime = deps.modelHubController.runtimeStore.state;
    final speech = deps.speechController.state;
    final image = deps.imageController.state;
    final lab = deps.labModelCoordinator.state;
    return runtime.isReady ||
        runtime.isLoading ||
        deps.modelHubController.state.activatingDescriptor != null ||
        speech.activeTtsModel != null ||
        speech.activeSttModel != null ||
        speech.isLoadingTts ||
        speech.isLoadingStt ||
        image.activeModel != null ||
        image.isLoadingModel ||
        lab.loadedLabModels.isNotEmpty ||
        lab.isLoadingModel ||
        deps.modelHubController.state.downloadsByModelId.values.any(
          (p) => p.isActive,
        );
  }

  Future<void> _remove(_StoredModelFile file) async {
    final deps = StudioScope.of(context);
    if (_storageBusy(deps) || _removingKey != null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove downloaded file?'),
        content: Text(
          '${file.name}\n\n${_storageBytes(file.bytes)} will be removed from managed storage. Models using this file will need it downloaded again.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep file'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove file'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || _storageBusy(deps)) return;
    setState(() {
      _removingKey = file.cacheKey;
      _error = null;
    });
    try {
      await deps.modelHubController.deleteCacheEntry(file.cacheKey!);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Could not remove the file. It may still be in use.',
        );
      }
    } finally {
      if (mounted) setState(() => _removingKey = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final deps = StudioScope.of(context);
    return StoreBuilder<ModelHubState>(
      store: deps.modelHubController.store,
      builder: (context, hub) => StoreBuilder<StudioRuntimeSnapshot>(
        store: deps.modelHubController.runtimeStore,
        builder: (context, _) => StoreBuilder<SpeechWorkspaceState>(
          store: deps.speechController.store,
          builder: (context, _) => StoreBuilder<ImageWorkspaceState>(
            store: deps.imageController.store,
            builder: (context, _) => StoreBuilder<LabModelState>(
              store: deps.labModelCoordinator.store,
              builder: (context, _) => _buildStorage(context, deps, hub),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStorage(
    BuildContext context,
    StudioDependencies deps,
    ModelHubState hub,
  ) {
    final managedByPath = <String, _StoredModelFile>{};
    for (final entry in hub.cacheEntries) {
      managedByPath.putIfAbsent(
        entry.filePath,
        () => _StoredModelFile(
          name: entry.fileName,
          path: entry.filePath,
          bytes: entry.bytes,
          cacheKey: entry.cacheKey,
        ),
      );
    }
    final externalByPath = <String, _StoredModelFile>{};
    for (final model in hub.localModels) {
      final uri = Uri.tryParse(model.sourceUri);
      final path = uri?.scheme == 'file' ? uri!.toFilePath() : model.sourceUri;
      if (!managedByPath.containsKey(path)) {
        externalByPath.putIfAbsent(
          path,
          () => _StoredModelFile(
            name: model.name,
            path: path,
            bytes: model.sizeBytes > 0 ? model.sizeBytes : null,
          ),
        );
      }
    }
    final managed = managedByPath.values.toList();
    final external = externalByPath.values.toList();
    final knownBytes = managed.fold<int>(0, (sum, f) => sum + (f.bytes ?? 0));
    final unknownSizes = managed.any((f) => f.bytes == null);
    List<_StoredModelFile> filtered(List<_StoredModelFile> files) =>
        files
            .where(
              (f) => '${f.name} ${f.path}'.toLowerCase().contains(
                _query.toLowerCase(),
              ),
            )
            .toList()
          ..sort(
            (a, b) => _largestFirst
                ? (b.bytes ?? -1).compareTo(a.bytes ?? -1)
                : a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          );
    final shownManaged = filtered(managed);
    final shownExternal = filtered(external);
    final busy = _storageBusy(deps);
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * .88,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 12, 12),
            child: Row(
              children: <Widget>[
                const Expanded(
                  child: Text(
                    'Model storage',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
                  ),
                ),
                IconButton(
                  tooltip: 'Refresh storage',
                  onPressed: _refreshing ? null : _refresh,
                  icon: const Icon(Icons.refresh_rounded),
                ),
                IconButton(
                  tooltip: 'Close storage',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          if (_refreshing) const LinearProgressIndicator(),
          Expanded(
            child: ListView(
              key: const Key('storage_file_list'),
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
              children: <Widget>[
                Text(
                  '${_storageBytes(knownBytes)}${unknownSizes ? ' known' : ''} in downloaded files',
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  '${managed.length} managed files · ${external.length} additional local models',
                ),
                const SizedBox(height: 8),
                const Text(
                  'Downloaded files can be removed here. Files found in other folders stay under your control.',
                ),
                if (busy)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      'Unload active models and finish downloads to remove files. Shared model components may still be in use.',
                    ),
                  ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                TextField(
                  key: const Key('storage_search'),
                  decoration: const InputDecoration(
                    labelText: 'Find a file',
                    prefixIcon: Icon(Icons.search_rounded),
                  ),
                  onChanged: (value) => setState(() => _query = value),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: <Widget>[
                    ChoiceChip(
                      label: const Text('Largest first'),
                      selected: _largestFirst,
                      onSelected: (_) => setState(() => _largestFirst = true),
                    ),
                    ChoiceChip(
                      label: const Text('Name'),
                      selected: !_largestFirst,
                      onSelected: (_) => setState(() => _largestFirst = false),
                    ),
                    if (!deps.isWeb && !deps.isMobile)
                      TextButton.icon(
                        onPressed: () async {
                          await widget.onAddFolder(context);
                          if (mounted) setState(() {});
                        },
                        icon: const Icon(Icons.create_new_folder_outlined),
                        label: const Text('Add Folder'),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                const Text(
                  'Downloaded files',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
                if (managed.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      deps.isWeb
                          ? 'Browser model storage is managed by the browser.'
                          : 'No managed downloads yet. Download a model from Browse.',
                    ),
                  ),
                for (final file in shownManaged) _fileTile(file, busy: busy),
                if (shownExternal.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 20),
                  const Text(
                    'Other local models',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const Text(
                    'These files are not managed downloads. Sizes exclude companion files.',
                  ),
                  for (final file in shownExternal) _fileTile(file, busy: true),
                ],
                if (_query.isNotEmpty &&
                    shownManaged.isEmpty &&
                    shownExternal.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Text('No files match this search.'),
                  ),
                const SizedBox(height: 16),
                ExpansionTile(
                  title: const Text('Folders & access'),
                  tilePadding: EdgeInsets.zero,
                  children: <Widget>[
                    for (final directory
                        in deps
                            .shellController
                            .state
                            .settings
                            .customModelDirectories)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(directory),
                        subtitle: const Text(
                          'Stop scanning this folder without deleting its files',
                        ),
                        trailing: IconButton(
                          tooltip: 'Stop scanning folder',
                          icon: const Icon(Icons.folder_off_outlined),
                          onPressed: () async {
                            await deps.modelHubController
                                .removeCustomModelDirectory(directory);
                            if (mounted) setState(() {});
                          },
                        ),
                      ),
                    TextFormField(
                      initialValue: hub.bearerToken,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Hugging Face access token',
                        helperText:
                            'For gated repositories. Kept in memory only.',
                      ),
                      onChanged: deps.modelHubController.setBearerToken,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _fileTile(_StoredModelFile file, {required bool busy}) {
    return ExpansionTile(
      key: ValueKey<String>('storage_file_${file.cacheKey ?? file.path}'),
      tilePadding: EdgeInsets.zero,
      title: Text(file.name, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${_storageBytes(file.bytes)} · ${file.cacheKey == null ? 'External file' : 'Managed download'}',
      ),
      children: <Widget>[
        Align(
          alignment: Alignment.centerLeft,
          child: SelectableText(file.path),
        ),
        if (file.cacheKey != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: ValueKey<String>('storage_remove_${file.cacheKey}'),
              onPressed: busy || _removingKey != null
                  ? null
                  : () => _remove(file),
              icon: const Icon(Icons.delete_outline_rounded),
              label: Text(
                _removingKey == file.cacheKey
                    ? 'Removing…'
                    : 'Remove downloaded file',
              ),
            ),
          ),
        const SizedBox(height: 8),
      ],
    );
  }
}
