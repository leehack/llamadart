import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../../core/exceptions.dart';

typedef _GetApiVersionNative =
    Int Function(Pointer<Int>, Pointer<Int>, Pointer<Int>);
typedef _GetApiVersionDart =
    int Function(Pointer<Int>, Pointer<Int>, Pointer<Int>);

/// Refuses versioned C APIs before using the pre-1.0 LiteRT-LM bindings.
///
/// LiteRT-LM 0.19 introduces `litert_lm_get_api_version` alongside status-return
/// and output-parameter signatures. Reusing the legacy function names does not
/// make their calling conventions compatible. The pinned 0.18 runtime has no
/// version export and continues through the existing capability checks.
void requireLiteRtLmLegacyCApi(DynamicLibrary library) {
  if (!library.providesSymbol('litert_lm_get_api_version')) {
    return;
  }
  final getVersion = library
      .lookupFunction<_GetApiVersionNative, _GetApiVersionDart>(
        'litert_lm_get_api_version',
      );
  final parts = calloc<Int>(3);
  try {
    final status = getVersion(parts, parts + 1, parts + 2);
    final version = status == 0
        ? '${parts[0]}.${parts[1]}.${parts[2]}'
        : 'unknown (version probe status $status)';
    throw LlamaUnsupportedException(
      'Native LiteRT-LM C API $version is incompatible with this package\'s '
      'pre-1.0 bindings. LiteRT-LM 0.19 and C API 1.0 require the consumer '
      'migration tracked in llamadart#1677. Use the pinned '
      'litert-lm-native v0.18.1-4 runtime, or a package release explicitly '
      'supporting the selected C API. No legacy engine call was attempted.',
    );
  } finally {
    calloc.free(parts);
  }
}
