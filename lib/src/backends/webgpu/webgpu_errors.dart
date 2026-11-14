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

// Only the pinned bridge's TypeError/RangeError validator messages establish
// argument provenance. Worker transport can erase their names; direct runtime
// failures can share those names. Keep both paths on the same allowlist.
// Source emissions and routing: doc/webgpu_bridge.md, "Request errors".
final RegExp _bridgeArgument = RegExp(
  r'^(?:CompletionOptions\.(?:presencePenalty|minP) must be a finite number|'
  r'CompletionOptions\.thinkingBudget(?: must be an object\.|'
  r'\.(?:startTag|endTag) must be a non-empty string\.|'
  r'\.forcedMessage must be a string\.|'
  r'\.maxTokens must be an integer from )|'
  r'CompletionOptions\.(?:grammar(?:Root)? contains U\+0000, which the core cannot read\.|'
  r'grammarRoot must be a non-empty string\.|'
  r'grammarLazy must be a boolean;|'
  r'(?:grammarLazy|grammarRoot) needs a non-empty CompletionOptions\.grammar\.|'
  r'grammarLazy needs at least one CompletionOptions\.grammarTriggers entry\.|'
  r'grammarTriggers(?: must be an array\.|\[\d+\](?: must be an object\.|'
  r'\.type must be one of |\.token must be an integer from |'
  r'\.value must be a non-empty string\.|'
  r'\.value contains U\+0000, which the core cannot read\.)))|'
  r'CompletionOptions\.speculativeDecoding(?: must be an object\.|'
  r'\.strategies (?:must be a non-empty array\.|has an unknown strategy )|'
  r'\.(?:draftTokenMax|draftTokenMin|ngramSizeN|ngramSizeM|ngramMinHits|'
  r'ngramMatch|ngramTokenMin|ngramTokenMax) must be an integer from |'
  r'\.(?:ngramTokenMin|draftTokenMin) \([^)]*\) must not exceed |'
  r'\.(?:minProbability|draftSplitProbability) must be a number from 0 to 1;|'
  r'\.(?:ngramCacheStatic|ngramCacheDynamic) (?:is empty\.|'
  r'must be a URL string, an ArrayBuffer or a typed array\.))|'
  r'LoRA adapter (?:handle must be a positive integer, got |'
  r'scale (?:must be a finite number, got |[^ ]+ is outside the 32-bit float range\.)|'
  r'source must be a URL string, an ArrayBuffer or a typed array\.)|'
  r'Next-token (?:candidates(?: must be an array or typed array of token ids\.|'
  r'\[\d+\] is .*; expected a 32-bit integer\.)|'
  r'scoring prompt must be a string\.|topK is .*; expected a 32-bit integer\.))',
);

final RegExp _bridgeUnsupportedCompletion = RegExp(
  r'^The loaded WebGPU core does not support CompletionOptions\.'
  r'(?:presencePenalty|minP|thinkingBudget\.pauseGrammar|thinkingBudget|grammarLazy|grammarRoot|penaltyPromptTokensWithGrammar|speculativeDecoding)'
  r'(?: or CompletionOptions\.'
  r'(?:presencePenalty|minP|thinkingBudget\.pauseGrammar|thinkingBudget|grammarLazy|grammarRoot|penaltyPromptTokensWithGrammar|speculativeDecoding))*\.$',
);

/// Classifies request rejections without reclassifying unknown runtime errors.
///
/// General request validators expose JS RangeError/TypeError. Media embedding
/// stable codes are handled separately by the embedding operation fallback.
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
  if (name == 'Error' &&
      (message.contains('CompletionOptions.grammar') ||
          message.contains('CompletionOptions.thinkingBudget') ||
          message.contains(
            'CompletionOptions.penaltyPromptTokensWithGrammar',
          )) &&
      _bridgeUnsupportedCompletion.hasMatch(message)) {
    return LlamaUnsupportedException(message);
  }
  if (name == 'Error' &&
      (message ==
              'Failed to start generation: Failed to initialize sampler chain '
                  '(invalid grammar)' ||
          message ==
              'Generation step failed: The lazy grammar rejected the text '
                  'that triggered it')) {
    return LlamaInferenceException(
      'WebGPU grammar generation failed.',
      message,
    );
  }
  if ((name == 'RangeError' || name == 'TypeError' || name == 'Error') &&
      _bridgeArgument.hasMatch(message)) {
    return LlamaArgumentException(message);
  }
  return null;
}

/// The bridge's `CrossOriginIsolationError` code, which the worker path keeps
/// on the error it rebuilds in the page.
const String _crossOriginIsolationRequiredCode =
    'CROSS_ORIGIN_ISOLATION_REQUIRED';

/// Returns [LlamaUnsupportedException] when [error] is the bridge's
/// `CrossOriginIsolationError` (assets `v0.1.85+`), otherwise null.
LlamaUnsupportedException? webGpuCrossOriginIsolationError(Object error) {
  if (error is LlamaException) return null;
  try {
    final object = error as JSObject;
    final code = object.getProperty<JSAny?>('code'.toJS);
    final name = object.getProperty<JSAny?>('name'.toJS);
    final isIsolationError =
        (code.isA<JSString>() &&
            (code as JSString).toDart == _crossOriginIsolationRequiredCode) ||
        (name.isA<JSString>() &&
            (name as JSString).toDart == 'CrossOriginIsolationError');
    if (!isIsolationError) return null;
  } catch (_) {
    return null;
  }
  return LlamaUnsupportedException(
    'The Web runtime needs cross-origin isolation (COOP/COEP) for shared '
    'memory, which this page does not have. Serve the page with '
    '"Cross-Origin-Opener-Policy: same-origin" and '
    '"Cross-Origin-Embedder-Policy: require-corp". '
    '"credentialless" does not isolate Safari.',
  );
}

final RegExp _gpuUnavailableNote = RegExp(r'(?:^|;)gpu_unavailable:([^;]+)');

/// Why the bridge ran without GPU layers, from its `gpu_unavailable:<reason>`
/// runtime note (assets `v0.1.85+`), or an empty string.
String webGpuUnavailableDetail(String runtimeNotes) {
  final reason = _gpuUnavailableNote.firstMatch(runtimeNotes)?.group(1);
  return switch (reason) {
    null => '',
    'no_webgpu' => ' The browser exposes no WebGPU.',
    'no_adapter' => ' The browser granted no WebGPU adapter.',
    'adapter_missing_shader_f16' =>
      ' WebGPU needs the shader-f16 feature, which this adapter does not '
          'expose. On Linux with an NVIDIA GPU, Chrome exposes it only with '
          'driver 615.71 or newer.',
    _ => ' The bridge reported gpu_unavailable:$reason.',
  };
}
