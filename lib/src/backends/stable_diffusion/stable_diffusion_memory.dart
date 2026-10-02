import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../../core/image/image_generation_driver.dart';

/// Up to [length] bytes of the file at [path] from [offset]; fewer at its end.
Future<Uint8List> readStableDiffusionFileRange(
  String path,
  int offset,
  int length,
) async {
  final file = await File(path).open();
  try {
    await file.setPosition(offset);
    return await file.read(length);
  } finally {
    await file.close();
  }
}

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
/// - Android: the larger of `MemAvailable` from `/proc/meminfo` and half of
///   `MemTotal` less the app's own memory (`VmRSS` plus `VmSwap`).
///   `MemAvailable`
///   leaves out what the low-memory killer frees by stopping cached apps and
///   what it swaps to zram: on six 4 to 16 GB phones, a foreground app that
///   kept touching all of its memory was killed only after allocating 0.9 to
///   3.6 GiB more than `MemAvailable`, 53 to 84% of `MemTotal`.
/// - Linux: `MemAvailable`, the memory the kernel can hand out without
///   swapping.
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
/// [abi], [readMemInfo], [readProcessStatus], [iosAvailableMemory],
/// [macosPhysicalMemory] and [metalRecommendedWorkingSet] default to the
/// host; tests replace them.
({int bytes, String source})? readStableDiffusionMemoryBudget({
  ImageGenerationComputeDevice device = ImageGenerationComputeDevice.cpu,
  Abi? abi,
  String? Function() readMemInfo = _readProcMemInfo,
  String? Function() readProcessStatus = _readProcSelfStatus,
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
    'android' => _androidMemoryBudget(readMemInfo(), readProcessStatus()),
    'linux' => (
      switch (readMemInfo()) {
        final String memInfo => parseProcMemoryBytes(memInfo, 'MemAvailable'),
        null => null,
      },
      _memAvailableSource,
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

const String _memAvailableSource = 'MemAvailable in /proc/meminfo';

(int?, String) _androidMemoryBudget(String? memInfo, String? status) {
  if (memInfo == null) {
    return (null, _memAvailableSource);
  }
  final available = parseProcMemoryBytes(memInfo, 'MemAvailable');
  final total = parseProcMemoryBytes(memInfo, 'MemTotal');
  final resident = status == null
      ? null
      : parseProcMemoryBytes(status, 'VmRSS');
  if (total == null || resident == null) {
    return (available, _memAvailableSource);
  }
  final swapped = parseProcMemoryBytes(status!, 'VmSwap') ?? 0;
  final halfLessApp = total ~/ 2 - resident - swapped;
  if (available != null && available >= halfLessApp) {
    return (available, _memAvailableSource);
  }
  return (
    halfLessApp,
    "half of MemTotal in /proc/meminfo less the app's memory",
  );
}

/// The `[field]:  <n> kB` line of `/proc/meminfo` or `/proc/self/status`
/// text, in bytes, or `null` when it is missing or malformed (kernels before
/// 3.14 do not report `MemAvailable`).
int? parseProcMemoryBytes(String text, String field) {
  final match = RegExp(
    '^${RegExp.escape(field)}:\\s+(\\d+)\\s*kB\\s*\$',
    multiLine: true,
  ).firstMatch(text);
  final kib = match == null ? null : int.tryParse(match.group(1)!);
  return kib == null ? null : kib * 1024;
}

String? _readProcMemInfo() => _readProcFile('/proc/meminfo');

String? _readProcSelfStatus() => _readProcFile('/proc/self/status');

String? _readProcFile(String path) {
  try {
    return File(path).readAsStringSync();
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
