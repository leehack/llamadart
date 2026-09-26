import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// Names the Windows footprint counter.
const windowsFootprintSource =
    'GetProcessMemoryInfo PROCESS_MEMORY_COUNTERS_EX2 '
    'PrivateUsage + SharedCommitUsage';

/// Written to `SharedCommitUsage` before the call, so a Windows build that
/// accepts the structure but does not fill that field is detected.
const windowsUnfilledSentinel = -1;

/// `PROCESS_MEMORY_COUNTERS_EX2` in `<psapi.h>`.
final class ProcessMemoryCountersEx2 extends Struct {
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
  @Size()
  external int privateWorkingSetSize;
  @Uint64()
  external int sharedCommitUsage;
}

/// `PrivateUsage` plus `SharedCommitUsage` from a `GetProcessMemoryInfo` call
/// that returned [succeeded], or null when it failed or left
/// `SharedCommitUsage` at [windowsUnfilledSentinel].
int? windowsFootprintFrom(int succeeded, ProcessMemoryCountersEx2 counters) =>
    succeeded == 0 || counters.sharedCommitUsage == windowsUnfilledSentinel
    ? null
    : counters.privateUsage + counters.sharedCommitUsage;

/// Calls `K32GetProcessMemoryInfo` for this process and passes the result to
/// [read].
R? readProcessMemoryCounters<R>(
  R? Function(int succeeded, ProcessMemoryCountersEx2 counters) read,
) {
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final currentProcess = kernel32
      .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
        'GetCurrentProcess',
      );
  final memoryInfo = kernel32
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Pointer<ProcessMemoryCountersEx2>,
          Uint32,
        ),
        int Function(Pointer<Void>, Pointer<ProcessMemoryCountersEx2>, int)
      >('K32GetProcessMemoryInfo');
  final size = sizeOf<ProcessMemoryCountersEx2>();
  final counters = calloc<ProcessMemoryCountersEx2>()
    ..ref.cb = size
    ..ref.sharedCommitUsage = windowsUnfilledSentinel;
  try {
    return read(memoryInfo(currentProcess(), counters, size), counters.ref);
  } finally {
    calloc.free(counters);
  }
}

/// This process's private and shared committed bytes, or null when
/// `K32GetProcessMemoryInfo` fails or does not report shared commit.
int? readWindowsFootprint() => readProcessMemoryCounters(windowsFootprintFrom);
