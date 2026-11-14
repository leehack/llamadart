part of 'model_hub_workspace_view.dart';

enum _ModelHubSection { browse, onDevice, huggingFace }

enum _ModelCapability {
  any('Any capability'),
  vision('Vision'),
  tools('Tool calling'),
  thinking('Reasoning'),
  audio('Audio'),
  embeddings('Embeddings'),
  reranking('Reranking');

  const _ModelCapability(this.label);
  final String label;
  bool matches(StudioModelDescriptor model) => switch (this) {
    any => true,
    vision => model.supportsVision,
    tools => model.supportsToolCalling,
    thinking => model.supportsThinking,
    audio =>
      model.supportsAudio ||
          model.supportsSpeechToText ||
          model.supportsTextToSpeech,
    embeddings => model.specialty == StudioModelSpecialty.embedding,
    reranking => model.specialty == StudioModelSpecialty.reranker,
  };
}

enum _ModelSort { recommended, smallest, name }

extension _ModelHubDiscovery on _ModelHubWorkspaceViewState {
  bool _isOnDevice(StudioModelDescriptor model, ModelHubState state) =>
      (state.cachedModelIds.contains(model.id) ||
      (!StudioScope.of(context).isWeb &&
          model.primarySource(isWeb: false).isLocal));

  void _resetFilters(StudioDependencies deps) {
    _searchController.clear();
    deps.modelHubController.setSearchQuery('');
    deps.modelHubController.selectCategory(null);
    _updateDiscovery(() {
      _capability = _ModelCapability.any;
      _sort = _ModelSort.recommended;
    });
  }

  Widget _buildDiscovery(
    BuildContext context,
    StudioDependencies deps,
    ModelHubState state,
    StudioRuntimeSnapshot runtime,
  ) {
    final palette = StudioPalette.of(context);
    final curated = deps.modelHubController.filteredCuratedModels();
    final models =
        <StudioModelDescriptor>[
              ...curated,
              ...deps.modelHubController.filteredLocalModels(),
            ]
            .where(
              (m) =>
                  _capability.matches(m) &&
                  (_section != _ModelHubSection.onDevice ||
                      _isOnDevice(m, state)),
            )
            .toList();
    models.sort((a, b) {
      if (_sort == _ModelSort.smallest) {
        final aBytes = a.effectiveSizeBytes(isWeb: deps.isWeb);
        final bBytes = b.effectiveSizeBytes(isWeb: deps.isWeb);
        final bySize = (aBytes <= 0 ? double.infinity : aBytes.toDouble())
            .compareTo(bBytes <= 0 ? double.infinity : bBytes.toDouble());
        if (bySize != 0) return bySize;
      }
      if (_sort == _ModelSort.recommended) {
        final byRecommended = (b.isRecommended ? 1 : 0).compareTo(
          a.isRecommended ? 1 : 0,
        );
        if (byRecommended != 0) return byRecommended;
        final byInstalled = (_isOnDevice(b, state) ? 1 : 0).compareTo(
          _isOnDevice(a, state) ? 1 : 0,
        );
        if (byInstalled != 0) return byInstalled;
      }
      return a.name.compareTo(b.name);
    });
    final isRemote = _section == _ModelHubSection.huggingFace;
    return ListView(
      key: const PageStorageKey<String>('model_hub_scroll'),
      padding: EdgeInsets.all(MediaQuery.sizeOf(context).width < 600 ? 16 : 22),
      children: <Widget>[
        Wrap(
          spacing: 12,
          runSpacing: 12,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            Text(
              'Model Hub & Cache Manager',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: palette.textPrimary,
              ),
            ),
            OutlinedButton.icon(
              key: const Key('open_cache_sheet_button'),
              onPressed: () => _showCacheManagerSheet(context),
              icon: const Icon(Icons.storage_rounded, size: 16),
              label: const Text('Model storage'),
            ),
            OutlinedButton.icon(
              key: const Key('open_custom_model_button'),
              onPressed: state.activatingDescriptor != null || runtime.isLoading
                  ? null
                  : () => _showCustomModelDialog(context),
              icon: const Icon(Icons.add_rounded, size: 16),
              label: const Text('Add model'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Find a model for your task, or use one already on your device.',
          style: TextStyle(color: palette.textSecondary),
        ),
        const SizedBox(height: 18),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            for (final section in _ModelHubSection.values)
              ChoiceChip(
                key: Key('model_hub_section_${section.name}'),
                label: Text(switch (section) {
                  _ModelHubSection.browse => 'Browse',
                  _ModelHubSection.onDevice =>
                    deps.isWeb ? 'Downloaded' : 'On device',
                  _ModelHubSection.huggingFace => 'Hugging Face',
                }),
                selected: _section == section,
                onSelected: (_) => _updateDiscovery(() => _section = section),
              ),
          ],
        ),
        if (state.activatingDescriptor != null ||
            runtime.isLoading && runtime.activeDescriptor != null) ...<Widget>[
          const SizedBox(height: 16),
          ModelLoadProgressBanner(
            descriptor: state.activatingDescriptor ?? runtime.activeDescriptor!,
            preparing: !runtime.isLoading,
          ),
        ],
        const SizedBox(height: 16),
        TextField(
          key: const Key('model_hub_search_field'),
          controller: _searchController,
          onChanged: deps.modelHubController.setSearchQuery,
          onSubmitted: isRemote
              ? deps.modelHubController.searchHuggingFace
              : null,
          decoration: InputDecoration(
            hintText: isRemote
                ? 'Search repositories on Hugging Face'
                : 'Search name, size, publisher or filename',
            prefixIcon: const Icon(Icons.search_rounded),
            suffixIcon: state.searchQuery.isEmpty
                ? null
                : IconButton(
                    tooltip: 'Clear search',
                    onPressed: () {
                      _searchController.clear();
                      deps.modelHubController.setSearchQuery('');
                    },
                    icon: const Icon(Icons.close_rounded),
                  ),
          ),
        ),
        const SizedBox(height: 12),
        if (isRemote)
          ..._buildHuggingFace(context, deps, state, runtime)
        else ...<Widget>[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              ChoiceChip(
                label: const Text('All Modalities'),
                selected: state.selectedCategory == null,
                onSelected: (_) => deps.modelHubController.selectCategory(null),
              ),
              for (final category in StudioModelCategory.values)
                ChoiceChip(
                  label: Text(category.label),
                  selected: state.selectedCategory == category,
                  onSelected: (_) =>
                      deps.modelHubController.selectCategory(category),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              DropdownButton<_ModelCapability>(
                key: const Key('model_hub_capability'),
                value: _capability,
                items: _ModelCapability.values
                    .map(
                      (c) => DropdownMenuItem(value: c, child: Text(c.label)),
                    )
                    .toList(),
                onChanged: (value) =>
                    _updateDiscovery(() => _capability = value!),
              ),
              DropdownButton<_ModelSort>(
                key: const Key('model_hub_sort'),
                value: _sort,
                items: const <DropdownMenuItem<_ModelSort>>[
                  DropdownMenuItem(
                    value: _ModelSort.recommended,
                    child: Text('Recommended first'),
                  ),
                  DropdownMenuItem(
                    value: _ModelSort.smallest,
                    child: Text('Smallest first'),
                  ),
                  DropdownMenuItem(
                    value: _ModelSort.name,
                    child: Text('Name A–Z'),
                  ),
                ],
                onChanged: (value) => _updateDiscovery(() => _sort = value!),
              ),
              TextButton(
                key: const Key('model_hub_reset'),
                onPressed: () => _resetFilters(deps),
                child: const Text('Reset filters'),
              ),
              if (_section == _ModelHubSection.onDevice)
                IconButton(
                  tooltip: 'Rescan local model directories',
                  onPressed: deps.modelHubController.refreshCacheInventory,
                  icon: const Icon(Icons.refresh_rounded),
                ),
              if (_section == _ModelHubSection.onDevice &&
                  !deps.isWeb &&
                  !deps.isMobile)
                OutlinedButton.icon(
                  key: const Key('add_model_folder_button'),
                  onPressed: () => _pickAndAddModelFolder(context),
                  icon: const Icon(Icons.create_new_folder_outlined, size: 16),
                  label: const Text('Add Folder'),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            '${models.length} ${models.length == 1 ? 'model' : 'models'}${_section == _ModelHubSection.onDevice ? ' on device' : ' available'}',
            key: const Key('model_hub_result_count'),
            style: TextStyle(color: palette.textSecondary),
          ),
          const SizedBox(height: 12),
          if (models.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Column(
                children: <Widget>[
                  const Icon(Icons.search_off_rounded, size: 32),
                  const SizedBox(height: 12),
                  const Text('No models match your filters.'),
                  TextButton(
                    onPressed: () => _resetFilters(deps),
                    child: const Text('Clear filters'),
                  ),
                  TextButton(
                    onPressed: () => _updateDiscovery(
                      () => _section = _ModelHubSection.huggingFace,
                    ),
                    child: const Text('Search Hugging Face instead'),
                  ),
                ],
              ),
            )
          else
            _buildModelGrid(
              context: context,
              deps: deps,
              hubState: state,
              runtime: runtime,
              models: models,
            ),
        ],
      ],
    );
  }

