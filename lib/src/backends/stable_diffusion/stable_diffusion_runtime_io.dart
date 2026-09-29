import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../../core/exceptions.dart';
import 'stable_diffusion_bindings.dart' as sd;
import 'stable_diffusion_runtime_status.dart';

/// The native calls the probe makes; tests substitute a fake.
abstract interface class StableDiffusionNativeApi {
  /// `sd_version()`.
  String version();

  /// `sd_commit()`.
  String commit();

  /// `sd_list_devices()` output.
  String listDevices();
}

/// ABIs stable-diffusion-native publishes a runtime for. `Abi.iosArm64` covers
/// both the device and the arm64 simulator archive.
const Set<Abi> stableDiffusionPublishedAbis = {
  Abi.androidArm64,
  Abi.iosArm64,
  Abi.linuxArm64,
  Abi.linuxX64,
  Abi.macosArm64,
  Abi.macosX64,
  Abi.windowsX64,
};

/// Probes the stable_diffusion runtime the build hook bundled.
///
/// The library is resolved through its native-asset id
/// (`package:llamadart/stable_diffusion`) on the first native call, so
/// nothing is loaded before the platform checks pass: an unpublished ABI is
/// rejected up front, and the CPU must support what the runtime was compiled
/// for, or it would crash with an illegal instruction:
///
/// - Android arm64: `/proc/cpuinfo` must report
///   [stableDiffusionRequiredArmFeatures] (Armv8.2 dot-product and fp16).
/// - Linux x64: `/proc/cpuinfo` must report
///   [stableDiffusionRequiredX86Features].
/// - Windows x64: `IsProcessorFeaturePresent` must report AVX2. Windows has no
///   feature constant for FMA, F16C or BMI2; every x86 CPU with AVX2 also has
///   them.
///
/// macOS x64 needs no check: the runtime is cross-compiled without AVX, and
/// macOS 13.3 runs only on Intel CPUs that have AVX2 anyway.
///
/// Then `sd_version`, `sd_commit` and `sd_list_devices` must answer.
///
/// [abi], [readCpuInfo], [windowsHasAvx2] and [api] default to the host and
/// the bundled library; tests replace them.
StableDiffusionRuntimeStatus probeStableDiffusionRuntime({
  Abi? abi,
  String? Function() readCpuInfo = _readProcCpuInfo,
  bool Function() windowsHasAvx2 = _windowsHasAvx2,
  StableDiffusionNativeApi api = const _BundledStableDiffusionApi(),
}) {
  final targetAbi = abi ?? Abi.current();
  final platform = _abiLabel(targetAbi);
  if (!stableDiffusionPublishedAbis.contains(targetAbi)) {
    return StableDiffusionRuntimeStatus.unavailable(
      LlamaUnsupportedException(
        'stable_diffusion runtime is not published for $platform; it is '
        'available on android-arm64, ios-arm64 (device and simulator), '
        'macos-arm64, macos-x64, linux-arm64, linux-x64 and windows-x64.',
      ),
    );
  }

  if (targetAbi == Abi.androidArm64) {
    final cpuInfo = readCpuInfo();
    if (cpuInfo == null) {
      return StableDiffusionRuntimeStatus.unavailable(
        LlamaUnsupportedException(
          'stable_diffusion runtime on $platform requires Armv8.2 '
          'dot-product and fp16 ($_armFeatureList), and /proc/cpuinfo could '
          'not be read to confirm it.',
        ),
      );
    }
    if (!cpuInfoReportsRequiredArmFeatures(cpuInfo)) {
      return StableDiffusionRuntimeStatus.unavailable(
        LlamaUnsupportedException(
          'stable_diffusion runtime on $platform requires Armv8.2 '
          'dot-product and fp16 ($_armFeatureList), which this CPU does not '
          'report on every core in /proc/cpuinfo.',
        ),
      );
    }
  }

  if (targetAbi == Abi.linuxX64) {
    final cpuInfo = readCpuInfo();
    if (cpuInfo == null || !cpuInfoReportsRequiredX86Features(cpuInfo)) {
      final evidence = cpuInfo == null
          ? '/proc/cpuinfo could not be read to confirm it'
          : 'this CPU does not report them in /proc/cpuinfo';
      return StableDiffusionRuntimeStatus.unavailable(
        LlamaUnsupportedException(
          'stable_diffusion runtime on $platform requires an x86-64 CPU with '
          '$_x86FeatureList, and $evidence.',
        ),
      );
    }
  }

  if (targetAbi == Abi.windowsX64 && !windowsHasAvx2()) {
    return StableDiffusionRuntimeStatus.unavailable(
      LlamaUnsupportedException(
        'stable_diffusion runtime on $platform requires an x86-64 CPU with '
        '$_x86FeatureList; this CPU does not report AVX2.',
      ),
    );
  }

  try {
    final version = api.version();
    final commit = api.commit();
    final devices = parseStableDiffusionDeviceList(api.listDevices());
    return StableDiffusionRuntimeStatus.available(
      version: version,
      commit: commit,
      devices: devices,
    );
  } on ArgumentError catch (error) {
    return StableDiffusionRuntimeStatus.unavailable(
      stableDiffusionLoadFailure(platform: platform, error: error),
    );
  }
}

