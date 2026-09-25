import 'package:llamadart/llamadart.dart';

import 'intents.dart';
import 'sources.dart';

/// Hugging Face repository with the Laya GGUF backbones and the base head.
const String layaRepoId = 'fr0stbit3/laya-gguf';

/// Pinned revision of [layaRepoId].
const String layaRevision = 'ce2afdc0a8766af56a29a22dcf4a781e1f5c7d3c';

/// A file of [layaRepoId] at [layaRevision].
ModelSource layaSource(String filePath) => ModelSource.huggingFace(
  repoId: layaRepoId,
  revision: layaRevision,
  filePath: filePath,
);

/// The default backbone, 421 MB.
final ModelSource defaultBackbone = layaSource('laya-Q8_0.gguf');

/// The base head, 106 MB.
final ModelSource defaultHead = layaSource('laya-head.safetensors');

/// Hugging Face repository with the command-tuned head.
const String commandHeadRepoId = 'leehack/laya-command-head';

/// Pinned revision of [commandHeadRepoId].
const String commandHeadRevision = '770c4c21e2185e44bf40075ee22989adc28a3771';

/// File name of the command-tuned head.
const String commandHeadFile = 'laya-head-commands.safetensors';

/// The published command-tuned head, 106 MB.
final ModelSource publishedCommandHead = ModelSource.huggingFace(
  repoId: commandHeadRepoId,
  revision: commandHeadRevision,
  filePath: commandHeadFile,
);

/// A loaded backbone and head.
class Laya {
  Laya._(this._engine, this.decisions, this.backendName);

  final LlamaEngine _engine;

  /// The head on the backbone.
  final DecisionEngine decisions;

  /// Runtime backend of the backbone, such as `Metal` or `CPU`.
  final String backendName;

  /// Device the decisions run on, such as `MTL0` or `CPU`.
  String get deviceName => decisions.info.deviceName;

  /// Reads intents with [decisions].
  IntentReader get reader => layaIntentReader(decisions);

  /// Downloads missing files through [downloads] (the engine's own manager
  /// when null), loads [backbone] with a 512-token context, loads [head] on
  /// it, and runs one decision so the first typed text does not pay for
  /// GPU pipeline setup. [cpu] keeps everything on the CPU.
  static Future<Laya> load({
    ModelSource? backbone,
    ModelSource? head,
    ModelDownloadManager? downloads,
    bool cpu = false,
    LoadStatus? onStatus,
  }) async {
    backbone ??= defaultBackbone;
    head ??= defaultHead;
    void Function(ModelDownloadProgress) progressOf(ModelSource source) =>
        (p) => onStatus?.call(
          'Downloading ${source.fileName}: ${_mb(p.receivedBytes)}'
          '${p.totalBytes == null ? '' : ' of ${_mb(p.totalBytes!)}'} MB',
          p.fraction,
        );

    final engine = LlamaEngine(LlamaBackend(), modelDownloadManager: downloads);
    DecisionEngine? decisions;
    try {
      onStatus?.call('Loading ${backbone.fileName}', null);
      await engine.loadModelSource(
        backbone,
        modelParams: ModelParams(
          contextSize: 512,
          preferredBackend: cpu ? GpuBackend.cpu : GpuBackend.auto,
          gpuLayers: cpu ? 0 : ModelParams.maxGpuLayers,
        ),
        onProgress: progressOf(backbone),
      );
      final capabilities = await DecisionEngine.capabilitiesFor(engine);
      if (!capabilities.isSupported) {
        throw LlamaUnsupportedException(capabilities.unsupportedReason!);
      }
      onStatus?.call('Loading ${head.fileName}', null);
      final headFile = await engine.modelDownloadManager.ensureModel(
        head,
        onProgress: progressOf(head),
      );
      onStatus?.call('Loading ${head.fileName}', null);
      decisions = await DecisionEngine.load(
        engine,
        headPath: headFile.filePath,
      );
      onStatus?.call('Warming up', null);
      await layaIntentReader(decisions)('remind me to call mom at 7');
      return Laya._(engine, decisions, await engine.getBackendName());
    } catch (_) {
      await decisions?.dispose();
      await engine.dispose();
      rethrow;
    }
  }

  /// Frees the head, then the engine.
  Future<void> dispose() async {
    await decisions.dispose();
    await _engine.dispose();
  }

  static String _mb(int bytes) => (bytes / 1e6).toStringAsFixed(0);
}

/// Default gate for readings of the command-tuned head.
const double layaEnter = 0.3;

/// Words a text needs before a Laya reading can change the bar: the tuned
/// head reads one-word fragments such as `rem` as settings.
const int layaMinWords = 2;

/// Loads Laya like [Laya.load], as an [IntentSource].
Future<IntentSource> loadLayaSource({
  ModelSource? head,
  ModelDownloadManager? downloads,
  bool cpu = false,
  LoadStatus? onStatus,
}) async {
  final laya = await Laya.load(
    head: head,
    downloads: downloads,
    cpu: cpu,
    onStatus: onStatus,
  );
  return IntentSource(
    reader: laya.reader,
    enter: layaEnter,
    label: '${laya.backendName} · ${laya.deviceName}',
    minWords: layaMinWords,
    dispose: laya.dispose,
  );
}
