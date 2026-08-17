// ignore_for_file: public_member_api_docs

import 'dart:ffi';

import 'package:ffi/ffi.dart';

typedef _CuInitNative = Int32 Function(Uint32 flags);
typedef _CuInitDart = int Function(int flags);
typedef _CuDriverGetVersionNative = Int32 Function(Pointer<Int32> version);
typedef _CuDriverGetVersionDart = int Function(Pointer<Int32> version);
typedef _CuDeviceGetCountNative = Int32 Function(Pointer<Int32> count);
typedef _CuDeviceGetCountDart = int Function(Pointer<Int32> count);
typedef _CuDeviceComputeCapabilityNative =
    Int32 Function(Pointer<Int32> major, Pointer<Int32> minor, Int32 device);
typedef _CuDeviceComputeCapabilityDart =
    int Function(Pointer<Int32> major, Pointer<Int32> minor, int device);

class WindowsCudaDriverProbe {
  final int driverApiVersion;
  final List<int> computeCapabilities;

  const WindowsCudaDriverProbe({
    required this.driverApiVersion,
    required this.computeCapabilities,
  });
}

int? windowsCudaMajorFromFileName(String fileName) {
  final match = RegExp(
    r'^ggml-cuda-(12|13)(?:-[^\\/]+)*\.dll$',
    caseSensitive: false,
  ).firstMatch(fileName);
  return int.tryParse(match?.group(1) ?? '');
}

int? selectWindowsCudaMajor({
  required Set<int> availableMajors,
  required WindowsCudaDriverProbe probe,
}) {
  if (probe.computeCapabilities.isEmpty) {
    return null;
  }
  final minimumCapability = probe.computeCapabilities.reduce(
    (value, element) => value < element ? value : element,
  );
  if (availableMajors.contains(13) &&
      probe.driverApiVersion >= 13000 &&
      minimumCapability >= 75) {
    return 13;
  }
  if (availableMajors.contains(12) &&
      probe.driverApiVersion >= 12000 &&
      minimumCapability >= 50) {
    return 12;
  }
  return null;
}

WindowsCudaDriverProbe? probeWindowsCudaDriver() {
  try {
    final library = DynamicLibrary.open('nvcuda.dll');
    final cuInit = library.lookupFunction<_CuInitNative, _CuInitDart>('cuInit');
    final cuDriverGetVersion = library
        .lookupFunction<_CuDriverGetVersionNative, _CuDriverGetVersionDart>(
          'cuDriverGetVersion',
        );
    final cuDeviceGetCount = library
        .lookupFunction<_CuDeviceGetCountNative, _CuDeviceGetCountDart>(
          'cuDeviceGetCount',
        );
    final cuDeviceComputeCapability = library
        .lookupFunction<
          _CuDeviceComputeCapabilityNative,
          _CuDeviceComputeCapabilityDart
        >('cuDeviceComputeCapability');
    if (cuInit(0) != 0) {
      return null;
    }

    final driverVersion = calloc<Int32>();
    final deviceCount = calloc<Int32>();
    final major = calloc<Int32>();
    final minor = calloc<Int32>();
    try {
      if (cuDriverGetVersion(driverVersion) != 0 ||
          cuDeviceGetCount(deviceCount) != 0 ||
          deviceCount.value <= 0) {
        return null;
      }
      final capabilities = <int>[];
      for (var device = 0; device < deviceCount.value; device++) {
        if (cuDeviceComputeCapability(major, minor, device) == 0) {
          capabilities.add(major.value * 10 + minor.value);
        }
      }
      if (capabilities.isEmpty) {
        return null;
      }
      return WindowsCudaDriverProbe(
        driverApiVersion: driverVersion.value,
        computeCapabilities: List.unmodifiable(capabilities),
      );
    } finally {
      calloc.free(driverVersion);
      calloc.free(deviceCount);
      calloc.free(major);
      calloc.free(minor);
    }
  } catch (_) {
    return null;
  }
}
