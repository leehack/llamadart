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
import '../services/model_service_base.dart';
import '../utils/backend_utils.dart';
import '../widgets/model_card.dart';
import '../widgets/tool_declarations_dialog.dart';

class ManageModelsScreen extends StatefulWidget {
  final VoidCallback? onModelActivated;
  final bool embeddedPanel;

  // Test hooks for exercising download-controller wiring without relying on
  // platform storage or the full built-in model catalog.
  final ModelService? modelService;
  final List<DownloadableModel>? initialModels;
  final bool? showModelLibraryInitially;

  const ManageModelsScreen({
    super.key,
    this.onModelActivated,
    this.embeddedPanel = false,
    this.modelService,
    this.initialModels,
    this.showModelLibraryInitially,
  });

  @override
  State<ManageModelsScreen> createState() => _ManageModelsScreenState();
}

class _ManageModelsScreenState extends State<ManageModelsScreen>
    with WidgetsBindingObserver {
  static const String _customModelsPrefsKey = 'custom_hf_models_v1';
  static const int _webLargeModelWarningBytes = 1900 * 1024 * 1024;

  late final ModelService _modelService;
  final HuggingFaceModelDiscoveryService _hfDiscoveryService =
      HuggingFaceModelDiscoveryService();
  final List<DownloadableModel> _models = <DownloadableModel>[];
  final List<DownloadableModel> _customModels = <DownloadableModel>[];

  final Map<String, ValueNotifier<_ModelDownloadUiState>>
  _downloadUiStateByFile = {};
  final Map<String, int> _lastDownloadedBytes = {};
  final Map<String, DateTime> _lastDownloadSampleAt = {};
  final Map<String, double> _smoothedDownloadRateBytesPerSec = {};
  final Map<String, ModelDownloadController> _downloadControllers = {};
  final Map<String, StreamSubscription<ModelDownloadTaskSnapshot>>
  _downloadSubscriptions = {};

  Set<String> _downloadedFiles = {};
  String? _modelsDir;
  String? _activatingModel;
  bool _showModelLibrary = true;
  bool _modelParametersExpanded = false;
  bool _inferenceParametersExpanded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _modelService = widget.modelService ?? ModelService();
    _models.addAll(_initialModelCatalog());
    _showModelLibrary = widget.showModelLibraryInitially ?? false;
    _initModelService();
  }

  List<DownloadableModel> _initialModelCatalog() {
    return List<DownloadableModel>.from(
      widget.initialModels ?? DownloadableModel.defaultModels,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (kIsWeb) {
      return;
    }

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      _pauseActiveDownloads();
    }
  }

  Future<void> _initModelService() async {
    await _loadCustomModels();
    _modelsDir = await _modelService.getModelsDirectory();
    _downloadedFiles = await _modelService.getDownloadedModels(_models);
    if (mounted) {
      setState(() {});
    }
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

    _downloadedFiles = await _modelService.getDownloadedModels(_models);
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

  String _downloadStageLabel(ModelDownloadProgress detail) {
    final actionText = detail.resumed
        ? (kIsWeb ? 'Resuming cache' : 'Resuming')
        : (kIsWeb ? 'Caching' : 'Downloading');
    final stageText = switch (detail.stage) {
      ModelDownloadStage.model => '$actionText model',
      ModelDownloadStage.multimodalProjector => '$actionText mmproj',
    };

    if (detail.stageCount > 1) {
      return '$stageText (${detail.stageIndex}/${detail.stageCount})';
    }
    return stageText;
  }

  String? _downloadTaskLabel(ModelDownloadTaskSnapshot? task) {
    if (task == null) {
      return null;
    }
    return switch (task.stage) {
      ModelDownloadTaskStage.idle => null,
      ModelDownloadTaskStage.resolving => 'Resolving model',
      ModelDownloadTaskStage.checkingCache => 'Checking cache',
      ModelDownloadTaskStage.downloading =>
        kIsWeb ? 'Caching model' : 'Downloading model',
      ModelDownloadTaskStage.verifying => 'Verifying model',
      ModelDownloadTaskStage.ready => 'Ready',
      ModelDownloadTaskStage.failed => task.errorMessage ?? 'Download failed',
      ModelDownloadTaskStage.cancelled => 'Paused',
    };
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

  void _updateDownloadRate(String filename, ModelDownloadProgress detail) {
    final now = DateTime.now();
    final previousBytes = _lastDownloadedBytes[filename];
    final previousSampleAt = _lastDownloadSampleAt[filename];

    if (previousBytes != null && previousSampleAt != null) {
      final elapsedMs = now.difference(previousSampleAt).inMilliseconds;
      final deltaBytes = detail.downloadedBytes - previousBytes;
      if (elapsedMs > 0 && deltaBytes > 0) {
        final instantRate = (deltaBytes * 1000.0) / elapsedMs;
        final previousRate = _smoothedDownloadRateBytesPerSec[filename];
        _smoothedDownloadRateBytesPerSec[filename] = previousRate == null
            ? instantRate
            : ((previousRate * 0.72) + (instantRate * 0.28));
      }
    }

    _lastDownloadedBytes[filename] = detail.downloadedBytes;
    _lastDownloadSampleAt[filename] = now;
  }

  String? _downloadTransferLabel(
    String filename,
    ModelDownloadProgress detail,
  ) {
    final bytesPerSecond = _smoothedDownloadRateBytesPerSec[filename];
    if (bytesPerSecond == null || bytesPerSecond <= 0) {
      return null;
    }

    final speedLabel = _formatByteRate(bytesPerSecond);
    final totalBytes = detail.totalBytes;
    if (totalBytes == null || totalBytes <= 0) {
      return speedLabel;
    }

    final remainingBytes = totalBytes - detail.downloadedBytes;
    if (remainingBytes <= 0) {
      return speedLabel;
    }

    final etaSeconds = (remainingBytes / bytesPerSecond).ceil();
    final etaLabel = _formatEta(Duration(seconds: etaSeconds));
    return '$speedLabel | $etaLabel left';
  }

  String _formatByteRate(double bytesPerSecond) {
    if (bytesPerSecond >= 1024 * 1024 * 1024) {
      return '${(bytesPerSecond / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB/s';
    }
    if (bytesPerSecond >= 1024 * 1024) {
      return '${(bytesPerSecond / (1024 * 1024)).toStringAsFixed(2)} MB/s';
    }
    if (bytesPerSecond >= 1024) {
      return '${(bytesPerSecond / 1024).toStringAsFixed(1)} KB/s';
    }
    return '${bytesPerSecond.toStringAsFixed(0)} B/s';
  }

  String _formatEta(Duration duration) {
    if (duration.inHours > 0) {
      final minutes = duration.inMinutes
          .remainder(60)
          .toString()
          .padLeft(2, '0');
      return '${duration.inHours}h ${minutes}m';
    }
    if (duration.inMinutes > 0) {
      final seconds = duration.inSeconds
          .remainder(60)
          .toString()
          .padLeft(2, '0');
      return '${duration.inMinutes}m ${seconds}s';
    }
    return '${duration.inSeconds}s';
  }

  ValueNotifier<_ModelDownloadUiState> _downloadUiStateFor(String filename) {
    return _downloadUiStateByFile.putIfAbsent(
      filename,
      () => ValueNotifier<_ModelDownloadUiState>(const _ModelDownloadUiState()),
    );
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
    final notifier = _downloadUiStateFor(filename);
    final current = notifier.value;
    notifier.value = current.copyWith(
      isDownloading: isDownloading,
      progress: clearProgress ? 0.0 : progress,
      detail: detail,
      task: task,
      clearDetail: clearDetail,
      clearTask: clearTask,
    );
  }

  void _clearDownloadTracking(String filename) {
    _lastDownloadedBytes.remove(filename);
    _lastDownloadSampleAt.remove(filename);
    _smoothedDownloadRateBytesPerSec.remove(filename);
  }

  void _pauseActiveDownloads() {
    for (final controller in _downloadControllers.values) {
      if (controller.snapshot.isRunning) {
        controller.cancel();
      }
    }
  }

  Future<void> _disposeDownloadController(
    String filename, {
    ModelDownloadController? controller,
    StreamSubscription<ModelDownloadTaskSnapshot>? subscription,
  }) async {
    final currentSubscription = _downloadSubscriptions[filename];
    if (subscription == null || identical(currentSubscription, subscription)) {
      await _downloadSubscriptions.remove(filename)?.cancel();
    } else {
      await subscription.cancel();
    }

    final currentController = _downloadControllers[filename];
    if (controller == null || identical(currentController, controller)) {
      await _downloadControllers.remove(filename)?.dispose();
    } else {
      await controller.dispose();
    }
  }

  void _handleDownloadSnapshot(
    DownloadableModel model,
    ModelDownloadTaskSnapshot snapshot,
  ) {
    if (!mounted) {
      return;
    }
    _updateDownloadUiState(
      model.filename,
      isDownloading: snapshot.isRunning,
      progress: snapshot.fraction,
      task: snapshot,
    );
  }

  Future<void> _downloadModel(DownloadableModel model) async {
    if (!kIsWeb && _modelsDir == null) {
      return;
    }
    if (_downloadControllers[model.filename]?.snapshot.isRunning ?? false) {
      return;
    }

    await _disposeDownloadController(model.filename);

    ModelDownloadController? controller;
    StreamSubscription<ModelDownloadTaskSnapshot>? subscription;

    _updateDownloadUiState(
      model.filename,
      isDownloading: true,
      clearDetail: true,
      clearTask: true,
      clearProgress: true,
    );
    _clearDownloadTracking(model.filename);

    try {
      final manager = ChatAppModelDownloadManager(
        modelService: _modelService,
        model: model,
        modelsDir: _modelsDir ?? '',
        onProgressDetail: (detail) {
          if (!mounted) {
            return;
          }
          _updateDownloadRate(model.filename, detail);
          _updateDownloadUiState(
            model.filename,
            progress: detail.overallProgress,
            detail: detail,
          );
        },
      );
      controller = ModelDownloadController(manager: manager);
      _downloadControllers[model.filename] = controller;
      subscription = controller.snapshots.listen(
        (snapshot) => _handleDownloadSnapshot(model, snapshot),
      );
      _downloadSubscriptions[model.filename] = subscription;

      await controller.start(manager.source);
      if (!mounted) {
        return;
      }
      _updateDownloadUiState(
        model.filename,
        isDownloading: false,
        clearProgress: true,
        clearDetail: true,
        clearTask: true,
      );
      _clearDownloadTracking(model.filename);
      setState(() {
        _downloadedFiles.add(model.filename);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${model.name} downloaded successfully.')),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
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
      await _disposeDownloadController(
        model.filename,
        controller: controller,
        subscription: subscription,
      );
    }
  }

  void _cancelDownload(DownloadableModel model) {
    _downloadControllers[model.filename]?.cancel();
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

    if (model.isMultimodal) {
      final mmprojPath = _resolveMmprojPathForModel(model);
      provider.updateMmprojPath(mmprojPath ?? '');
    } else {
      provider.updateMmprojPath('');
    }

    if (kIsWeb && model.sizeBytes >= _webLargeModelWarningBytes) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          duration: Duration(seconds: 4),
          content: Text(
            'Large web model selected. Download/cache can complete, but browser memory limits may still block loading.',
          ),
        ),
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${model.name} loaded successfully.')),
      );
      widget.onModelActivated?.call();
    }
  }

  Future<void> _deleteModel(DownloadableModel model) async {
    if (_modelsDir == null) return;

    if (_downloadUiStateFor(model.filename).value.isDownloading) {
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

    setState(() {
      _downloadedFiles.remove(model.filename);
    });
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

    final snapshot = List<DownloadableModel>.from(_models);
    for (final model in snapshot) {
      await _modelService.deleteModel(_modelsDir ?? '', model);
    }

    _models
      ..clear()
      ..addAll(_initialModelCatalog());
    _customModels.clear();
    for (final notifier in _downloadUiStateByFile.values) {
      notifier.dispose();
    }
    _downloadUiStateByFile.clear();
    _lastDownloadedBytes.clear();
    _lastDownloadSampleAt.clear();
    _smoothedDownloadRateBytesPerSec.clear();
    for (final subscription in _downloadSubscriptions.values) {
      await subscription.cancel();
    }
    _downloadSubscriptions.clear();
    for (final controller in _downloadControllers.values) {
      await controller.dispose();
    }
    _downloadControllers.clear();
    _downloadedFiles = await _modelService.getDownloadedModels(_models);

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
    return _resolveAssetLoadReference(model.modelSource);
  }

  bool _hasUnsupportedWebAsset(DownloadableModel model) {
    if (model.modelSource is LocalModelAssetSource) {
      return true;
    }
    return model.multimodalProjectorSource is LocalModelAssetSource;
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
    if (!model.isMultimodal) {
      return null;
    }

    final source = model.multimodalProjectorSource;
    if (source != null) {
      return _resolveAssetLoadReference(source);
    }

    return model.supportsVision || model.supportsAudio
        ? _resolveModelLoadReference(model)
        : null;
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
        final selectedModelMmprojPath = selectedModel == null
            ? null
            : _resolveMmprojPathForModel(selectedModel);
        final selectedBackend = _resolveSelectedBackend(provider);
        final contextOptions = _buildContextSizeOptions(provider.contextSize);
        final hasModelPath =
            provider.modelPath != null && provider.modelPath!.isNotEmpty;
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
        final isAutoGpuLayers = provider.gpuLayers >= 99;
        final gpuLayersLabel = isAutoGpuLayers
            ? 'Auto'
            : provider.gpuLayers.toString();
        final gpuLayersSliderValue = isAutoGpuLayers
            ? 99.0
            : provider.gpuLayers.clamp(0, 98).toDouble();
        final hasLoadProgress =
            provider.loadingProgress > 0 && provider.loadingProgress < 1;
        final loadProgressLabel = hasLoadProgress
            ? '${(provider.loadingProgress * 100).toStringAsFixed(0)}%'
            : null;

        return ListView(
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
                    const SizedBox(height: 8),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size.fromHeight(44),
                            alignment: Alignment.centerLeft,
                          ),
                          onPressed: _showDiscoverPopularModelsDialog,
                          icon: const Icon(Icons.auto_awesome_rounded),
                          label: const Text('Discover popular'),
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size.fromHeight(44),
                            alignment: Alignment.centerLeft,
                          ),
                          onPressed: _showAddHuggingFaceDialog,
                          icon: const Icon(Icons.add_link_rounded),
                          label: const Text('Add GGUF (HF)'),
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          style: OutlinedButton.styleFrom(
                            minimumSize: const Size.fromHeight(44),
                            alignment: Alignment.centerLeft,
                          ),
                          onPressed: _removeAllModels,
                          icon: const Icon(Icons.delete_sweep_outlined),
                          label: const Text('Remove all'),
                        ),
                      ],
                    ),
                    if (!kIsWeb && _modelsDir == null)
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 40),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else
                      ..._models.map((model) {
                        final selectedPath = _resolveModelLoadReference(model);
                        final isActivating = _activatingModel == model.filename;
                        final downloadStateListenable = _downloadUiStateFor(
                          model.filename,
                        );

                        return ValueListenableBuilder<_ModelDownloadUiState>(
                          valueListenable: downloadStateListenable,
                          builder: (context, downloadState, _) {
                            final detail = downloadState.detail;
                            final taskLabel = _downloadTaskLabel(
                              downloadState.task,
                            );

                            final card = ModelCard(
                              model: model,
                              isDownloaded: _downloadedFiles.contains(
                                model.filename,
                              ),
                              isDownloading: downloadState.isDownloading,
                              progress: downloadState.progress,
                              downloadStatusLabel: detail == null
                                  ? taskLabel
                                  : _downloadStageLabel(detail),
                              downloadTransferLabel: detail == null
                                  ? null
                                  : _downloadTransferLabel(
                                      model.filename,
                                      detail,
                                    ),
                              isWeb: kIsWeb,
                              isSelected: provider.modelPath == selectedPath,
                              gpuLayers: provider.gpuLayers,
                              contextSize: provider.contextSize,
                              onGpuLayersChanged: provider.updateGpuLayers,
                              onContextSizeChanged: provider.updateContextSize,
                              onSelect: isActivating
                                  ? () {}
                                  : () => unawaited(_selectModel(model)),
                              onDownload: () =>
                                  unawaited(_downloadModel(model)),
                              onDelete: () => unawaited(_deleteModel(model)),
                              onCancel: () => _cancelDownload(model),
                            );

                            return Padding(
                              padding: const EdgeInsets.only(bottom: 14),
                              child: Stack(
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
                    'GPU layers, backend, context, and runtime threads',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  children: [
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
                        hasMmprojPath
                            ? 'mmproj is configured for this model. Use Text only to disable it, or Load mmproj to attach it without a full reload. '
                                  'Set GPU layers to 99 for Auto. Runtime values apply on next model load.'
                            : 'Set GPU layers to 99 for Auto. Runtime values apply on next model load.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
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
                      subtitle: const Text(
                        'Allow the model to emit tool calls.',
                      ),
                      contentPadding: EdgeInsets.zero,
                      onChanged: provider.updateToolsEnabled,
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
                      subtitle: const Text(
                        'Sends thinking-disable hint to template handlers.',
                      ),
                      contentPadding: EdgeInsets.zero,
                      onChanged: provider.updateThinkingEnabled,
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
                      onChanged: (value) =>
                          provider.updateThinkingBudgetTokens(value.toInt()),
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
            Text(
              'Diagnostics',
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

  List<GpuBackend> _getAvailableBackends(ChatProvider provider) {
    return BackendUtils.availableBackends(
      devices: provider.availableDevices,
      activeBackend: provider.activeBackend,
      includeAutoOnWeb: true,
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
    _pauseActiveDownloads();
    for (final subscription in _downloadSubscriptions.values) {
      unawaited(subscription.cancel());
    }
    _downloadSubscriptions.clear();
    for (final controller in _downloadControllers.values) {
      unawaited(controller.dispose());
    }
    _downloadControllers.clear();
    for (final notifier in _downloadUiStateByFile.values) {
      notifier.dispose();
    }
    _downloadUiStateByFile.clear();
    super.dispose();
  }
}

class _ModelDownloadUiState {
  final bool isDownloading;
  final double progress;
  final ModelDownloadProgress? detail;
  final ModelDownloadTaskSnapshot? task;

  const _ModelDownloadUiState({
    this.isDownloading = false,
    this.progress = 0.0,
    this.detail,
    this.task,
  });

  _ModelDownloadUiState copyWith({
    bool? isDownloading,
    double? progress,
    ModelDownloadProgress? detail,
    ModelDownloadTaskSnapshot? task,
    bool clearDetail = false,
    bool clearTask = false,
  }) {
    final normalizedProgress =
        ((progress ?? this.progress).clamp(0.0, 1.0) as num).toDouble();

    return _ModelDownloadUiState(
      isDownloading: isDownloading ?? this.isDownloading,
      progress: normalizedProgress,
      detail: clearDetail ? null : (detail ?? this.detail),
      task: clearTask ? null : (task ?? this.task),
    );
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
      details.add('${entry.model.sizeMb} MB');
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
                  icon: const Icon(Icons.refresh_rounded),
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
                              icon: const Icon(Icons.clear_rounded),
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
                                            if (model.supportsVision)
                                              const _CapabilityPill(
                                                label: 'Vision',
                                              ),
                                            if (model.supportsAudio)
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