  List<Widget> _buildHuggingFace(
    BuildContext context,
    StudioDependencies deps,
    ModelHubState state,
    StudioRuntimeSnapshot runtime,
  ) => <Widget>[
    Align(
      alignment: Alignment.centerLeft,
      child: FilledButton.tonalIcon(
        key: const Key('model_hub_search_hf'),
        onPressed: state.isSearchingHf
            ? null
            : () => deps.modelHubController.searchHuggingFace(
                _searchController.text,
              ),
        icon: state.isSearchingHf
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.travel_explore_rounded, size: 18),
        label: const Text('Search HF Hub'),
      ),
    ),
    const SizedBox(height: 12),
    const Text(
      'Community repositories. Review model requirements before downloading.',
    ),
    if (state.hfErrorMessage != null)
      Text(
        state.hfErrorMessage!,
        style: TextStyle(color: StudioPalette.of(context).danger),
      ),
    if (!state.isSearchingHf && state.hfResults.isEmpty)
      const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Text(
          'Search by model family or repository name to explore more models.',
        ),
      ),
    for (final hit in state.hfResults)
      _HuggingFaceRepoTile(
        hit: hit,
        canActivate: state.activatingDescriptor == null && !runtime.isLoading,
        isExpanded: state.expandedRepoId == hit.repoId,
        files: state.expandedRepoId == hit.repoId
            ? state.expandedRepoFiles
            : const <StudioModelDescriptor>[],
        onTapRepo: () =>
            deps.modelHubController.expandHuggingFaceRepo(hit.repoId),
        onActivateFile: (file) => _activateDescriptor(context, file),
      ),
  ];
}
