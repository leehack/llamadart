// coverage:ignore-file

/// Web-safe placeholder for the native-only LiteRT-LM backend.
class LiteRtLmBackend {
  /// Creates a placeholder backend on platforms without `dart:ffi`.
  LiteRtLmBackend() {
    throw UnsupportedError('LiteRT-LM backend requires a native platform.');
  }
}
