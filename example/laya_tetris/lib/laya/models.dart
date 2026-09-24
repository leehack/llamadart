import 'package:llamadart/llamadart.dart';

import '../players.dart';

/// Hugging Face repository with the Laya GGUF backbones and the base head.
const String layaRepoId = 'fr0stbit3/laya-gguf';

/// Pinned revision of [layaRepoId].
const String layaRevision = 'ce2afdc0a8766af56a29a22dcf4a781e1f5c7d3c';

/// File name of the published base head.
const String baseHeadFile = 'laya-head.safetensors';

/// Hugging Face repository with the Tetris-tuned head.
const String tunedHeadRepoId = 'leehack/laya-tetris-head';

/// Pinned revision of [tunedHeadRepoId].
const String tunedHeadRevision = '465546a595ee2e8e3b212b8cb16829205d5dfab6';

/// File name of the Tetris-tuned head.
const String tunedHeadFile = 'laya-head-tetris.safetensors';

/// A file of [layaRepoId] at [layaRevision].
ModelSource layaSource(String filePath) => ModelSource.huggingFace(
  repoId: layaRepoId,
  revision: layaRevision,
  filePath: filePath,
);

/// The published Tetris-tuned head: [tunedHeadFile] of [tunedHeadRepoId] at
/// [tunedHeadRevision].
final ModelSource publishedTunedHead = ModelSource.huggingFace(
  repoId: tunedHeadRepoId,
  revision: tunedHeadRevision,
  filePath: tunedHeadFile,
);

/// Published Laya backbones.
enum LayaBackbone {
  /// Faster on CPU; can change decisions compared with Laya.
  q8('laya-Q8_0.gguf', 'Q8_0, 421 MB'),

  /// Twice the size of [q8]. A local F16 conversion measured closer to Laya
  /// than Q8_0; this published file has not been measured.
  f16('laya-F16.gguf', 'F16, 791 MB');

  const LayaBackbone(this.fileName, this.label);

  /// File name in [layaRepoId].
  final String fileName;

  /// Display name with the download size.
  final String label;
}

/// Model files and runtime settings for [LayaModels.load].
class LayaSetup {
  /// Creates a setup.
  const LayaSetup({
    required this.backbone,
    required this.head,
    this.tunedHead,
    this.backend = GpuBackend.auto,
    this.threads = 4,
  });

  /// The backbone GGUF.
  final ModelSource backbone;

  /// The base head.
  final ModelSource head;

  /// The Tetris-tuned head, or null to load only [head].
  final ModelSource? tunedHead;

  /// [GpuBackend.auto] for the best available device, or [GpuBackend.cpu].
  final GpuBackend backend;

  /// CPU threads of the encoder and the head.
  final int threads;

  /// Engine parameters: a 512-token context, as the decision path needs no
  /// larger one, and [threads] as the batch threads that decisions use.
  ModelParams get modelParams => ModelParams(
    contextSize: 512,
    preferredBackend: backend,
    gpuLayers: backend == GpuBackend.cpu ? 0 : ModelParams.maxGpuLayers,
    numberOfThreads: threads,
    numberOfThreadsBatch: threads,
  );
}

/// Reports load progress: a message and, while downloading, a fraction.
typedef LayaLoadStatus = void Function(String message, double? fraction);

/// Loads the models of a [LayaSetup], like [LayaModels.load].
typedef LayaLoader =
    Future<LayaModels> Function(
      LayaSetup setup, {
      ModelDownloadManager? downloads,
      ModelDownloadCancelToken? cancelToken,
      LayaLoadStatus? onStatus,
    });

/// Loaded heads that answer through one backbone.
class LayaModels {
  /// Wraps loaded heads; [onDispose] frees them.
  LayaModels({
    required this.base,
    this.tuned,
    this.tunedError,
    required this.backendName,
    required this.deviceName,
    required this.loadMillis,
    required Future<void> Function() onDispose,
  }) : _onDispose = onDispose;

  /// Asks the base head.
  final LayaDecide base;

  /// Asks the Tetris-tuned head, when it was requested and loaded.
  final LayaDecide? tuned;

