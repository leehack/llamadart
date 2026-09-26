import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// Names the Windows footprint counter.
const windowsFootprintSource =
    'GetProcessMemoryInfo PROCESS_MEMORY_COUNTERS_EX.PrivateUsage';

/// `PROCESS_MEMORY_COUNTERS_EX` in `<psapi.h>`.
final class ProcessMemoryCountersEx extends Struct {
  @Uint32()
  external int cb;
  @Uint32()
  external int pageFaultCount;
  @Size()
  external int peakWorkingSetSize;
  @Size()
  external int workingSetSize;
  @Size()
  external int quotaPeakPagedPoolUsage;
  @Size()
  external int quotaPagedPoolUsage;
  @Size()
  external int quotaPeakNonPagedPoolUsage;
  @Size()
  external int quotaNonPagedPoolUsage;
  @Size()
  external int pagefileUsage;
  @Size()
  external int peakPagefileUsage;
  @Size()
  external int privateUsage;
}

/// `PrivateUsage` from a `GetProcessMemoryInfo` call that returned
/// [succeeded], or null when it failed.
int? windowsFootprintFrom(int succeeded, ProcessMemoryCountersEx counters) =>
    succeeded != 0 ? counters.privateUsage : null;

/// Calls `K32GetProcessMemoryInfo` for this process and passes the result to
/// [read].
R? readProcessMemoryCounters<R>(
  R? Function(int succeeded, ProcessMemoryCountersEx counters) read,
) {
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final currentProcess = kernel32
      .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
        'GetCurrentProcess',
      );
  final memoryInfo = kernel32
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<ProcessMemoryCountersEx>, Uint32),
        int Function(Pointer<Void>, Pointer<ProcessMemoryCountersEx>, int)
      >('K32GetProcessMemoryInfo');
  final size = sizeOf<ProcessMemoryCountersEx>();
  final counters = calloc<ProcessMemoryCountersEx>()..ref.cb = size;
  try {
    return read(memoryInfo(currentProcess(), counters, size), counters.ref);
  } finally {
    calloc.free(counters);
  }
}

/// This process's private committed bytes, or null when
/// `K32GetProcessMemoryInfo` fails.
int? readWindowsFootprint() => readProcessMemoryCounters(windowsFootprintFrom);
