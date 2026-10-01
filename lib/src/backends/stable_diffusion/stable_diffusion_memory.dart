import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../../core/image/image_generation_driver.dart';

/// Size of the regular file at [path] in bytes, or `null` when there is none.
int? stableDiffusionFileSize(String path) {
  final file = File(path);
  try {
    return file.statSync().type == FileSystemEntityType.file
        ? file.lengthSync()
        : null;
  } on FileSystemException {
    return null;
  }
}

/// Memory a new image model can use on [device], and where the figure came
/// from, or `null` when it is not known.
///
/// On the CPU, host memory:
/// - Android and Linux: `MemAvailable` from `/proc/meminfo`, the memory the
///   kernel can hand out without swapping. Android's low-memory killer acts
///   on the same figure.
/// - iOS: `os_proc_available_memory()`, what the app can still allocate
///   before it reaches its memory limit.
/// - macOS: physical memory (`hw.memsize`). macOS compresses and swaps, so
///   only a model that cannot fit at all is refused.
/// - Windows and others: `null`; the check is skipped.
///
/// On Metal, the same figure, capped on macOS by the GPU's
/// `recommendedMaxWorkingSetSize`: about two thirds to three quarters of
/// physical memory, beyond which Metal buffers page.
///
/// On other GPUs, such as Vulkan, `null`: the weights live in device memory,
/// which the runtime does not report (stable-diffusion-native#9), so host
/// memory would be the wrong figure.
///
/// [abi], [readMemInfo], [iosAvailableMemory], [macosPhysicalMemory] and
/// [metalRecommendedWorkingSet] default to the host; tests replace them.
({int bytes, String source})? readStableDiffusionMemoryBudget({
  ImageGenerationComputeDevice device = ImageGenerationComputeDevice.cpu,
  Abi? abi,
  String? Function() readMemInfo = _readProcMemInfo,
  int? Function() iosAvailableMemory = _iosAvailableMemory,
  int? Function() macosPhysicalMemory = _macosPhysicalMemory,
  int? Function() metalRecommendedWorkingSet = _metalRecommendedWorkingSet,
}) {
  if (device == ImageGenerationComputeDevice.otherGpu) {
    return null;
  }
  final target = abi ?? Abi.current();
  final os = target.toString().split('_').first;
  final (int?, String) reading = switch (os) {
    'android' || 'linux' => (
      switch (readMemInfo()) {
        final String memInfo => parseMemAvailableBytes(memInfo),
        null => null,
      },
      'MemAvailable in /proc/meminfo',
    ),
    'ios' => (iosAvailableMemory(), "the app's remaining iOS memory limit"),
    'macos' => (macosPhysicalMemory(), 'physical memory'),
    _ => (null, ''),
  };
  final bytes = reading.$1;
  if (bytes == null || bytes <= 0) {
    return null;
  }
  if (os == 'macos' && device == ImageGenerationComputeDevice.metal) {
    final workingSet = metalRecommendedWorkingSet();
    if (workingSet != null && workingSet > 0 && workingSet < bytes) {
      return (bytes: workingSet, source: "Metal's recommended GPU working set");
    }
  }
  return (bytes: bytes, source: reading.$2);
}

/// `MemAvailable` from `/proc/meminfo` text, in bytes, or `null` when the
/// line is missing or malformed (kernels before 3.14 do not report it).
int? parseMemAvailableBytes(String memInfo) {
  final match = RegExp(
    r'^MemAvailable:\s+(\d+)\s*kB\s*$',
    multiLine: true,
  ).firstMatch(memInfo);
  final kib = match == null ? null : int.tryParse(match.group(1)!);
  return kib == null ? null : kib * 1024;
}

String? _readProcMemInfo() {
  try {
    return File('/proc/meminfo').readAsStringSync();
  } on FileSystemException {
    return null;
  }
}

int? _iosAvailableMemory() {
  try {
    final available = DynamicLibrary.process()
        .lookupFunction<Size Function(), int Function()>(
          'os_proc_available_memory',
        );
    return available();
  } on ArgumentError {
    return null;
  }
}

int? _macosPhysicalMemory() {
  try {
    final sysctlbyname = DynamicLibrary.process()
        .lookupFunction<
          Int Function(
            Pointer<Utf8>,
            Pointer<Void>,
            Pointer<Size>,
            Pointer<Void>,
            Size,
          ),
          int Function(
            Pointer<Utf8>,
            Pointer<Void>,
            Pointer<Size>,
            Pointer<Void>,
            int,
          )
        >('sysctlbyname');
    return using((arena) {
      final value = arena<Uint64>();
      final length = arena<Size>()..value = sizeOf<Uint64>();
      final status = sysctlbyname(
        'hw.memsize'.toNativeUtf8(allocator: arena),
        value.cast(),
        length,
        nullptr,
        0,
      );
      return status == 0 ? value.value : null;
    });
  } on ArgumentError {
    return null;
  }
}

/// `MTLCreateSystemDefaultDevice().recommendedMaxWorkingSetSize`, through the
/// Objective-C runtime, or `null` without a Metal device.
int? _metalRecommendedWorkingSet() {
  try {
    final metal = DynamicLibrary.open(
      '/System/Library/Frameworks/Metal.framework/Metal',
    );
    final objc = DynamicLibrary.open('/usr/lib/libobjc.A.dylib');
    final createDevice = metal
        .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
          'MTLCreateSystemDefaultDevice',
        );
    final selector = objc
        .lookupFunction<
          Pointer<Void> Function(Pointer<Utf8>),
          Pointer<Void> Function(Pointer<Utf8>)
        >('sel_registerName');
    final sendUint64 = objc
        .lookupFunction<
          Uint64 Function(Pointer<Void>, Pointer<Void>),
          int Function(Pointer<Void>, Pointer<Void>)
        >('objc_msgSend');
    final sendVoid = objc
        .lookupFunction<
          Void Function(Pointer<Void>, Pointer<Void>),
          void Function(Pointer<Void>, Pointer<Void>)
        >('objc_msgSend');
    return using((arena) {
      Pointer<Void> select(String name) =>
          selector(name.toNativeUtf8(allocator: arena));
      final device = createDevice();
      if (device == nullptr) {
        return null;
      }
      try {
        return sendUint64(device, select('recommendedMaxWorkingSetSize'));
      } finally {
        sendVoid(device, select('release'));
      }
    });
  } on ArgumentError {
    return null;
  }
}
