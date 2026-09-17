import 'package:llamadart_validation/llamadart_validation.dart';

import 'host_native.dart'
    if (dart.library.js_interop) 'host_web.dart'
    as platform;

/// Platform storage and model preparation for the shared validation runner.
abstract interface class ValidationHost {
  /// Prepares and verifies the locked model before inference.
  Future<({String path, Map<String, dynamic> evidence})> prepare(
    ValidationProfile profile,
  );

  /// Cancels an in-progress download.
  void cancelPreparation();

  /// Opens a unique incremental result journal.
  Future<void> start(String runId);

  /// Persists a complete event and crash-recovery breadcrumb.
  Future<void> emit(Map<String, dynamic> event);

  /// Closes the journal and derives reports from it.
  Future<ValidationReport> finish();

  /// Exports one report to device storage or a browser download.
  Future<void> export(String name, String text);

  /// Describes where the host keeps result files.
  String get outputLocation;
}

/// Selects native filesystem or browser storage without importing IO on Web.
ValidationHost createValidationHost() => platform.createHost();
