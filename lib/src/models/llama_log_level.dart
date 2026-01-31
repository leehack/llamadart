/// Log level for the underlying llama.cpp engine.
enum LlamaLogLevel {
  /// No logging output.
  none,

  /// Detailed debug information.
  debug,

  /// General execution information.
  info,

  /// Warnings about potential issues.
  warn,

  /// Critical error messages only.
  error,
}
