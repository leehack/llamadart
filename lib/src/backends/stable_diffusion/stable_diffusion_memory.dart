import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

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

/// Memory the host can give a new image model, and where the figure came
/// from, or `null` when the platform does not report one.
///
/// - Android and Linux: `MemAvailable` from `/proc/meminfo`, the memory the
///   kernel can hand out without swapping. Android's low-memory killer acts
///   on the same figure.
/// - iOS: `os_proc_available_memory()`, what the app can still allocate
///   before it reaches its memory limit.
/// - macOS: physical memory (`hw.memsize`). macOS compresses and swaps, so
///   only a model that cannot fit at all is refused.
/// - Windows and others: `null`; the check is skipped.
///
/// [abi], [readMemInfo], [iosAvailableMemory] and [macosPhysicalMemory]
/// default to the host; tests replace them.
({int bytes, String source})? readStableDiffusionMemoryBudget({
  Abi? abi,
  String? Function() readMemInfo = _readProcMemInfo,
  int? Function() iosAvailableMemory = _iosAvailableMemory,
  int? Function() macosPhysicalMemory = _macosPhysicalMemory,
}) {
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
  return bytes == null || bytes <= 0
      ? null
      : (bytes: bytes, source: reading.$2);
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