  /// Why the requested tuned head did not load.
  final String? tunedError;

  /// Runtime backend of the backbone, such as `Metal` or `CPU`.
  final String backendName;

  /// Device the decisions run on, such as `MTL0`.
  final String deviceName;

  /// Wall time of the load, including downloads.
  final int loadMillis;

  final Future<void> Function() _onDispose;

  /// Both heads, for the players.
  LayaHeads get heads => LayaHeads(base: base, tuned: tuned);

  /// Downloads missing files through [downloads], then loads the backbone of
  /// [setup] into one [LlamaEngine] and each head as a [DecisionEngine] on it.
  /// A backend that loads URLs, such as the WebGPU bridge, fetches the files
  /// itself.
  ///
  /// A tuned head that fails to download or load is reported in [tunedError]
  /// and leaves [tuned] null; every other failure disposes the engine and
  /// throws.
  static Future<LayaModels> load(
    LayaSetup setup, {
    ModelDownloadManager? downloads,
    ModelDownloadCancelToken? cancelToken,
    LayaLoadStatus? onStatus,
  }) async {
    final sw = Stopwatch()..start();
    final engine = LlamaEngine(LlamaBackend(), modelDownloadManager: downloads);
    // URL-loading backends reject a cancel token.
    final options = engine.backend.supportsUrlLoading
        ? ModelLoadOptions.defaults
        : ModelLoadOptions(cancelToken: cancelToken);
    void Function(ModelDownloadProgress) progressOf(ModelSource source) => (p) {
      final fraction = p.fraction;
      final amount = p.totalBytes == null && fraction != null
          ? '${(fraction * 100).round()}%'
          : '${_mb(p.receivedBytes)}'
                '${p.totalBytes == null ? '' : ' of ${_mb(p.totalBytes!)}'} MB';
      onStatus?.call('Downloading ${source.fileName}: $amount', fraction);
    };

    Future<DecisionEngine> loadHead(
      LlamaEngine engine,
      ModelSource source,
    ) async {
      onStatus?.call('Loading ${source.fileName}', null);
      final url = source.resolvedUri;
      if (url != null && engine.backend.supportsUrlLoading) {
        return DecisionEngine.load(engine, headPath: '$url');
      }
      final entry = await engine.modelDownloadManager.ensureModel(
        source,
        options: options,
        onProgress: progressOf(source),
      );
      onStatus?.call('Loading ${source.fileName}', null);
      return DecisionEngine.load(engine, headPath: entry.filePath);
    }

    final heads = <DecisionEngine>[];
    Future<void> disposeAll() async {
      for (final head in heads.reversed) {
        await head.dispose();
      }
      await engine.dispose();
    }

    try {
      onStatus?.call('Loading ${setup.backbone.fileName}', null);
      await engine.loadModelSource(
        setup.backbone,
        modelParams: setup.modelParams,
        options: options,
        onProgress: progressOf(setup.backbone),
      );
      final capabilities = await DecisionEngine.capabilitiesFor(engine);
      if (!capabilities.isSupported) {
        throw LlamaUnsupportedException(capabilities.unsupportedReason!);
      }
      final base = await loadHead(engine, setup.head);
      heads.add(base);
      DecisionEngine? tuned;
      String? tunedError;
      final tunedSource = setup.tunedHead;
      if (tunedSource != null) {
        try {
          tuned = await loadHead(engine, tunedSource);
          heads.add(tuned);
        } on Exception catch (e) {
          tunedError = '$e';
        }
      }
      return LayaModels(
        base: base.systemOneBatch,
        tuned: tuned?.systemOneBatch,
        tunedError: tunedError,
        backendName: await engine.getBackendName(),
        deviceName: base.info.deviceName,
        loadMillis: sw.elapsedMilliseconds,
        onDispose: disposeAll,
      );
    } catch (_) {
      await disposeAll();
      rethrow;
    }
  }

  /// Frees the heads, then the engine.
  Future<void> dispose() => _onDispose();

  static String _mb(int bytes) => (bytes / 1e6).toStringAsFixed(0);
}
