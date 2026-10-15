import 'dart:ffi';
import 'dart:io';

import '../../core/exceptions.dart';
import 'litert_lm_runtime.dart';

/// CPU backend selector accepted by the native LiteRT-LM runtime.
const String liteRtLmCpuBackend = 'cpu';

/// GPU backend selector accepted by the native LiteRT-LM runtime.
const String liteRtLmGpuBackend = 'gpu';

/// Android NPU backend selector accepted by the native LiteRT-LM runtime.
const String liteRtLmNpuBackend = 'npu';

/// Returns the LiteRT-LM native backend names available on this platform.
List<String> liteRtLmAvailableNativeBackendsForCurrentPlatform() {
  if (Platform.isAndroid) {
    return const <String>[
      liteRtLmCpuBackend,
      liteRtLmGpuBackend,
      liteRtLmNpuBackend,
    ];
  }
  if (liteRtLmNativeGpuSupportedOnCurrentPlatform()) {
    return const <String>[liteRtLmCpuBackend, liteRtLmGpuBackend];
  }
  return const <String>[liteRtLmCpuBackend];
}

/// Returns the native LiteRT-LM backend used for automatic selection.
///
/// Linux and Windows default to CPU; GPU execution there requires explicit
/// selection. macOS x86_64 reports CPU, but LiteRT-LM has no runtime there.
String liteRtLmDefaultNativeBackendForCurrentPlatform() {
  if (Platform.isAndroid ||
      Platform.isIOS ||
      liteRtLmGateAbi() == Abi.macosArm64) {
    return liteRtLmGpuBackend;
  }
  return liteRtLmCpuBackend;
}

/// Returns whether the current native LiteRT-LM target exposes a GPU backend.
bool liteRtLmNativeGpuSupportedOnCurrentPlatform() {
  final abi = liteRtLmGateAbi();
  return Platform.isAndroid ||
      Platform.isIOS ||
      abi == Abi.macosArm64 ||
      liteRtLmDesktopGpuSupportedForAbi(abi);
}

/// Throws a [LlamaUnsupportedException] when the current target cannot run
/// the native LiteRT-LM [backend] and the request must fail with a typed
/// error instead of an unavailable-backend [ArgumentError].
///
/// litert-lm-native publishes arm64-only macOS runtimes
/// ([leehack/litert-lm-native#72](https://github.com/leehack/litert-lm-native/issues/72)),
/// so macOS x86_64, including an Apple-silicon app under Rosetta, has no
/// LiteRT-LM runtime at all.
void liteRtLmEnsureNativeBackendSupported(String backend) {
  if (backend != liteRtLmGpuBackend || liteRtLmGateAbi() != Abi.macosX64) {
    return;
  }
  throw LlamaUnsupportedException(
    'LiteRT-LM GPU is not available on macOS x86_64 because LiteRT-LM is not '
    'available there; litert-lm-native publishes arm64-only macOS runtimes '
    '(leehack/litert-lm-native#72). Run the app natively on Apple silicon, '
    'not under Rosetta, or use the llama.cpp backend.',
  );
}

/// Returns whether a Linux or Windows ABI has qualified GPU runtime support.
///
/// ARM64 desktop targets remain unavailable until separately qualified.
bool liteRtLmDesktopGpuSupportedForAbi(Abi abi) {
  return abi == Abi.linuxX64 || abi == Abi.windowsX64;
}

/// Normalizes an optional direct LiteRT-LM native backend override.
String? normalizeLiteRtLmNativeBackendOverride(String? backend) {
  if (backend == null) {
    return null;
  }
  final normalized = backend.trim().toLowerCase();
  if (normalized.isEmpty) {
    return null;
  }
  if (normalized == liteRtLmCpuBackend ||
      normalized == liteRtLmGpuBackend ||
      normalized == liteRtLmNpuBackend) {
    return normalized;
  }
  throw ArgumentError(
    'LiteRtLmBackend backend must be cpu, gpu, or npu; got $backend',
  );
}