/// Maps a failed native-asset resolution to the requirement the app missed.
///
/// The VM reports a missing asset, a library that fails to load and a missing
/// symbol through the same [ArgumentError]; only its message tells them
/// apart. A missing asset is checked first because that message lists every
/// bundled asset, which on Linux and Windows includes llama.cpp's
/// `ggml-vulkan`. A Linux dynamic-loader failure names the loader library it
/// could not find; Windows reports only error 126, so that message names the
/// Vulkan loader as a possible cause.
LlamaUnsupportedException stableDiffusionLoadFailure({
  required String platform,
  required ArgumentError error,
}) {
  final detail = '${error.message ?? error}';
  if (detail.contains('No asset with id')) {
    return LlamaUnsupportedException(
      'stable_diffusion runtime is not bundled for $platform; add '
      'stable_diffusion to hooks.user_defines.llamadart.'
      'llamadart_native_runtimes and rebuild.',
    );
  }
  if (_vulkanLoaderNames.any(detail.toLowerCase().contains)) {
    return LlamaUnsupportedException(
      'stable_diffusion runtime on $platform is the Vulkan variant, which '
      'requires the Vulkan loader (libvulkan.so.1 on Linux, vulkan-1.dll on '
      'Windows); install it, or set '
      'hooks.user_defines.llamadart.llamadart_stable_diffusion_backends to '
      '[cpu] for this platform and rebuild.',
    );
  }
  if (detail.contains('Failed to lookup symbol')) {
    return LlamaUnsupportedException(
      'stable_diffusion runtime on $platform does not export the '
      'stable-diffusion.h API these bindings were generated from; bundle the '
      'pinned stable-diffusion-native release.',
    );
  }
  final firstLine = detail.split('\n').first.trimRight();
  if (detail.contains('error code: 126')) {
    return LlamaUnsupportedException(
      'stable_diffusion runtime could not be loaded on $platform: $firstLine. '
      'Windows does not name the missing dependency; if the app bundles the '
      'Vulkan build, install the Vulkan loader (vulkan-1.dll) or set '
      'hooks.user_defines.llamadart.llamadart_stable_diffusion_backends to '
      '[cpu] and rebuild.',
    );
  }
  return LlamaUnsupportedException(
    'stable_diffusion runtime could not be loaded on $platform: $firstLine',
  );
}

final String _armFeatureList = stableDiffusionRequiredArmFeatures.join(', ');

final String _x86FeatureList = stableDiffusionRequiredX86Features
    .map((feature) => feature.toUpperCase())
    .join(', ');

/// `PF_AVX2_INSTRUCTIONS_AVAILABLE` for `IsProcessorFeaturePresent`.
const int _pfAvx2InstructionsAvailable = 40;

const List<String> _vulkanLoaderNames = ['libvulkan.so', 'vulkan-1.dll'];

String _abiLabel(Abi abi) => abi.toString().replaceAll('_', '-');

String? _readProcCpuInfo() {
  try {
    return File('/proc/cpuinfo').readAsStringSync();
  } on FileSystemException {
    return null;
  }
}

bool _windowsHasAvx2() {
  final isProcessorFeaturePresent = DynamicLibrary.open('kernel32.dll')
      .lookupFunction<Int32 Function(Uint32), int Function(int)>(
        'IsProcessorFeaturePresent',
      );
  return isProcessorFeaturePresent(_pfAvx2InstructionsAvailable) != 0;
}

final class _BundledStableDiffusionApi implements StableDiffusionNativeApi {
  const _BundledStableDiffusionApi();

  @override
  String version() => _string(sd.sd_version());

  @override
  String commit() => _string(sd.sd_commit());

  @override
  String listDevices() {
    final size = sd.sd_list_devices(nullptr, 0);
    if (size <= 0) {
      return '';
    }
    final buffer = calloc<Char>(size + 1);
    try {
      sd.sd_list_devices(buffer, size + 1);
      return buffer.cast<Utf8>().toDartString();
    } finally {
      calloc.free(buffer);
    }
  }

  static String _string(Pointer<Char> value) =>
      value == nullptr ? '' : value.cast<Utf8>().toDartString();
}
