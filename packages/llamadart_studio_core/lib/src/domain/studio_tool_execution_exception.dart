import 'package:llamadart/llamadart.dart';

/// A tool-reported failure whose original payload must reach the transcript.
///
/// MCP adapters throw this only for a returned MCP error. Ordinary custom tool
/// maps, including maps with an `isError` key, remain ordinary results.
class StudioToolExecutionException extends LlamaException {
  /// Creates a failure retaining the exact returned [result] map.
  StudioToolExecutionException(this.result) : super('Tool execution failed.');

  /// Original result, preserved in invocation JSON and model-facing history.
  final Map<String, Object?> result;
}
