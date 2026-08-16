import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:llamadart/llamadart.dart' hide ModelDownloadProgress;
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/downloadable_model.dart';
import '../providers/chat_provider.dart';
import '../services/hugging_face_model_discovery_service.dart';
import '../services/model_download_controller_adapter.dart';
import '../services/model_download_ui_controller.dart';
import '../services/model_service_base.dart';
import '../utils/backend_utils.dart';
import '../widgets/model_card.dart';
import '../widgets/tool_declarations_dialog.dart';

enum _CustomModelRemoval { entryOnly, entryAndFiles }

enum _ModelPlatformFilter { all, mobile, web, desktop }

enum _ModelLibraryMenuAction { removeAll }

class ManageModelsScreen extends StatefulWidget {
  final VoidCallback? onModelActivated;
  final bool embeddedPanel;

  // Test hooks for exercising download-controller wiring without relying on
  // platform storage or the full built-in model catalog.
  final ModelService? modelService;
  final List<DownloadableModel>? initialModels;
  final bool? showModelLibraryInitially;

  /// App-owned download state that outlives transient drawer and panel views.
  final ModelDownloadUiController? downloadUiController;

  /// Model card to reveal when the shell opens download details.
  final String? focusModelFilename;

  /// Monotonic request ID so repeated taps can refocus the same model.
  final int focusRequestId;

  const ManageModelsScreen({
    super.key,
    this.onModelActivated,
    this.embeddedPanel = false,
    this.modelService,
    this.initialModels,
    this.showModelLibraryInitially,
    this.downloadUiController,
    this.focusModelFilename,
    this.focusRequestId = 0,
  });

  @override
  State<ManageModelsScreen> createState() => _ManageModelsScreenState();
}

