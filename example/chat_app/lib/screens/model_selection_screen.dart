import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/chat_provider.dart';
import '../models/downloadable_model.dart';
import '../widgets/model_card.dart';
import '../services/model_service.dart';

class ModelSelectionScreen extends StatefulWidget {
  const ModelSelectionScreen({super.key});

  @override
  State<ModelSelectionScreen> createState() => _ModelSelectionScreenState();
}

class _ModelSelectionScreenState extends State<ModelSelectionScreen> {
  final ModelService _modelService = ModelService();
  final List<DownloadableModel> _models = DownloadableModel.defaultModels;

  final Map<String, double> _downloadProgress = {};
  final Map<String, bool> _isDownloading = {};
  Set<String> _downloadedFiles = {};
  String? _modelsDir;

  @override
  void initState() {
    super.initState();
    if (!kIsWeb) {
      _initModelService();
    }
  }

  Future<void> _initModelService() async {
    _modelsDir = await _modelService.getModelsDirectory();
    _downloadedFiles = await _modelService.getDownloadedModels(_models);
    if (mounted) setState(() {});
  }

  Future<void> _downloadModel(DownloadableModel model) async {
    if (_modelsDir == null) return;

    setState(() {
      _isDownloading[model.filename] = true;
      _downloadProgress[model.filename] = 0.0;
    });

    await _modelService.downloadModel(
      model: model,
      modelsDir: _modelsDir!,
      onProgress: (p) => setState(() => _downloadProgress[model.filename] = p),
      onSuccess: (filename) {
        setState(() {
          _downloadedFiles.add(filename);
          _isDownloading[model.filename] = false;
          _downloadProgress.remove(model.filename);
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('${model.name} downloaded successfully!')),
          );
        }
      },
      onError: (e) {
        setState(() {
          _isDownloading[model.filename] = false;
          _downloadProgress.remove(model.filename);
        });
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Download failed: $e')));
        }
      },
    );
  }

  void _selectModel(String pathOrUrl) {
    context.read<ChatProvider>().updateModelPath(pathOrUrl);
    context.read<ChatProvider>().loadModel();
    Navigator.of(context).pop();
  }

  Future<void> _deleteModel(String filename) async {
    if (_modelsDir == null) return;
    await _modelService.deleteModel(_modelsDir!, filename);
    setState(() => _downloadedFiles.remove(filename));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Select Model'), centerTitle: true),
      body: ListView.separated(
        itemCount: _models.length,
        separatorBuilder: (_, _) => const SizedBox(height: 16),
        padding: const EdgeInsets.all(24),
        itemBuilder: (context, index) {
          final model = _models[index];
          return ModelCard(
            model: model,
            isDownloaded: _downloadedFiles.contains(model.filename),
            isDownloading: _isDownloading[model.filename] ?? false,
            progress: _downloadProgress[model.filename] ?? 0.0,
            isWeb: kIsWeb,
            onSelect: () => _selectModel(
              kIsWeb ? model.url : '${_modelsDir!}/${model.filename}',
            ),
            onDownload: () => _downloadModel(model),
            onDelete: () => _deleteModel(model.filename),
          );
        },
      ),
    );
  }
}
