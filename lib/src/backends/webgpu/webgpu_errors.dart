import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import '../../core/exceptions.dart';
import 'webgpu_decision.dart';

/// Preserves argument validation as a typed backend failure.
T webGpuValidateArguments<T>(T Function() call) {
  try {
    return call();
  } on ArgumentError catch (error) {
    throw LlamaArgumentException(
      webGpuBridgeErrorText(error),
      name: error.name,
      invalidValue: error.invalidValue,
    );
  }
}

// v0.1.63 serializeWorkerError keeps only message, and BridgeWorkerProxy
// reconstructs Error without name or code. Match only its validator emissions,
// never generic words such as "invalid", "argument" or "TypeError".
final RegExp _workerArgument = RegExp(
  r'^(?:CompletionOptions\.(?:presencePenalty|minP) must be a finite number|'
  r'CompletionOptions\.speculativeDecoding\.(?:draftTokenMax|draftTokenMin|'
  r'ngramSizeN|ngramSizeM|ngramMinHits|ngramMatch|ngramTokenMin|ngramTokenMax) '
  r'(?:must be an integer from |\([^)]*\) must not exceed )|'
  r'LoRA adapter scale (?:must be a finite number, got |[^ ]+ is outside the 32-bit float range\.))',
);

/// Classifies request rejections without reclassifying unknown runtime errors.
///
/// The pinned bridge exposes JS RangeError/TypeError, not stable error codes.
/// Keep this separate from operation-specific fallbacks so later bridge code
/// mappings (including EmbeddingError) can be added when their assets are pinned.
LlamaException? webGpuBridgeRequestError(
  Object error, {
  Iterable<String> sourceUrls = const <String>[],
}) {
  if (error is LlamaException) return error;
  String? name;
  try {
    final value = (error as JSObject).getProperty<JSAny?>('name'.toJS);
    if (value.isA<JSString>()) name = (value as JSString).toDart;
  } catch (_) {
    // Dart errors and primitive JS rejections have no JS error name.
  }
  final message = webGpuBridgeErrorText(error, sourceUrls: sourceUrls);
  if (name == 'RangeError' ||
      name == 'TypeError' ||
      (name == 'Error' && _workerArgument.hasMatch(message))) {
    return LlamaArgumentException(message);
  }
  return null;
}