class _ManageModelsScreenState extends State<ManageModelsScreen>
    with WidgetsBindingObserver {
  static const String _customModelsPrefsKey = 'custom_hf_models_v1';
  static const int _webLargeModelWarningBytes = 1900 * 1024 * 1024;
  static const Duration _completedDownloadHighlightDuration = Duration(
    seconds: 2,
  );

  late final ModelService _modelService;
  final HuggingFaceModelDiscoveryService _hfDiscoveryService =
      HuggingFaceModelDiscoveryService();
  final TextEditingController _modelSearchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<DownloadableModel> _models = <DownloadableModel>[];
  final List<DownloadableModel> _customModels = <DownloadableModel>[];
  final Map<String, GlobalKey> _modelCardKeys = {};

  final Map<String, ModelProfileCacheState> _cacheStateByFile = {};
  final Map<String, bool> _includeProjectorByFile = {};
  late final ModelDownloadUiController _downloadUi;
  late final bool _ownsDownloadUi;
  StreamSubscription<String>? _downloadFinishedSubscription;
  Timer? _completedDownloadHighlightTimer;

  Set<String> _downloadedFiles = {};
  String? _modelsDir;
  String? _activatingModel;
  bool _showModelLibrary = true;
  bool _modelParametersExpanded = false;
  bool _inferenceParametersExpanded = false;
  bool _advancedExpanded = false;
  String _modelSearchQuery = '';
  String? _focusedModelFilename;
  late _ModelPlatformFilter _modelPlatformFilter;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _modelService = widget.modelService ?? ModelService();
    _downloadUi = widget.downloadUiController ?? ModelDownloadUiController();
    _ownsDownloadUi = widget.downloadUiController == null;
    _downloadFinishedSubscription = _downloadUi.downloadsFinished.listen(
      _handleDownloadFinished,
    );
    _modelPlatformFilter = _currentPlatformFilter;
    _models.addAll(_initialModelCatalog());
    _showModelLibrary = widget.showModelLibraryInitially ?? false;
    _initModelService();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focusRequestedModel());
  }

  @override
  void didUpdateWidget(covariant ManageModelsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.focusRequestId != oldWidget.focusRequestId ||
        widget.focusModelFilename != oldWidget.focusModelFilename) {
      _focusRequestedModel();
    }
  }

  void _focusRequestedModel() {
    final filename = widget.focusModelFilename;
    if (!mounted || filename == null || filename.isEmpty) {
      return;
    }

    _completedDownloadHighlightTimer?.cancel();
    _modelSearchController.clear();
    setState(() {
      _showModelLibrary = true;
      _modelSearchQuery = '';
      _modelPlatformFilter = _ModelPlatformFilter.all;
      _focusedModelFilename = filename;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final cardContext = _modelCardKeys[filename]?.currentContext;
      if (cardContext != null) {
        unawaited(
          Scrollable.ensureVisible(
            cardContext,
            alignment: 0.12,
            duration: const Duration(milliseconds: 360),
            curve: Curves.easeOutCubic,
          ),
        );
      }
    });
  }

  List<DownloadableModel> _initialModelCatalog() {
    return List<DownloadableModel>.from(
      widget.initialModels ?? DownloadableModel.defaultModels,
    );
  }

  bool get _isMobilePlatform =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  _ModelPlatformFilter get _currentPlatformFilter {
    if (kIsWeb) {
      return _ModelPlatformFilter.web;
    }
    if (_isMobilePlatform) {
      return _ModelPlatformFilter.mobile;
    }
    return _ModelPlatformFilter.desktop;
  }

  bool _isAvailableOnCurrentPlatform(DownloadableModel model) {
    return model.isAvailableFor(web: kIsWeb, mobile: _isMobilePlatform);
  }

  bool _matchesPlatformFilter(DownloadableModel model) {
    return switch (_modelPlatformFilter) {
      _ModelPlatformFilter.all => true,
      _ModelPlatformFilter.mobile => model.isAvailableFor(
        web: false,
        mobile: true,
      ),
      _ModelPlatformFilter.web => model.isAvailableFor(
        web: true,
        mobile: false,
      ),
      _ModelPlatformFilter.desktop => model.isAvailableFor(
        web: false,
        mobile: false,
      ),
    };
  }

  bool _matchesModelSearch(DownloadableModel model) {
    final query = _modelSearchQuery.trim().toLowerCase();
    if (query.isEmpty) {
      return true;
    }
    // A Web user can browse the All, Mobile, and Desktop catalogs. Outside the
    // Web filter, search the native capability profile rather than hiding
    // features unavailable only in the browser runtime.
    final useWebCapabilities =
        kIsWeb && _modelPlatformFilter == _ModelPlatformFilter.web;
    final searchable = <String>[
      model.name,
      model.description,
      model.distribution ?? '',
      model.filename,
      if (model.supportsToolCalling) 'tools function calling',
      if (model.supportsThinking) 'thinking reasoning',
      if (model.supportsVisionFor(web: useWebCapabilities)) 'vision image',
      if (model.supportsAudioFor(web: useWebCapabilities)) 'audio voice',
      if (model.supportsSpeechToTextFor(web: useWebCapabilities))
        'speech-to-text speech to text transcription asr stt',
      if (model.supportsTextToSpeechFor(web: useWebCapabilities))
        'text-to-speech text to speech synthesis tts voice output',
      if (model.supportsVideoFor(web: useWebCapabilities)) 'video',
    ].join(' ').toLowerCase();
    return query.split(RegExp(r'\s+')).every(searchable.contains);
  }

  bool _isModelDownloaded(DownloadableModel model) {
    return _downloadedFiles.contains(model.filename) ||
        (_cacheStateByFile[model.filename]?.model.isAvailable ?? false);
  }

  List<DownloadableModel> _visibleModels() {
    final visible = _models
        .where(_matchesPlatformFilter)
        .where(_matchesModelSearch)
        .toList(growable: false);
    return [
      ...visible.where(_isModelDownloaded),
      ...visible.where((model) => !_isModelDownloaded(model)),
    ];
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Do not deliberately cancel active downloads on mobile background/sleep.
    // The foreground Dart request may be suspended by the OS, but cancelling here
    // guarantees a pause every time the screen locks. Let the transfer continue
    // for short lifecycle interruptions and rely on resumable `.download` files
    // when the OS eventually interrupts the socket.
  }

  Future<void> _initModelService() async {
    await _loadCustomModels();
    _modelsDir = await _modelService.getModelsDirectory();
    await _refreshDownloadedModelState();
    if (mounted) {
      setState(() {});
      _focusRequestedModel();
    }
  }

  Future<void> _refreshDownloadedModelState({
    Iterable<DownloadableModel>? cacheModels,
    bool clearCacheStates = false,
  }) async {
    final downloadedFiles = await _modelService.getDownloadedModels(_models);
    if (clearCacheStates) {
      _cacheStateByFile.clear();
    }
    await _refreshCacheStates(cacheModels ?? _models);
    _downloadedFiles = downloadedFiles;
  }

  Future<void> _refreshCacheStates(Iterable<DownloadableModel> models) async {
    final entries = await Future.wait(
      models.map((model) async {
        final state = await _modelService.getModelCacheState(model);
        return MapEntry(model.filename, state);
      }),
    );
    for (final entry in entries) {
      _cacheStateByFile[entry.key] = entry.value;
    }
  }

  Future<void> _handleDownloadFinished(String filename) async {
    final model = _models
        .where((model) => model.filename == filename)
        .firstOrNull;
    if (model == null) {
      return;
    }

    final cardKey = _modelCardKeys[filename];
    final beforeTop = _globalTop(cardKey?.currentContext);
    await _refreshDownloadedModelState(cacheModels: <DownloadableModel>[model]);
    if (mounted) {
      setState(() {
        _focusedModelFilename = filename;
      });
      _scheduleCompletedDownloadHighlightClear(filename);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final cardContext = cardKey?.currentContext;
        final afterTop = _globalTop(cardContext);
        if (beforeTop != null &&
            afterTop != null &&
            _scrollController.hasClients) {
          final position = _scrollController.position;
          final anchoredOffset = (position.pixels + afterTop - beforeTop).clamp(
            position.minScrollExtent,
            position.maxScrollExtent,
          );
          _scrollController.jumpTo(anchoredOffset);
        } else if (cardContext != null) {
          unawaited(
            Scrollable.ensureVisible(
              cardContext,
              alignment: 0.12,
              duration: const Duration(milliseconds: 360),
              curve: Curves.easeOutCubic,
            ),
          );
        }
      });
    }
  }

  void _scheduleCompletedDownloadHighlightClear(String filename) {
    _completedDownloadHighlightTimer?.cancel();
    _completedDownloadHighlightTimer = Timer(
      _completedDownloadHighlightDuration,
      () {
        if (!mounted || _focusedModelFilename != filename) {
          return;
        }
        setState(() {
          _focusedModelFilename = null;
        });
      },
    );
  }

  double? _globalTop(BuildContext? context) {
    final renderObject = context?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) {
      return null;
    }
    return renderObject.localToGlobal(Offset.zero).dy;
  }

  Future<void> _loadCustomModels() async {
    final prefs = await SharedPreferences.getInstance();
    final entries = prefs.getStringList(_customModelsPrefsKey) ?? const [];

    _customModels.clear();
    for (final entry in entries) {
      try {
        final decoded = jsonDecode(entry);
        if (decoded is! Map<String, dynamic>) {
          continue;
        }

        final model = DownloadableModel(
          name: (decoded['name'] as String?) ?? 'Custom GGUF',
          description:
              (decoded['description'] as String?) ??
              'Custom Hugging Face GGUF model.',
          url: (decoded['url'] as String?) ?? '',
          filename: (decoded['filename'] as String?) ?? '',
          mmprojUrl: decoded['mmprojUrl'] as String?,
          mmprojFilename: decoded['mmprojFilename'] as String?,
          sizeBytes: (decoded['sizeBytes'] as int?) ?? 0,
          supportsVision: (decoded['supportsVision'] as bool?) ?? false,
          supportsAudio: (decoded['supportsAudio'] as bool?) ?? false,
          supportsSpeechToText:
              (decoded['supportsSpeechToText'] as bool?) ?? false,
          supportsVideo: (decoded['supportsVideo'] as bool?) ?? false,
          supportsToolCalling:
              (decoded['supportsToolCalling'] as bool?) ?? false,
          supportsThinking: (decoded['supportsThinking'] as bool?) ?? false,
          preset: _decodePreset(decoded['preset']),
          minRamGb: (decoded['minRamGb'] as int?) ?? 2,
        );

        if (model.url.isEmpty || model.filename.isEmpty) {
          continue;
        }

        final exists = _models.any(
          (existing) =>
              existing.filename == model.filename || existing.url == model.url,
        );
        if (!exists) {
          _models.add(model);
          _customModels.add(model);
        }
      } catch (_) {
        // Ignore malformed persisted model entries.
      }
    }
  }

  Future<void> _saveCustomModels() async {
    final prefs = await SharedPreferences.getInstance();
    final payload = _customModels
        .map(
          (model) => jsonEncode({
            'name': model.name,
            'description': model.description,
            'url': model.url,
            'filename': model.filename,
            'mmprojUrl': model.mmprojUrl,
            'mmprojFilename': model.mmprojFilename,
            'sizeBytes': model.sizeBytes,
            'supportsVision': model.supportsVision,
            'supportsAudio': model.supportsAudio,
            'supportsSpeechToText': model.supportsSpeechToText,
            'supportsVideo': model.supportsVideo,
            'supportsToolCalling': model.supportsToolCalling,
            'supportsThinking': model.supportsThinking,
            'minRamGb': model.minRamGb,
            'preset': _encodePreset(model.preset),
          }),
        )
        .toList(growable: false);
    await prefs.setStringList(_customModelsPrefsKey, payload);
  }

  Map<String, dynamic> _encodePreset(ModelPreset preset) {
    return <String, dynamic>{
      'temperature': preset.temperature,
      'topK': preset.topK,
      'topP': preset.topP,
      'minP': preset.minP,
      'penalty': preset.penalty,
      'thinkingBudgetTokens': preset.thinkingBudgetTokens,
      'contextSize': preset.contextSize,
      'maxTokens': preset.maxTokens,
      'thinkingEnabled': preset.thinkingEnabled,
      'gpuLayers': preset.gpuLayers,
    };
  }

  ModelPreset _decodePreset(Object? raw) {
    if (raw is! Map<String, dynamic>) {
      return const ModelPreset();
    }

    return ModelPreset(
      temperature: (raw['temperature'] as num?)?.toDouble() ?? 0.7,
      topK: (raw['topK'] as num?)?.toInt() ?? 40,
      topP: (raw['topP'] as num?)?.toDouble() ?? 0.9,
      minP: (raw['minP'] as num?)?.toDouble() ?? 0.0,
      penalty: (raw['penalty'] as num?)?.toDouble() ?? 1.1,
      thinkingBudgetTokens: (raw['thinkingBudgetTokens'] as num?)?.toInt() ?? 0,
      contextSize: (raw['contextSize'] as num?)?.toInt() ?? 4096,
      maxTokens: (raw['maxTokens'] as num?)?.toInt() ?? 4096,
      thinkingEnabled: (raw['thinkingEnabled'] as bool?) ?? true,
      gpuLayers: (raw['gpuLayers'] as num?)?.toInt() ?? 99,
    );
  }

  bool _isDuplicateModel(DownloadableModel candidate) {
    return _models.any(
      (model) =>
          model.filename == candidate.filename ||
          model.url == candidate.url ||
          (model.name == candidate.name &&
              model.sizeBytes == candidate.sizeBytes),
    );
  }

  Future<void> _addCustomModelEntry(DownloadableModel model) async {
    setState(() {
      _models.insert(0, model);
      _customModels.removeWhere(
        (existing) =>
            existing.filename == model.filename || existing.url == model.url,
      );
      _customModels.insert(0, model);
      _showModelLibrary = true;
    });

    await _refreshDownloadedModelState(cacheModels: <DownloadableModel>[model]);
    if (mounted) {
      setState(() {});
    }

    await _saveCustomModels();
  }

  String? _extractFilenameFromUrl(String rawUrl) {
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null || uri.pathSegments.isEmpty) {
      return null;
    }

    for (var i = uri.pathSegments.length - 1; i >= 0; i--) {
      final segment = Uri.decodeComponent(uri.pathSegments[i]).trim();
      if (segment.isNotEmpty) {
        return segment;
      }
    }
    return null;
  }

  List<String> _credentialLikeCustomUrlLabels({
    required String modelUrl,
    required String? mmprojUrl,
  }) {
    return <String>[
      if (_hasCredentialLikePersistentUrlParts(modelUrl)) 'GGUF URL',
      if (mmprojUrl != null &&
          mmprojUrl.isNotEmpty &&
          _hasCredentialLikePersistentUrlParts(mmprojUrl))
        'MMProj URL',
    ];
  }

  bool _hasCredentialLikePersistentUrlParts(String value) {
    return hasPersistentCacheSensitiveUrlParts(value.trim());
  }

  Future<bool> _confirmSavingCredentialLikeCustomUrls(
    BuildContext context,
    List<String> labels,
  ) async {
    final labelText = labels.length == 1
        ? labels.single
        : '${labels.take(labels.length - 1).join(', ')} and ${labels.last}';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Save credentialed URL?'),
          content: Text(
            '$labelText includes user info, a fragment, or credential-like '
            'query parameters. Custom model URLs are saved in local '
            'preferences. Prefer a public ?download=true URL or runtime '
            'headers for private access.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Review URL'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Save anyway'),
            ),
          ],
        );
      },
    );
    return confirmed ?? false;
  }

  Future<void> _showAddHuggingFaceDialog() async {
    final nameController = TextEditingController();
    final modelUrlController = TextEditingController();
    final mmprojUrlController = TextEditingController();
    String? errorText;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Add Hugging Face GGUF'),
              content: SizedBox(
                width: 480,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: nameController,
                      decoration: const InputDecoration(
                        labelText: 'Display name (optional)',
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: modelUrlController,
                      decoration: const InputDecoration(
                        labelText: 'GGUF URL (Hugging Face)',
                        hintText:
                            'https://huggingface.co/.../resolve/main/model.gguf?download=true',
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: mmprojUrlController,
                      decoration: const InputDecoration(
                        labelText: 'MMProj URL (optional)',
                      ),
                    ),
                    if (errorText != null) ...[
                      const SizedBox(height: 10),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          errorText!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () async {
                    final url = modelUrlController.text.trim();
                    final mmprojUrl = mmprojUrlController.text.trim();
                    final uri = Uri.tryParse(url);
                    final modelFilename = _extractFilenameFromUrl(url);

                    if (uri == null ||
                        !uri.hasScheme ||
                        !uri.host.contains('huggingface.co') ||
                        modelFilename == null ||
                        !modelFilename.toLowerCase().endsWith('.gguf')) {
                      setDialogState(() {
                        errorText =
                            'Please enter a valid Hugging Face GGUF URL.';
                      });
                      return;
                    }

                    String? mmprojFilename;
                    if (mmprojUrl.isNotEmpty) {
                      mmprojFilename = _extractFilenameFromUrl(mmprojUrl);
                      if (mmprojFilename == null ||
                          !mmprojFilename.toLowerCase().endsWith('.gguf')) {
                        setDialogState(() {
                          errorText =
                              'Invalid MMProj URL. It must point to .gguf';
                        });
                        return;
                      }
                    }

                    final displayName = nameController.text.trim().isEmpty
                        ? modelFilename
                        : nameController.text.trim();

                    final customModel = DownloadableModel(
                      name: displayName,
                      description: 'Custom Hugging Face GGUF model.',
                      url: url,
                      filename: modelFilename,
                      mmprojUrl: mmprojUrl.isEmpty ? null : mmprojUrl,
                      mmprojFilename: mmprojFilename,
                      sizeBytes: 0,
                      supportsVision: mmprojUrl.isNotEmpty,
                      supportsAudio: false,
                      supportsVideo: false,
                      supportsToolCalling: false,
                      supportsThinking: false,
                      minRamGb: 2,
                      preset: const ModelPreset(),
                    );

                    if (_isDuplicateModel(customModel)) {
                      setDialogState(() {
                        errorText = 'This model is already in your list.';
                      });
                      return;
                    }

                    final credentialUrlLabels = _credentialLikeCustomUrlLabels(
                      modelUrl: url,
                      mmprojUrl: mmprojUrl.isEmpty ? null : mmprojUrl,
                    );
                    if (credentialUrlLabels.isNotEmpty) {
                      if (!dialogContext.mounted) return;
                      final confirmed =
                          await _confirmSavingCredentialLikeCustomUrls(
                            dialogContext,
                            credentialUrlLabels,
                          );
                      if (!confirmed) {
                        return;
                      }
                    }

                    await _addCustomModelEntry(customModel);
                    if (!dialogContext.mounted) return;
                    Navigator.of(dialogContext).pop();

                    if (!mounted) return;
                    ScaffoldMessenger.of(this.context).showSnackBar(
                      SnackBar(content: Text('Added ${customModel.name}')),
                    );
                  },
                  child: const Text('Add model'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _showDiscoverPopularModelsDialog() async {
    final discovered = await showModalBottomSheet<HfDiscoveredModel>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) {
        return _PopularModelsDiscoverySheet(
          discoveryService: _hfDiscoveryService,
          existingModels: _models,
        );
      },
    );

    if (!mounted || discovered == null) {
      return;
    }

    final source = discovered.model;
    final enrichedDescription = discovered.hasLiveStats
        ? '⭐ ${_formatCompactCount(discovered.downloads)} downloads • '
              '${source.description}'
        : source.description;

    final customModel = DownloadableModel(
      name: source.name,
      description: enrichedDescription,
      url: source.url,
      filename: source.filename,
      mmprojUrl: source.mmprojUrl,
      mmprojFilename: source.mmprojFilename,
      sizeBytes: source.sizeBytes,
      supportsVision: source.supportsVision,
      supportsAudio: source.supportsAudio,
      supportsSpeechToText: source.supportsSpeechToText,
      supportsVideo: source.supportsVideo,
      supportsToolCalling: source.supportsToolCalling,
      supportsThinking: source.supportsThinking,
      minRamGb: source.minRamGb,
      preset: source.preset,
    );

    if (_isDuplicateModel(customModel)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${customModel.name} is already in your list.')),
      );
      return;
    }

    await _addCustomModelEntry(customModel);
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Added ${customModel.name}')));
  }

  String _formatCompactCount(int value) {
    if (value >= 1000000) {
      return '${(value / 1000000).toStringAsFixed(1)}M';
    }
    if (value >= 1000) {
      return '${(value / 1000).toStringAsFixed(1)}k';
    }
    return value.toString();
  }

  String _downloadFailureMessage(dynamic error) {
    if (error is DioException) {
      final normalized = '${error.message ?? ''} ${error.error ?? ''}'
          .toLowerCase();
      final statusCode = error.response?.statusCode;

      if (error.type == DioExceptionType.connectionError) {
        final looksLikeDnsFailure =
            normalized.contains('failed host lookup') ||
            normalized.contains('no address associated with hostname') ||
            normalized.contains('socketexception');
        if (looksLikeDnsFailure) {
          return 'Cannot reach Hugging Face. Check internet, DNS/Private DNS, VPN, or ad blocker.';
        }
        return 'Network connection error while downloading. Please check your internet and retry.';
      }

      if (error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.sendTimeout ||
          error.type == DioExceptionType.receiveTimeout) {
        return 'Download timed out. Please retry on a stable connection.';
      }

      if (error.type == DioExceptionType.badResponse && statusCode != null) {
        return 'Download failed (HTTP $statusCode). Please retry.';
      }
    }

    return 'Download failed. Please retry.';
  }

  bool _includeProjectorFor(DownloadableModel model) {
    return model.supportsSpeechToTextFor(web: kIsWeb) ||
        model.supportsTextToSpeechFor(web: kIsWeb) ||
        (_includeProjectorByFile[model.filename] ?? true);
  }

  void _setIncludeProjector(DownloadableModel model, bool value) {
    setState(() {
      _includeProjectorByFile[model.filename] = value;
    });
  }

  void _updateDownloadUiState(
    String filename, {
    bool? isDownloading,
    double? progress,
    ModelDownloadProgress? detail,
    ModelDownloadTaskSnapshot? task,
    bool clearDetail = false,
    bool clearTask = false,
    bool clearProgress = false,
  }) {
    _downloadUi.updateState(
      filename,
      isDownloading: isDownloading,
      progress: clearProgress ? 0.0 : progress,
      detail: detail,
      task: task,
      clearDetail: clearDetail,
      clearTask: clearTask,
    );
  }

  void _clearDownloadTracking(String filename) {
    _downloadUi.clearTracking(filename);
  }

  void _pauseActiveDownloads() {
    _downloadUi.pauseActiveDownloads();
  }

  Future<void> _disposeDownloadController(
    String filename, {
    ModelDownloadController? controller,
    StreamSubscription<ModelDownloadTaskSnapshot>? subscription,
  }) async {
    await _downloadUi.disposeDownload(
      filename,
      controller: controller,
      subscription: subscription,
    );
  }

  void _handleDownloadSnapshot(
    DownloadableModel model,
    ModelDownloadTaskSnapshot snapshot,
  ) {
    _updateDownloadUiState(
      model.filename,
      isDownloading: snapshot.isRunning,
      progress: snapshot.fraction,
      task: snapshot,
    );
  }

  Future<void> _downloadModel(
    DownloadableModel model, {
    bool? includeProjector,
  }) async {
    if (!kIsWeb && _modelsDir == null) {
      return;
    }
    if (_downloadUi.isPending(model.filename)) {
      return;
    }

    final shouldIncludeProjector =
        includeProjector ?? _includeProjectorFor(model);
    final ready = await _downloadUi.enqueueDownload(
      filename: model.filename,
      displayName: model.name,
    );
    if (!ready) {
      return;
    }
    if (!_downloadUi.canRegisterDownload(model.filename)) {
      _downloadUi.completeActiveDownload(model.filename);
      return;
    }

    await _disposeDownloadController(model.filename);
    // The user may cancel while the previous controller is being disposed,
    // before this attempt has registered a cancellable controller.
    if (!_downloadUi.canRegisterDownload(model.filename)) {
      _downloadUi.completeActiveDownload(model.filename);
      return;
    }

    ModelDownloadController? controller;
    StreamSubscription<ModelDownloadTaskSnapshot>? subscription;

    try {
      _updateDownloadUiState(
        model.filename,
        isDownloading: true,
        clearDetail: true,
        clearTask: true,
        clearProgress: true,
      );
      _clearDownloadTracking(model.filename);

      final manager = ChatAppModelDownloadManager(
        modelService: _modelService,
        model: model,
        modelsDir: _modelsDir ?? '',
        useWebSources: kIsWeb,
        includeProjector: shouldIncludeProjector,
        onProgressDetail: (detail) {
          _downloadUi.updateDownloadRate(model.filename, detail);
          _updateDownloadUiState(
            model.filename,
            progress: detail.overallProgress,
            detail: detail,
          );
        },
      );
      controller = ModelDownloadController(manager: manager);
      subscription = controller.snapshots.listen(
        (snapshot) => _handleDownloadSnapshot(model, snapshot),
      );
      final registered = _downloadUi.registerDownload(
        filename: model.filename,
        controller: controller,
        subscription: subscription,
      );
      if (!registered) {
        _downloadUi.completeActiveDownload(model.filename);
        return;
      }

      await controller.start(manager.source);
      _updateDownloadUiState(
        model.filename,
        isDownloading: false,
        clearProgress: true,
        clearDetail: true,
        clearTask: true,
      );
      _clearDownloadTracking(model.filename);
      _downloadUi.notifyDownloadFinished(model.filename);
      if (!mounted) {
        return;
      }
      final successAction = shouldIncludeProjector
          ? 'downloaded successfully'
          : 'downloaded for text-only chat';
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('${model.name} $successAction.')));
    } catch (error) {
      final snapshot = controller?.snapshot;
      final isCancel =
          snapshot?.stage == ModelDownloadTaskStage.cancelled ||
          (error is DioException && error.type == DioExceptionType.cancel);
      _updateDownloadUiState(
        model.filename,
        isDownloading: false,
        clearDetail: !isCancel,
        clearTask: !isCancel,
        clearProgress: !isCancel,
      );
      if (!isCancel) {
        _clearDownloadTracking(model.filename);
      }
      _downloadUi.notifyDownloadFinished(model.filename);
      if (!mounted) {
        return;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            isCancel
                ? 'Download paused: ${model.name}'
                : error is DioException
                ? _downloadFailureMessage(error)
                : snapshot?.errorMessage ?? _downloadFailureMessage(error),
          ),
        ),
      );
    } finally {
      _downloadUi.completeActiveDownload(model.filename);
      await _disposeDownloadController(
        model.filename,
        controller: controller,
        subscription: subscription,
      );
    }
  }

  void _cancelDownload(DownloadableModel model) {
    _downloadUi.cancel(model.filename);
  }

  Future<void> _selectModel(DownloadableModel model) async {
    if (!kIsWeb && _modelsDir == null) {
      return;
    }

    if (kIsWeb && _hasUnsupportedWebAsset(model)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Web builds require remote URLs for model assets.'),
        ),
      );
      return;
    }

    final provider = context.read<ChatProvider>();
    final pathOrUrl = _resolveModelLoadReference(model);

    provider.updateModelPath(pathOrUrl);
    provider.applyModelPreset(model);

    if ((model.isMultimodalFor(web: kIsWeb) ||
            model.supportsTextToSpeechFor(web: kIsWeb)) &&
        model.mediaInputModeFor(web: kIsWeb) ==
            ModelMediaInputMode.externalProjector) {
      final mmprojPath = _resolveMmprojPathForModel(model);
      final mmprojSource = model.multimodalProjectorSourceFor(web: kIsWeb);
      final projectorIsAvailable =
          mmprojSource == null ||
          (_cacheStateByFile[model.filename]
                  ?.multimodalProjector
                  ?.isAvailable ??
              false);
      provider.updateMmprojPath(projectorIsAvailable ? (mmprojPath ?? '') : '');
    } else {
      provider.updateMmprojPath('');
    }

    if (kIsWeb && model.sizeBytesFor(web: true) >= _webLargeModelWarningBytes) {
      final warningMessage = _isLiteRtLmWebModel(model)
          ? 'Large LiteRT-LM web model selected. Browser memory limits may still block engine initialization.'
          : 'Large web model selected. Download/cache can complete, but browser memory limits may still block loading.';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(duration: Duration(seconds: 4), content: Text(warningMessage)),
      );
    }

    setState(() {
      _activatingModel = model.filename;
    });

    await provider.loadModel();

    if (!mounted) return;
    setState(() {
      _activatingModel = null;
      _showModelLibrary = false;
    });

    if (provider.error == null) {
      final capabilityWarning = _runtimeCapabilityWarning(model, provider);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            capabilityWarning ?? '${model.name} loaded successfully.',
          ),
        ),
      );
      widget.onModelActivated?.call();
    }
  }

  Future<void> _deleteModel(DownloadableModel model) async {
    if (_modelsDir == null) return;

    if (_downloadUi.listenableFor(model.filename).value.isDownloading) {
      _cancelDownload(model);
    }

    await _modelService.deleteModel(_modelsDir!, model);
    if (!mounted) return;

    _updateDownloadUiState(
      model.filename,
      isDownloading: false,
      clearProgress: true,
      clearDetail: true,
    );
    _clearDownloadTracking(model.filename);
    await _disposeDownloadController(model.filename);
    await _refreshDownloadedModelState();
    if (!mounted) return;

    setState(() {});
  }

  Future<void> _removeCustomModelEntry(DownloadableModel model) async {
    final isCustom = _customModels.any(
      (entry) => entry.filename == model.filename && entry.url == model.url,
    );
    if (!isCustom) {
      return;
    }

    final cacheState = _cacheStateByFile[model.filename];
    final hasCachedAssets =
        _downloadedFiles.contains(model.filename) ||
        (cacheState?.availableAssetLabels.isNotEmpty ?? false);
    final removal = await showDialog<_CustomModelRemoval>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove from library?'),
        content: Text(
          hasCachedAssets
              ? 'Remove ${model.name} from your model library? You can keep its downloaded files or delete them too.'
              : 'Remove ${model.name} from your model library?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          if (hasCachedAssets)
            TextButton(
              onPressed: () =>
                  Navigator.of(context).pop(_CustomModelRemoval.entryOnly),
              child: const Text('Remove only'),
            ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(
              hasCachedAssets
                  ? _CustomModelRemoval.entryAndFiles
                  : _CustomModelRemoval.entryOnly,
            ),
            child: Text(hasCachedAssets ? 'Delete files & remove' : 'Remove'),
          ),
        ],
      ),
    );
    if (removal == null || !mounted) {
      return;
    }

    if (removal == _CustomModelRemoval.entryAndFiles) {
      await _deleteModel(model);
      if (!mounted) {
        return;
      }
    }

    setState(() {
      _models.removeWhere(
        (entry) => entry.filename == model.filename && entry.url == model.url,
      );
      _customModels.removeWhere(
        (entry) => entry.filename == model.filename && entry.url == model.url,
      );
    });
    await _saveCustomModels();
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Removed ${model.name} from the library.')),
    );
  }

  Future<void> _removeAllModels() async {
    if (!kIsWeb && _modelsDir == null) {
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Remove all models?'),
          content: const Text(
            'This removes all downloaded model files and clears all custom model entries.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Remove all'),
            ),
          ],
        );
      },
    );

    if (confirmed != true) {
      return;
    }

    if (!mounted) {
      return;
    }

    final provider = context.read<ChatProvider>();

    _pauseActiveDownloads();
    await _downloadUi.disposeDownloads();

    final snapshot = List<DownloadableModel>.from(_models);
    for (final model in snapshot) {
      await _modelService.deleteModel(_modelsDir ?? '', model);
    }

    _models
      ..clear()
      ..addAll(_initialModelCatalog());
    _customModels.clear();
    _downloadUi.clearUiState();
    _downloadUi.clearRateTracking();
    _includeProjectorByFile.clear();
    await _refreshDownloadedModelState(clearCacheStates: true);

    await _saveCustomModels();

    if (provider.isLoaded) {
      await provider.unloadModel();
    }
    provider.updateModelPath('');
    provider.updateMmprojPath('');

    if (!mounted) {
      return;
    }

    setState(() {
      _showModelLibrary = true;
      _activatingModel = null;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Removed all models and custom entries.')),
    );
  }

  void _resetModelParams(ChatProvider provider) {
    final selectedModel = _findSelectedModel(provider);
    if (selectedModel != null) {
      provider.updateGpuLayers(selectedModel.preset.gpuLayers);
      provider.updateContextSize(selectedModel.preset.contextSize);
    } else {
      provider.updateGpuLayers(32);
      provider.updateContextSize(4096);
    }

    provider.updateNumberOfThreads(0);
    provider.updateNumberOfThreadsBatch(0);
    provider.updateBatchSize(0);
    provider.updateMicroBatchSize(0);
  }

  void _resetInferenceParams(ChatProvider provider) {
    final selectedModel = _findSelectedModel(provider);
    if (selectedModel != null) {
      provider.updateMaxTokens(selectedModel.preset.maxTokens);
      provider.updateTemperature(selectedModel.preset.temperature);
      provider.updateTopK(selectedModel.preset.topK);
      provider.updateTopP(selectedModel.preset.topP);
      provider.updateMinP(selectedModel.preset.minP);
      provider.updatePenalty(selectedModel.preset.penalty);
      provider.updateThinkingEnabled(selectedModel.preset.thinkingEnabled);
      provider.updateThinkingBudgetTokens(
        selectedModel.preset.thinkingBudgetTokens,
      );
    } else {
      provider.updateMaxTokens(4096);
      provider.updateTemperature(0.7);
      provider.updateTopK(40);
      provider.updateTopP(0.9);
      provider.updateMinP(0.0);
      provider.updatePenalty(1.1);
      provider.updateThinkingEnabled(true);
      provider.updateThinkingBudgetTokens(0);
    }

    provider.updateSingleTurnMode(false);
  }

  DownloadableModel? _findSelectedModel(ChatProvider provider) {
    final path = provider.modelPath;
    if (path == null || path.isEmpty) {
      return null;
    }

    for (final model in _models) {
      if (path == model.url ||
          ((kIsWeb || _modelsDir != null) &&
              path == _resolveModelLoadReference(model))) {
        return model;
      }
      if (path.contains(model.filename)) {
        return model;
      }
    }
    return null;
  }

  String _resolveModelLoadReference(DownloadableModel model) {
    return _resolveAssetLoadReference(model.modelSourceFor(web: kIsWeb));
  }

  bool _hasUnsupportedWebAsset(DownloadableModel model) {
    if (model.modelSourceFor(web: true) is LocalModelAssetSource) {
      return true;
    }
    return model.multimodalProjectorSourceFor(web: true)
        is LocalModelAssetSource;
  }

  bool _isLiteRtLmWebModel(DownloadableModel model) {
    return model.filenameFor(web: true).toLowerCase().endsWith('.litertlm');
  }

  String _resolveAssetLoadReference(ModelAssetSource source) {
    if (source is LocalModelAssetSource) {
      return source.path;
    }
    final remote = source as RemoteModelAssetSource;
    if (kIsWeb) {
      return remote.url;
    }
    if (_modelsDir == null) {
      throw StateError('Models directory is not initialized.');
    }
    return '${_modelsDir!}/${remote.filename}';
  }

  String? _resolveMmprojPathForModel(DownloadableModel model) {
    if ((!model.isMultimodalFor(web: kIsWeb) &&
            !model.supportsTextToSpeechFor(web: kIsWeb)) ||
        model.mediaInputModeFor(web: kIsWeb) !=
            ModelMediaInputMode.externalProjector) {
      return null;
    }

    final source = model.multimodalProjectorSourceFor(web: kIsWeb);
    if (source != null) {
      return _resolveAssetLoadReference(source);
    }

    return model.supportsVisionFor(web: kIsWeb) ||
            model.supportsAudioFor(web: kIsWeb)
        ? _resolveModelLoadReference(model)
        : null;
  }

  String? _runtimeCapabilityWarning(
    DownloadableModel model,
    ChatProvider provider,
  ) {
    final missing = <String>[
      if (model.supportsVisionFor(web: kIsWeb) && !provider.supportsVision)
        'vision',
      if (model.supportsAudioFor(web: kIsWeb) && !provider.supportsAudio)
        'audio',
    ];
    if (missing.isEmpty) {
      return null;
    }

    final capabilityLabel = missing.length == 1
        ? missing.single
        : '${missing.take(missing.length - 1).join(', ')} and ${missing.last}';
    return 'Loaded, but the active runtime/projector did not report $capabilityLabel support. Media controls stay disabled for unsupported inputs.';
  }

  Future<void> _setSelectedModelMmprojMode(
    ChatProvider provider,
    DownloadableModel model, {
    required bool enable,
  }) async {
    if (!enable) {
      await provider.clearMmprojPath();
      return;
    }

    final mmprojPath = _resolveMmprojPathForModel(model);
    if (mmprojPath == null || mmprojPath.isEmpty) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No matching mmproj is configured for this model.'),
        ),
      );
      return;
    }

    provider.updateMmprojPath(mmprojPath);
    if (provider.isLoaded) {
      await provider.loadConfiguredMmproj();
      return;
    }

    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('mmproj configured. Load the model to activate it.'),
      ),
    );
  }

  Future<void> _loadConfiguredModel(ChatProvider provider) async {
    await provider.loadModel();
    if (!mounted) return;

    if (provider.error == null) {
      setState(() {
        _showModelLibrary = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Model loaded successfully.')),
      );
      widget.onModelActivated?.call();
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Failed to load model: ${provider.error}')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ChatProvider>(
      builder: (context, provider, _) {
        final width = MediaQuery.sizeOf(context).width;
        final isEmbedded = widget.embeddedPanel;
        final isWide = width >= 980 && !isEmbedded;
        final horizontalPadding = isEmbedded ? 12.0 : (isWide ? 28.0 : 16.0);
        final selectedModel = _findSelectedModel(provider);
        final selectedModelMmprojPath =
            selectedModel == null || (!kIsWeb && _modelsDir == null)
            ? null
            : _resolveMmprojPathForModel(selectedModel);
        final selectedBackend = _resolveSelectedBackend(provider);
        final contextOptions = _buildContextSizeOptions(provider.contextSize);
        final hasModelPath =
            provider.modelPath != null && provider.modelPath!.isNotEmpty;
        final usesLiteRtLmModel =
            provider.modelPath
                ?.split('?')
                .first
                .toLowerCase()
                .endsWith('.litertlm') ??
            false;
        final hasMmprojPath = (provider.settings.mmprojPath ?? '')
            .trim()
            .isNotEmpty;
        final canToggleSelectedModelMmproj =
            selectedModelMmprojPath != null &&
            selectedModelMmprojPath.isNotEmpty;
        final modelLabel = provider.activeModelName;
        final threadLabel = provider.numberOfThreads == 0
            ? '(auto detected)'
            : provider.numberOfThreads.toString();
        final threadBatchLabel = provider.numberOfThreadsBatch == 0
            ? '(auto detected)'
            : provider.numberOfThreadsBatch.toString();
        final batchSizeOptions = _buildBatchSizeOptions(provider.batchSize);
        final microBatchSizeOptions = _buildBatchSizeOptions(
          provider.microBatchSize,
        );
        final isMaximumGpuLayers = provider.gpuLayers >= 99;
        final isAutoTuning =
            selectedBackend == GpuBackend.auto && provider.autoTuneModelParams;
        final gpuLayersLabel = isAutoTuning
            ? isMaximumGpuLayers
                  ? 'Auto · Max'
                  : 'Auto · ${provider.gpuLayers}'
            : isMaximumGpuLayers
            ? 'Max'
            : provider.gpuLayers.toString();
        final gpuLayersSliderValue = isMaximumGpuLayers
            ? 99.0
            : provider.gpuLayers.clamp(0, 98).toDouble();
        final gpuOffloadDisabled =
            selectedBackend != GpuBackend.cpu && provider.gpuLayers == 0;
        final hasLoadProgress =
            provider.loadingProgress > 0 && provider.loadingProgress < 1;
        final loadProgressLabel = hasLoadProgress
            ? '${(provider.loadingProgress * 100).toStringAsFixed(0)}%'
            : null;
        final visibleModels = _visibleModels();
        final visibleDownloadedCount = visibleModels
            .where(_isModelDownloaded)
            .length;

        return ListView(
          controller: _scrollController,
          padding: EdgeInsets.fromLTRB(
            horizontalPadding,
            isEmbedded ? 14 : 24,
            horizontalPadding,
            isEmbedded ? 14 : 24,
          ),
          children: [
            Text(
              'Model',
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: Theme.of(
                    context,
                  ).colorScheme.outlineVariant.withValues(alpha: 0.45),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              modelLabel,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              provider.isLoaded
                                  ? 'Loaded'
                                  : (hasModelPath
                                        ? 'Configured (not loaded)'
                                        : 'No model selected'),
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                            ),
                          ],
                        ),
                      ),
                      if (hasModelPath)
                        OutlinedButton.icon(
                          onPressed: provider.isInitializing
                              ? null
                              : () => unawaited(
                                  provider.isLoaded
                                      ? provider.unloadModel()
                                      : _loadConfiguredModel(provider),
                                ),
                          icon: Icon(
                            provider.isLoaded
                                ? Icons.eject_outlined
                                : Icons.play_arrow_rounded,
                          ),
                          label: Text(provider.isLoaded ? 'Unload' : 'Load'),
                        ),
                    ],
                  ),
                  if (provider.isInitializing) ...[
                    const SizedBox(height: 10),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(999),
                      child: LinearProgressIndicator(
                        value: hasLoadProgress
                            ? provider.loadingProgress
                            : null,
                        minHeight: 8,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      loadProgressLabel == null
                          ? 'Loading model...'
                          : 'Loading model... $loadProgressLabel',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: () {
                      setState(() {
                        _showModelLibrary = !_showModelLibrary;
                      });
                    },
                    icon: Icon(
                      _showModelLibrary
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                    ),
                    label: Text(
                      _showModelLibrary
                          ? 'Hide model library'
                          : 'Manage models',
                    ),
                  ),
                  if (_showModelLibrary) ...[
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            'Model library',
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                        Text(
                          visibleDownloadedCount == 0
                              ? '${visibleModels.length} models'
                              : '$visibleDownloadedCount downloaded · ${visibleModels.length} total',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                        ),
                        const SizedBox(width: 4),
                        PopupMenuButton<_ModelLibraryMenuAction>(
                          tooltip: 'Model library actions',
                          icon: const Icon(Icons.more_horiz_rounded),
                          onSelected: (_) => unawaited(_removeAllModels()),
                          itemBuilder: (context) => [
                            PopupMenuItem(
                              value: _ModelLibraryMenuAction.removeAll,
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.delete_sweep_outlined,
                                    size: 19,
                                    color: Theme.of(context).colorScheme.error,
                                  ),
                                  const SizedBox(width: 10),
                                  Text(
                                    'Remove all models',
                                    style: TextStyle(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.error,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _modelSearchController,
                      onChanged: (value) {
                        setState(() {
                          _modelSearchQuery = value;
                        });
                      },
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration(
                        hintText: 'Search models or capabilities',
                        prefixIcon: const Icon(Icons.search_rounded),
                        suffixIcon: _modelSearchQuery.isEmpty
                            ? null
                            : IconButton(
                                onPressed: () {
                                  FocusScope.of(context).unfocus();
                                  _modelSearchController.clear();
                                  setState(() {
                                    _modelSearchQuery = '';
                                  });
                                },
                                tooltip: 'Clear model search',
                                icon: const Icon(Icons.close_rounded),
                              ),
                        filled: true,
                        fillColor: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerLowest,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 12,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: _ModelPlatformFilter.values
                            .map((filter) {
                              final (label, icon) = switch (filter) {
                                _ModelPlatformFilter.all => (
                                  'All',
                                  Icons.apps_rounded,
                                ),
                                _ModelPlatformFilter.mobile => (
                                  'Mobile',
                                  Icons.smartphone_rounded,
                                ),
                                _ModelPlatformFilter.web => (
                                  'Web',
                                  Icons.language_rounded,
                                ),
                                _ModelPlatformFilter.desktop => (
                                  'Desktop',
                                  Icons.desktop_mac_outlined,
                                ),
                              };
                              return Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: ChoiceChip(
                                  selected: _modelPlatformFilter == filter,
                                  materialTapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                  visualDensity: VisualDensity.compact,
                                  labelPadding: const EdgeInsets.symmetric(
                                    horizontal: 4,
                                  ),
                                  onSelected: (_) {
                                    setState(() {
                                      _modelPlatformFilter = filter;
                                    });
                                  },
                                  avatar: Icon(icon, size: 16),
                                  label: Text(label),
                                ),
                              );
                            })
                            .toList(growable: false),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: _showDiscoverPopularModelsDialog,
                          icon: const Icon(Icons.auto_awesome_rounded),
                          label: const Text('Discover'),
                        ),
                        OutlinedButton.icon(
                          onPressed: _showAddHuggingFaceDialog,
                          icon: const Icon(Icons.add_link_rounded),
                          label: const Text('Add model'),
                        ),
                      ],
                    ),
                    if (!kIsWeb && _modelsDir == null)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 40),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else if (visibleModels.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 32),
                        child: Column(
                          children: [
                            Icon(
                              Icons.search_off_rounded,
                              size: 32,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                            const SizedBox(height: 10),
                            Text(
                              'No models match these filters',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Try another platform or a broader search.',
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                            ),
                          ],
                        ),
                      )
                    else
                      ...visibleModels.map((model) {
                        final selectedPath = _resolveModelLoadReference(model);
                        final isActivating = _activatingModel == model.filename;
                        final downloadStateListenable = _downloadUi
                            .listenableFor(model.filename);

                        return ValueListenableBuilder<ModelDownloadUiState>(
                          valueListenable: downloadStateListenable,
                          builder: (context, downloadState, _) {
                            final detail = downloadState.detail;
                            final taskLabel = downloadTaskLabel(
                              downloadState.task,
                              isWeb: kIsWeb,
                            );
                            final queueLabel = downloadState.isQueued
                                ? 'Queued${downloadState.queuePosition == null ? '' : ' (#${downloadState.queuePosition})'}'
                                : null;

                            final card = ModelCard(
                              model: model,
                              isDownloaded: _downloadedFiles.contains(
                                model.filename,
                              ),
                              cacheState: _cacheStateByFile[model.filename],
                              isDownloading: downloadState.isDownloading,
                              isQueued: downloadState.isQueued,
                              queuePosition: downloadState.queuePosition,
                              progress: downloadState.progress,
                              downloadStatusLabel: detail == null
                                  ? (queueLabel ?? taskLabel)
                                  : downloadStageLabel(detail, isWeb: kIsWeb),
                              downloadTransferLabel: detail == null
                                  ? null
                                  : _downloadUi.transferLabel(
                                      model.filename,
                                      detail,
                                    ),
                              isWeb: kIsWeb,
                              isAvailableOnCurrentPlatform:
                                  _isAvailableOnCurrentPlatform(model),
                              isSelected: provider.modelPath == selectedPath,
                              gpuLayers: provider.gpuLayers,
                              contextSize: provider.contextSize,
                              onGpuLayersChanged: provider.updateGpuLayers,
                              onContextSizeChanged: provider.updateContextSize,
                              onSelect: isActivating
                                  ? null
                                  : () => unawaited(_selectModel(model)),
                              onDownload: () =>
                                  unawaited(_downloadModel(model)),
                              onDelete: () => unawaited(_deleteModel(model)),
                              isCustom: _customModels.contains(model),
                              onRemoveFromLibrary: () =>
                                  unawaited(_removeCustomModelEntry(model)),
                              onCancel: () => _cancelDownload(model),
                              includeProjector: _includeProjectorFor(model),
                              onIncludeProjectorChanged: (value) =>
                                  _setIncludeProjector(model, value),
                            );

                            final isFocused =
                                _focusedModelFilename == model.filename;
                            return AnimatedContainer(
                              key: ValueKey(
                                'model-card-highlight-${model.filename}',
                              ),
                              duration: const Duration(milliseconds: 220),
                              curve: Curves.easeOut,
                              padding: EdgeInsets.all(isFocused ? 3 : 0),
                              margin: const EdgeInsets.only(bottom: 14),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(23),
                                border: isFocused
                                    ? Border.all(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.primary,
                                        width: 2,
                                      )
                                    : null,
                              ),
                              child: Stack(
                                key: _modelCardKeys.putIfAbsent(
                                  model.filename,
                                  GlobalKey.new,
                                ),
                                children: [
                                  card,
                                  if (isActivating)
                                    Positioned.fill(
                                      child: DecoratedBox(
                                        decoration: BoxDecoration(
                                          color: Colors.black.withValues(
                                            alpha: 0.35,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            20,
                                          ),
                                        ),
                                        child: Center(
                                          child: Container(
                                            width: 210,
                                            padding: const EdgeInsets.all(12),
                                            decoration: BoxDecoration(
                                              color: Colors.black.withValues(
                                                alpha: 0.45,
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(14),
                                              border: Border.all(
                                                color: Colors.white.withValues(
                                                  alpha: 0.16,
                                                ),
                                              ),
                                            ),
                                            child: Column(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Text(
                                                  hasLoadProgress
                                                      ? 'Loading ${loadProgressLabel!}'
                                                      : 'Loading model...',
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .bodySmall
                                                      ?.copyWith(
                                                        color: Colors.white,
                                                        fontWeight:
                                                            FontWeight.w600,
                                                      ),
                                                ),
                                                const SizedBox(height: 8),
                                                LinearProgressIndicator(
                                                  value: hasLoadProgress
                                                      ? provider.loadingProgress
                                                      : null,
                                                  minHeight: 6,
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            );
                          },
                        );
                      }),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: Theme.of(
                    context,
                  ).colorScheme.outlineVariant.withValues(alpha: 0.45),
                ),
              ),
              child: Theme(
                data: Theme.of(
                  context,
                ).copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  initiallyExpanded: _modelParametersExpanded,
                  onExpansionChanged: (expanded) {
                    setState(() {
                      _modelParametersExpanded = expanded;
                    });
                  },
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(top: 8),
                  shape: const RoundedRectangleBorder(),
                  collapsedShape: const RoundedRectangleBorder(),
                  title: Text(
                    'Model parameters',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  subtitle: Text(
                    'GPU layers, backend, context, batching, and runtime threads',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  children: [
                    if (provider.supportsLiveSpeechFeature) ...[
                      SwitchListTile.adaptive(
                        key: const ValueKey<String>(
                          'live_speech_enabled_switch',
                        ),
                        value: provider.liveSpeechEnabled,
                        secondary: const Icon(Icons.subtitles_rounded),
                        title: const Text('Live dictation'),
                        subtitle: const Text(
                          'Use a separate on-device English speech model to '
                          'put microphone text in the composer. Nothing is '
                          'sent until you tap Send.',
                        ),
                        contentPadding: EdgeInsets.zero,
                        onChanged: (enabled) => unawaited(
                          provider.updateLiveSpeechEnabled(enabled),
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],
                    _LabeledSlider(
                      label: 'GPU layers',
                      valueLabel: gpuLayersLabel,
                      min: 0,
                      max: 99,
                      divisions: 99,
                      value: gpuLayersSliderValue,
                      onChanged: (value) =>
                          provider.updateGpuLayers(value.round()),
                    ),
                    const SizedBox(height: 10),
                    _LabeledSlider(
                      label: '# threads',
                      valueLabel: threadLabel,
                      min: 0,
                      max: 32,
                      divisions: 32,
                      value: provider.numberOfThreads.toDouble(),
                      onChanged: (value) =>
                          provider.updateNumberOfThreads(value.toInt()),
                    ),
                    const SizedBox(height: 10),
                    _LabeledSlider(
                      label: '# batch threads',
                      valueLabel: threadBatchLabel,
                      min: 0,
                      max: 64,
                      divisions: 64,
                      value: provider.numberOfThreadsBatch.toDouble(),
                      onChanged: (value) =>
                          provider.updateNumberOfThreadsBatch(value.toInt()),
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<int>(
                      initialValue: provider.contextSize,
                      decoration: const InputDecoration(
                        labelText: 'Context size',
                      ),
                      items: contextOptions
                          .map(
                            (option) => DropdownMenuItem<int>(
                              value: option,
                              child: Text(
                                option == 0 ? 'Auto (Native)' : '$option',
                              ),
                            ),
                          )
                          .toList(growable: false),
                      onChanged: (value) {
                        if (value != null) {
                          provider.updateContextSize(value);
                        }
                      },
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<int>(
                      initialValue: provider.batchSize,
                      decoration: InputDecoration(
                        labelText: 'Batch size (n_batch)',
                        helperText: usesLiteRtLmModel
                            ? 'Not used by LiteRT-LM'
                            : null,
                      ),
                      items: batchSizeOptions
                          .map(
                            (option) => DropdownMenuItem<int>(
                              value: option,
                              child: Text(option == 0 ? 'Auto' : '$option'),
                            ),
                          )
                          .toList(growable: false),
                      onChanged: usesLiteRtLmModel
                          ? null
                          : (value) {
                              if (value != null) {
                                provider.updateBatchSize(value);
                              }
                            },
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<int>(
                      initialValue: provider.microBatchSize,
                      decoration: InputDecoration(
                        labelText: 'Micro-batch size (n_ubatch)',
                        helperText: usesLiteRtLmModel
                            ? 'Not used by LiteRT-LM'
                            : null,
                      ),
                      items: microBatchSizeOptions
                          .map(
                            (option) => DropdownMenuItem<int>(
                              value: option,
                              child: Text(option == 0 ? 'Auto' : '$option'),
                            ),
                          )
                          .toList(growable: false),
                      onChanged: usesLiteRtLmModel
                          ? null
                          : (value) {
                              if (value != null) {
                                provider.updateMicroBatchSize(value);
                              }
                            },
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<GpuBackend>(
                      initialValue: selectedBackend,
                      decoration: const InputDecoration(
                        labelText: 'Preferred backend',
                      ),
                      items: _getAvailableBackends(provider)
                          .map(
                            (backend) => DropdownMenuItem<GpuBackend>(
                              value: backend,
                              child: Text(_backendLabel(backend)),
                            ),
                          )
                          .toList(growable: false),
                      onChanged: (value) {
                        if (value != null) {
                          unawaited(provider.updatePreferredBackend(value));
                        }
                      },
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        provider.isLoaded
                            ? 'Active backend: ${provider.activeBackend}'
                            : 'Active backend is shown after the model loads.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Wrap(
                        spacing: 10,
                        runSpacing: 10,
                        children: [
                          if (canToggleSelectedModelMmproj)
                            OutlinedButton.icon(
                              onPressed: provider.isInitializing
                                  ? null
                                  : () => unawaited(
                                      _setSelectedModelMmprojMode(
                                        provider,
                                        selectedModel!,
                                        enable: !hasMmprojPath,
                                      ),
                                    ),
                              icon: Icon(
                                hasMmprojPath
                                    ? Icons.visibility_off_outlined
                                    : Icons.visibility_outlined,
                              ),
                              label: Text(
                                hasMmprojPath ? 'Text only' : 'Use mmproj',
                              ),
                            )
                          else if (hasMmprojPath)
                            OutlinedButton.icon(
                              onPressed: provider.isInitializing
                                  ? null
                                  : () => unawaited(provider.clearMmprojPath()),
                              icon: const Icon(Icons.visibility_off_outlined),
                              label: const Text('Disable mmproj'),
                            ),
                          if (hasMmprojPath &&
                              provider.isLoaded &&
                              !provider.isMmprojLoaded)
                            FilledButton.tonalIcon(
                              onPressed: provider.isInitializing
                                  ? null
                                  : () => unawaited(
                                      provider.loadConfiguredMmproj(),
                                    ),
                              icon: const Icon(Icons.visibility_rounded),
                              label: const Text('Load mmproj'),
                            ),
                          if (provider.isLoaded)
                            FilledButton.tonalIcon(
                              onPressed: provider.isInitializing
                                  ? null
                                  : () async {
                                      await provider.unloadModel();
                                      if (!mounted) return;
                                      await _loadConfiguredModel(provider);
                                    },
                              icon: const Icon(Icons.refresh_rounded),
                              label: const Text('Reload model'),
                            ),
                          FilledButton.tonal(
                            onPressed: () => _resetModelParams(provider),
                            child: const Text('Reset model params'),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 4),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        [
                          if (hasMmprojPath)
                            'mmproj is configured for this model. Use Text only to disable it, or Load mmproj to attach it without a full reload.',
                          if (gpuOffloadDisabled)
                            'GPU layers is 0, so inference will run on CPU. Increase it or choose Max to enable GPU offload.',
                          isAutoTuning
                              ? 'Auto tuning recalculates GPU layers and context headroom on every model load. Auto selects Metal on supported Macs.'
                              : 'GPU layers controls how much of the model is offloaded; Max enables Auto tuning with the Auto backend. Changes apply on next model load.',
                        ].join(' '),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: gpuOffloadDisabled
                              ? Theme.of(context).colorScheme.error
                              : Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: Theme.of(
                    context,
                  ).colorScheme.outlineVariant.withValues(alpha: 0.45),
                ),
              ),
              child: Theme(
                data: Theme.of(
                  context,
                ).copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  initiallyExpanded: _inferenceParametersExpanded,
                  onExpansionChanged: (expanded) {
                    setState(() {
                      _inferenceParametersExpanded = expanded;
                    });
                  },
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(top: 8),
                  shape: const RoundedRectangleBorder(),
                  collapsedShape: const RoundedRectangleBorder(),
                  title: Text(
                    'Inference parameters',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  subtitle: Text(
                    'Sampling, tool behavior, and thinking controls',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  children: [
                    _LabeledSlider(
                      label: 'Max generated tokens',
                      valueLabel: provider.maxGenerationTokens.toString(),
                      min: 512,
                      max: 32768,
                      divisions: (32768 - 512) ~/ 512,
                      value: provider.maxGenerationTokens.toDouble(),
                      onChanged: (value) =>
                          provider.updateMaxTokens(value.toInt()),
                    ),
                    const SizedBox(height: 10),
                    _LabeledSlider(
                      label: 'Temperature',
                      valueLabel: provider.temperature.toStringAsFixed(2),
                      min: 0,
                      max: 2,
                      divisions: 40,
                      value: provider.temperature,
                      onChanged: provider.updateTemperature,
                    ),
                    const SizedBox(height: 10),
                    _LabeledSlider(
                      label: 'Top-K',
                      valueLabel: provider.topK.toString(),
                      min: 1,
                      max: 100,
                      divisions: 99,
                      value: provider.topK.toDouble(),
                      onChanged: (value) => provider.updateTopK(value.toInt()),
                    ),
                    const SizedBox(height: 10),
                    _LabeledSlider(
                      label: 'Top-P',
                      valueLabel: provider.topP.toStringAsFixed(2),
                      min: 0,
                      max: 1,
                      divisions: 50,
                      value: provider.topP,
                      onChanged: provider.updateTopP,
                    ),
                    const SizedBox(height: 10),
                    _LabeledSlider(
                      label: 'Min-P',
                      valueLabel: provider.minP.toStringAsFixed(2),
                      min: 0,
                      max: 1,
                      divisions: 100,
                      value: provider.minP,
                      onChanged: provider.updateMinP,
                    ),
                    const SizedBox(height: 10),
                    _LabeledSlider(
                      label: 'Repetition penalty',
                      valueLabel: provider.penalty.toStringAsFixed(2),
                      min: 0.8,
                      max: 2.0,
                      divisions: 60,
                      value: provider.penalty,
                      onChanged: provider.updatePenalty,
                    ),
                    const SizedBox(height: 8),
                    SwitchListTile.adaptive(
                      value: provider.toolsEnabled,
                      title: const Text('Function calling'),
                      subtitle: Text(
                        provider.templateSupportsTools
                            ? 'Allow the model to emit tool calls.'
                            : 'Unavailable for this loaded runtime/template.',
                      ),
                      contentPadding: EdgeInsets.zero,
                      onChanged: provider.templateSupportsTools
                          ? provider.updateToolsEnabled
                          : null,
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: () =>
                            showToolDeclarationsDialog(context, provider),
                        icon: const Icon(Icons.edit_outlined, size: 16),
                        label: const Text('Edit declarations'),
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '${provider.declaredToolCount} declaration(s) loaded',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    if (provider.toolDeclarationsError != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Text(
                            provider.toolDeclarationsError!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    SwitchListTile.adaptive(
                      value: provider.thinkingEnabled,
                      title: const Text('Enable thinking output'),
                      subtitle: Text(
                        provider.thinkingControlsSupported
                            ? 'Sends thinking-disable hint to template handlers.'
                            : 'Unavailable for this loaded runtime.',
                      ),
                      contentPadding: EdgeInsets.zero,
                      onChanged: provider.thinkingControlsSupported
                          ? provider.updateThinkingEnabled
                          : null,
                    ),
                    const SizedBox(height: 10),
                    _LabeledSlider(
                      label: 'Thinking budget',
                      valueLabel: provider.thinkingBudgetTokens == 0
                          ? 'Auto'
                          : provider.thinkingBudgetTokens.toString(),
                      min: 0,
                      max: 4096,
                      divisions: 64,
                      value: provider.thinkingBudgetTokens.toDouble(),
                      onChanged: provider.thinkingControlsSupported
                          ? (value) => provider.updateThinkingBudgetTokens(
                              value.toInt(),
                            )
                          : null,
                    ),
                    SwitchListTile.adaptive(
                      value: provider.singleTurnMode,
                      title: const Text('Single-turn mode'),
                      subtitle: const Text(
                        'Each prompt runs without previous turn context.',
                      ),
                      contentPadding: EdgeInsets.zero,
                      onChanged: provider.updateSingleTurnMode,
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        FilledButton.tonal(
                          onPressed: () => _resetInferenceParams(provider),
                          child: const Text('Reset inference params'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: Theme.of(
                    context,
                  ).colorScheme.outlineVariant.withValues(alpha: 0.45),
                ),
              ),
              child: Theme(
                data: Theme.of(
                  context,
                ).copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  initiallyExpanded: _advancedExpanded,
                  onExpansionChanged: (expanded) {
                    setState(() {
                      _advancedExpanded = expanded;
                    });
                  },
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(top: 8),
                  shape: const RoundedRectangleBorder(),
                  collapsedShape: const RoundedRectangleBorder(),
                  title: Text(
                    'Advanced',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  subtitle: Text(
                    'Diagnostics and runtime logging',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  children: [
                    DropdownButtonFormField<LlamaLogLevel>(
                      initialValue: provider.dartLogLevel,
                      decoration: const InputDecoration(
                        labelText: 'Dart log level',
                      ),
                      items: LlamaLogLevel.values
                          .map(
                            (level) => DropdownMenuItem<LlamaLogLevel>(
                              value: level,
                              child: Text(_logLevelLabel(level)),
                            ),
                          )
                          .toList(growable: false),
                      onChanged: (value) {
                        if (value != null) {
                          provider.updateLogLevel(value);
                        }
                      },
                    ),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<LlamaLogLevel>(
                      initialValue: provider.nativeLogLevel,
                      decoration: InputDecoration(
                        labelText: kIsWeb
                            ? 'Bridge/runtime log level'
                            : 'Native log level',
                        helperText: kIsWeb
                            ? 'Applies to bridge/core logs. For startup diagnostics set window.__llamadartBridgeBootstrapVerbose = true; for pthread warnings align window.__llamadartBridgeThreadPoolSize.'
                            : null,
                      ),
                      items: LlamaLogLevel.values
                          .map(
                            (level) => DropdownMenuItem<LlamaLogLevel>(
                              value: level,
                              child: Text(_logLevelLabel(level)),
                            ),
                          )
                          .toList(growable: false),
                      onChanged: (value) {
                        if (value != null) {
                          provider.updateNativeLogLevel(value);
                        }
                      },
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  List<int> _buildContextSizeOptions(int current) {
    final values = <int>{0, 2048, 4096, 8192, 16384, 32768, current}.toList()
      ..sort();
    return values;
  }

  List<int> _buildBatchSizeOptions(int current) {
    final values = <int>{
      0,
      1,
      16,
      32,
      64,
      128,
      256,
      512,
      1024,
      2048,
      current,
    }.toList()..sort();
    return values;
  }

  List<GpuBackend> _getAvailableBackends(ChatProvider provider) {
    return BackendUtils.availableBackends(
      devices: provider.availableDevices,
      activeBackend: provider.activeBackend,
      includeAuto: true,
    );
  }

  GpuBackend _resolveSelectedBackend(ChatProvider provider) {
    final available = _getAvailableBackends(provider);
    if (available.contains(provider.preferredBackend)) {
      return provider.preferredBackend;
    }
    if (available.contains(GpuBackend.cpu)) {
      return GpuBackend.cpu;
    }
    return available.first;
  }

  String _backendLabel(GpuBackend backend) {
    if (kIsWeb && backend == GpuBackend.auto) {
      return 'WEBGPU';
    }
    return backend.name.toUpperCase();
  }

  String _logLevelLabel(LlamaLogLevel level) {
    return switch (level) {
      LlamaLogLevel.none => 'None',
      LlamaLogLevel.error => 'Error',
      LlamaLogLevel.warn => 'Warn',
      LlamaLogLevel.info => 'Info',
      LlamaLogLevel.debug => 'Debug',
    };
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _modelSearchController.dispose();
    _scrollController.dispose();
    _completedDownloadHighlightTimer?.cancel();
    unawaited(_downloadFinishedSubscription?.cancel());
    if (_ownsDownloadUi) {
      _downloadUi.dispose();
    }
    super.dispose();
  }
}

class _PopularModelsDiscoverySheet extends StatefulWidget {
  final HuggingFaceModelDiscoveryService discoveryService;
  final List<DownloadableModel> existingModels;

  const _PopularModelsDiscoverySheet({
    required this.discoveryService,
    required this.existingModels,
  });

  @override
  State<_PopularModelsDiscoverySheet> createState() =>
      _PopularModelsDiscoverySheetState();
}

class _PopularModelsDiscoverySheetState
    extends State<_PopularModelsDiscoverySheet> {
  static const String _prefsDiscoveryCacheKey = 'hf_discovery_cache_v1';
  static const int _pageSize = 20;

  bool _isLoading = true;
  String? _error;
  List<HfDiscoveredModel> _allModels = const <HfDiscoveredModel>[];
  int _loadRequestSerial = 0;
  Timer? _refreshDebounce;
  final TextEditingController _searchController = TextEditingController();
  int _visibleCount = _pageSize;

  String _searchQuery = '';
  HfDiscoverySort _sortBy = HfDiscoverySort.trending;
  HfPipelineTagFilter _pipelineTag = HfPipelineTagFilter.any;

  HfDiscoveryFilters get _activeFilters => HfDiscoveryFilters(
    searchQuery: _searchQuery,
    sort: _sortBy,
    pipelineTag: _pipelineTag,
  );

  Set<String> get _existingKeys {
    final keys = <String>{};
    for (final model in widget.existingModels) {
      keys.add(model.filename);
      keys.add(model.url);
    }
    return keys;
  }

  @override
  void initState() {
    super.initState();
    unawaited(_bootstrap());
  }

  @override
  void dispose() {
    _refreshDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    await _restorePersistedCache();
    if (!mounted) {
      return;
    }
    await _load(showLoading: _allModels.isEmpty);
  }

  String _filtersCacheKey(HfDiscoveryFilters filters) {
    return [
      filters.sort.name,
      filters.pipelineTag.name,
      filters.searchQuery.trim().toLowerCase(),
    ].join('|');
  }

  Future<void> _restorePersistedCache() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsDiscoveryCacheKey);
    if (raw == null || raw.isEmpty) {
      return;
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return;
      }

      final key = decoded['filtersKey'] as String?;
      if (key != _filtersCacheKey(_activeFilters)) {
        return;
      }

      final timestampRaw = decoded['timestamp'] as String?;
      final timestamp = timestampRaw == null
          ? null
          : DateTime.tryParse(timestampRaw);
      if (timestamp == null ||
          DateTime.now().difference(timestamp) > const Duration(hours: 12)) {
        return;
      }

      final modelsRaw = decoded['models'];
      if (modelsRaw is! List) {
        return;
      }

      final restored = modelsRaw
          .whereType<Map>()
          .map((row) => _decodeDiscoveredModel(row))
          .whereType<HfDiscoveredModel>()
          .toList(growable: false);

      if (restored.isEmpty || !mounted) {
        return;
      }

      setState(() {
        _allModels = restored;
        _visibleCount = math.min(_pageSize, restored.length);
        _isLoading = false;
      });
    } catch (_) {
      return;
    }
  }

  Future<void> _persistCache(List<HfDiscoveredModel> models) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final payload = <String, dynamic>{
        'filtersKey': _filtersCacheKey(_activeFilters),
        'timestamp': DateTime.now().toIso8601String(),
        'models': models.map(_encodeDiscoveredModel).toList(growable: false),
      };
      await prefs.setString(_prefsDiscoveryCacheKey, jsonEncode(payload));
    } catch (_) {
      return;
    }
  }

  Map<String, dynamic> _encodeDiscoveredModel(HfDiscoveredModel entry) {
    final m = entry.model;
    return <String, dynamic>{
      'repositoryId': entry.repositoryId,
      'downloads': entry.downloads,
      'likes': entry.likes,
      'hasLiveStats': entry.hasLiveStats,
      'modelScaleB': entry.modelScaleB,
      'model': <String, dynamic>{
        'name': m.name,
        'description': m.description,
        'url': m.url,
        'filename': m.filename,
        'mmprojUrl': m.mmprojUrl,
        'mmprojFilename': m.mmprojFilename,
        'sizeBytes': m.sizeBytes,
        'supportsVision': m.supportsVision,
        'supportsAudio': m.supportsAudio,
        'supportsSpeechToText': m.supportsSpeechToText,
        'supportsVideo': m.supportsVideo,
        'supportsToolCalling': m.supportsToolCalling,
        'supportsThinking': m.supportsThinking,
        'minRamGb': m.minRamGb,
        'preset': <String, dynamic>{
          'temperature': m.preset.temperature,
          'topK': m.preset.topK,
          'topP': m.preset.topP,
          'minP': m.preset.minP,
          'penalty': m.preset.penalty,
          'thinkingBudgetTokens': m.preset.thinkingBudgetTokens,
          'contextSize': m.preset.contextSize,
          'maxTokens': m.preset.maxTokens,
          'thinkingEnabled': m.preset.thinkingEnabled,
          'gpuLayers': m.preset.gpuLayers,
        },
      },
    };
  }

  HfDiscoveredModel? _decodeDiscoveredModel(Map raw) {
    final modelRaw = raw['model'];
    if (modelRaw is! Map) {
      return null;
    }

    final presetRaw = modelRaw['preset'] is Map
        ? modelRaw['preset'] as Map
        : null;

    double asDouble(Object? value, double fallback) {
      if (value is num) {
        return value.toDouble();
      }
      return fallback;
    }

    int asInt(Object? value, int fallback) {
      if (value is num) {
        return value.toInt();
      }
      return fallback;
    }

    bool asBool(Object? value, bool fallback) {
      if (value is bool) {
        return value;
      }
      return fallback;
    }

    final model = DownloadableModel(
      name: (modelRaw['name'] as String?) ?? 'Unknown model',
      description: (modelRaw['description'] as String?) ?? '',
      url: (modelRaw['url'] as String?) ?? '',
      filename: (modelRaw['filename'] as String?) ?? '',
      mmprojUrl: modelRaw['mmprojUrl'] as String?,
      mmprojFilename: modelRaw['mmprojFilename'] as String?,
      sizeBytes: (modelRaw['sizeBytes'] as num?)?.toInt() ?? 0,
      supportsVision: (modelRaw['supportsVision'] as bool?) ?? false,
      supportsAudio: (modelRaw['supportsAudio'] as bool?) ?? false,
      supportsSpeechToText:
          (modelRaw['supportsSpeechToText'] as bool?) ?? false,
      supportsVideo: (modelRaw['supportsVideo'] as bool?) ?? false,
      supportsToolCalling: (modelRaw['supportsToolCalling'] as bool?) ?? false,
      supportsThinking: (modelRaw['supportsThinking'] as bool?) ?? false,
      minRamGb: (modelRaw['minRamGb'] as num?)?.toInt() ?? 2,
      preset: ModelPreset(
        temperature: asDouble(presetRaw?['temperature'], 0.7),
        topK: asInt(presetRaw?['topK'], 40),
        topP: asDouble(presetRaw?['topP'], 0.9),
        minP: asDouble(presetRaw?['minP'], 0.0),
        penalty: asDouble(presetRaw?['penalty'], 1.1),
        thinkingBudgetTokens: asInt(presetRaw?['thinkingBudgetTokens'], 0),
        contextSize: asInt(presetRaw?['contextSize'], 4096),
        maxTokens: asInt(presetRaw?['maxTokens'], 4096),
        thinkingEnabled: asBool(presetRaw?['thinkingEnabled'], true),
        gpuLayers: asInt(presetRaw?['gpuLayers'], 99),
      ),
    );

    if (model.url.isEmpty || model.filename.isEmpty) {
      return null;
    }

    return HfDiscoveredModel(
      model: model,
      repositoryId: (raw['repositoryId'] as String?) ?? model.name,
      downloads: (raw['downloads'] as num?)?.toInt() ?? 0,
      likes: (raw['likes'] as num?)?.toInt() ?? 0,
      hasLiveStats: (raw['hasLiveStats'] as bool?) ?? false,
      modelScaleB: (raw['modelScaleB'] as num?)?.toDouble(),
    );
  }

  void _scheduleRefresh() {
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) {
        return;
      }
      unawaited(_load());
    });
  }

  Future<void> _load({
    bool forceRefresh = false,
    bool showLoading = true,
  }) async {
    final requestSerial = ++_loadRequestSerial;

    if (showLoading) {
      setState(() {
        _isLoading = true;
        _error = null;
      });
    } else {
      _error = null;
    }

    try {
      final models = await widget.discoveryService.discoverPopularModels(
        filters: _activeFilters,
        forceRefresh: forceRefresh,
      );

      if (!mounted || requestSerial != _loadRequestSerial) {
        return;
      }

      setState(() {
        _allModels = models;
        _visibleCount = math.min(_pageSize, models.length);
        _isLoading = false;
      });
      unawaited(_persistCache(models));
    } catch (e) {
      if (!mounted || requestSerial != _loadRequestSerial) {
        return;
      }

      setState(() {
        _isLoading = false;
        _error = e.toString();
      });
    }
  }

  String _formatCompact(int value) {
    if (value >= 1000000) {
      return '${(value / 1000000).toStringAsFixed(1)}M';
    }
    if (value >= 1000) {
      return '${(value / 1000).toStringAsFixed(1)}k';
    }
    return value.toString();
  }

  String _formatModelMetadata(HfDiscoveredModel entry) {
    final details = <String>[];

    if (entry.modelScaleB != null) {
      details.add(entry.modelScaleLabel);
    }

    if (entry.model.sizeBytes > 0) {
      details.add(entry.model.sizeLabelFor(web: kIsWeb));
    }

    if (entry.model.minRamGb > 0) {
      details.add('${entry.model.minRamGb} GB RAM');
    }

    if (details.isEmpty) {
      return 'Size/RAM metadata unavailable from API';
    }

    return details.join(' • ');
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _allModels;
    final visibleCount = math.min(_visibleCount, filtered.length);
    final visibleModels = filtered.take(visibleCount).toList(growable: false);
    final hasMore = visibleCount < filtered.length;
    final existing = _existingKeys;

    return FractionallySizedBox(
      heightFactor: 0.9,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.outlineVariant,
                  borderRadius: BorderRadius.circular(99),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Discover popular Hugging Face GGUF models',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: _isLoading
                      ? null
                      : () {
                          _refreshDebounce?.cancel();
                          unawaited(_load(forceRefresh: true));
                        },
                  tooltip: 'Refresh popularity',
                  icon: const Icon(
                    Icons.refresh_rounded,
                    semanticLabel: kIsWeb ? null : 'Refresh popularity',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              'Live results from Hugging Face official API only (`/api/models` with `filter=gguf`, optional `pipeline_tag`, search, and sort). File size and RAM are shown only when API metadata is available.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: Theme.of(
                    context,
                  ).colorScheme.outlineVariant.withValues(alpha: 0.45),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _searchController,
                    textInputAction: TextInputAction.search,
                    onChanged: (value) {
                      setState(() {
                        _searchQuery = value;
                      });
                      _scheduleRefresh();
                    },
                    decoration: InputDecoration(
                      labelText: 'Search Hugging Face models',
                      hintText: 'e.g. qwen, llama, gemma, audio',
                      prefixIcon: const Icon(Icons.search_rounded),
                      suffixIcon: _searchQuery.trim().isEmpty
                          ? null
                          : IconButton(
                              tooltip: 'Clear search',
                              onPressed: () {
                                _searchController.clear();
                                setState(() {
                                  _searchQuery = '';
                                });
                                _scheduleRefresh();
                              },
                              icon: const Icon(
                                Icons.clear_rounded,
                                semanticLabel: kIsWeb ? null : 'Clear search',
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<HfDiscoverySort>(
                          initialValue: _sortBy,
                          decoration: const InputDecoration(labelText: 'Sort'),
                          items: const [
                            DropdownMenuItem<HfDiscoverySort>(
                              value: HfDiscoverySort.trending,
                              child: Text('Trending'),
                            ),
                            DropdownMenuItem<HfDiscoverySort>(
                              value: HfDiscoverySort.downloads,
                              child: Text('Downloads'),
                            ),
                          ],
                          onChanged: (value) {
                            if (value == null) {
                              return;
                            }
                            setState(() {
                              _sortBy = value;
                            });
                            _scheduleRefresh();
                          },
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: DropdownButtonFormField<HfPipelineTagFilter>(
                          initialValue: _pipelineTag,
                          decoration: const InputDecoration(
                            labelText: 'Pipeline',
                          ),
                          items: const [
                            DropdownMenuItem<HfPipelineTagFilter>(
                              value: HfPipelineTagFilter.any,
                              child: Text('Any'),
                            ),
                            DropdownMenuItem<HfPipelineTagFilter>(
                              value: HfPipelineTagFilter.textGeneration,
                              child: Text('Text generation'),
                            ),
                            DropdownMenuItem<HfPipelineTagFilter>(
                              value: HfPipelineTagFilter.imageTextToText,
                              child: Text('Vision'),
                            ),
                            DropdownMenuItem<HfPipelineTagFilter>(
                              value: HfPipelineTagFilter.audioTextToText,
                              child: Text('Audio'),
                            ),
                          ],
                          onChanged: (value) {
                            if (value == null) {
                              return;
                            }
                            setState(() {
                              _pipelineTag = value;
                            });
                            _scheduleRefresh();
                          },
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const SizedBox(height: 2),
                  Text(
                    hasMore
                        ? 'Showing $visibleCount of ${filtered.length} model(s)'
                        : 'Showing ${filtered.length} model(s)',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            'Failed to load model popularity.',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    )
                  : filtered.isEmpty
                  ? const Center(
                      child: Text('No models match the current filters.'),
                    )
                  : Column(
                      children: [
                        Expanded(
                          child: ListView.separated(
                            itemCount: visibleModels.length,
                            separatorBuilder: (_, int index) =>
                                const SizedBox(height: 8),
                            itemBuilder: (context, index) {
                              final entry = visibleModels[index];
                              final model = entry.model;
                              final alreadyAdded =
                                  existing.contains(model.filename) ||
                                  existing.contains(model.url);

                              return Container(
                                decoration: BoxDecoration(
                                  color: Theme.of(context).colorScheme.surface,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .outlineVariant
                                        .withValues(alpha: 0.45),
                                  ),
                                ),
                                child: ListTile(
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 8,
                                  ),
                                  title: Text(
                                    model.name,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  subtitle: Padding(
                                    padding: const EdgeInsets.only(top: 6),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(_formatModelMetadata(entry)),
                                        Text(
                                          entry.hasLiveStats
                                              ? '${_formatCompact(entry.downloads)} downloads • ${entry.likes} likes • ${entry.repositoryId}'
                                              : 'Popularity unavailable • ${entry.repositoryId}',
                                          style: Theme.of(context)
                                              .textTheme
                                              .bodySmall
                                              ?.copyWith(
                                                color: Theme.of(
                                                  context,
                                                ).colorScheme.onSurfaceVariant,
                                              ),
                                        ),
                                        const SizedBox(height: 6),
                                        Wrap(
                                          spacing: 6,
                                          runSpacing: 6,
                                          children: [
                                            if (model.supportsVisionFor(
                                              web: kIsWeb,
                                            ))
                                              const _CapabilityPill(
                                                label: 'Vision',
                                              ),
                                            if (model.supportsAudioFor(
                                              web: kIsWeb,
                                            ))
                                              const _CapabilityPill(
                                                label: 'Audio',
                                              ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                  trailing: alreadyAdded
                                      ? const Icon(
                                          Icons.check_circle_outline_rounded,
                                          color: Colors.green,
                                        )
                                      : FilledButton.tonal(
                                          onPressed: () {
                                            Navigator.of(context).pop(entry);
                                          },
                                          child: const Text('Add'),
                                        ),
                                ),
                              );
                            },
                          ),
                        ),
                        if (hasMore) ...[
                          const SizedBox(height: 10),
                          Align(
                            alignment: Alignment.center,
                            child: FilledButton.tonalIcon(
                              onPressed: () {
                                setState(() {
                                  _visibleCount = math.min(
                                    _visibleCount + _pageSize,
                                    filtered.length,
                                  );
                                });
                              },
                              icon: const Icon(Icons.expand_more_rounded),
                              label: Text(
                                'Load more (${filtered.length - visibleCount} left)',
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CapabilityPill extends StatelessWidget {
  final String label;

  const _CapabilityPill({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          color: Theme.of(context).colorScheme.onPrimaryContainer,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _LabeledSlider extends StatelessWidget {
  final String label;
  final String valueLabel;
  final double min;
  final double max;
  final int? divisions;
  final double value;
  final ValueChanged<double>? onChanged;

  const _LabeledSlider({
    required this.label,
    required this.valueLabel,
    required this.min,
    required this.max,
    required this.value,
    required this.onChanged,
    this.divisions,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            Text(
              valueLabel,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        Slider(
          min: min,
          max: max,
          divisions: divisions,
          value: value.clamp(min, max),
          onChanged: onChanged,
        ),
      ],
    );
  }
}
