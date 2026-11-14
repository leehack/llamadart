import 'package:meta/meta.dart';

import '../../domain/studio_model_descriptor.dart';
import '../../ports/model_storage_port.dart';
import 'local_model_scanner_stub.dart'
    if (dart.library.io) 'local_model_scanner_io.dart'
    as impl;

/// Metadata for a single model or companion file found on local storage.
@immutable
class LocalScannedModelFile {
  /// Creates a [LocalScannedModelFile].
  const LocalScannedModelFile({
    required this.path,
    required this.filename,
    required this.sizeBytes,
    required this.modifiedAt,
  });

  /// Absolute filesystem path.
  final String path;

  /// Basename of the file.
  final String filename;

  /// File length in bytes.
  final int sizeBytes;

  /// Last-modified timestamp used to prefer newer copies on duplicate names.
  final DateTime modifiedAt;
}

/// Result of scanning local model cache and custom model directories.
@immutable
class LocalModelScanResult {
  /// Creates a [LocalModelScanResult].
  const LocalModelScanResult({
    this.curatedAssetsById = const <String, ResolvedModelAssets>{},
    this.standaloneModels = const <StudioModelDescriptor>[],
    this.allFiles = const <LocalScannedModelFile>[],
  });

  /// Curated catalog models whose primary and companion weights were found on
  /// local disk, keyed by `descriptor.id`.
  final Map<String, ResolvedModelAssets> curatedAssetsById;

  /// Additional loadable `.gguf` / `.litertlm` models found on local disk that
  /// are not already represented by [curatedAssetsById].
  final List<StudioModelDescriptor> standaloneModels;

  /// All candidate model/companion files discovered across scanned roots.
  final List<LocalScannedModelFile> allFiles;

  /// Total unique bytes across all discovered files on disk.
  int get totalUniqueBytes => allFiles.fold<int>(
    0,
    (int sum, LocalScannedModelFile file) => sum + file.sizeBytes,
  );
}

/// Cross-platform scanner that discovers existing `.gguf`, `.litertlm`, and
/// companion weights across `llamadart` caches and user-configured folders.
abstract interface class LocalModelScanner {
  /// Creates the platform-appropriate [LocalModelScanner].
  factory LocalModelScanner({List<String> defaultRoots = const <String>[]}) =>
      impl.createLocalModelScanner(defaultRoots: defaultRoots);

  /// Standard per-user `llamadart` model cache directories on desktop hosts.
  static List<String> defaultDesktopRoots() => impl.defaultDesktopModelRoots();

  /// Default local root directories scanned on every refresh.
  List<String> get defaultRoots;

  /// Scans [defaultRoots] plus [extraDirectories] and classifies loadable
  /// curated matches and standalone local models.
  Future<LocalModelScanResult> scan({
    List<String> extraDirectories = const <String>[],
  });
}
