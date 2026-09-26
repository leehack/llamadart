import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:llamadart_validation/src/process_memory.dart';
import 'package:llamadart_validation/src/process_memory_darwin.dart';
import 'package:llamadart_validation/src/process_memory_io.dart'
    show footprintCounterFor, sampleFootprint;
import 'package:llamadart_validation/src/process_memory_linux.dart';
import 'package:llamadart_validation/src/process_memory_windows.dart';
import 'package:test/test.dart';

const mib = 1024 * 1024;

/// `/proc/self/status` from Linux 6.8, trimmed.
const linuxStatus = '''
Name:\tdart
Umask:\t0022
State:\tS (sleeping)
VmPeak:\t 3050212 kB
VmSize:\t 2983540 kB
VmHWM:\t  402940 kB
VmRSS:\t  398212 kB
RssAnon:\t  150020 kB
RssFile:\t  247168 kB
RssShmem:\t    1024 kB
VmData:\t  612300 kB
VmSwap:\t    2048 kB
HugetlbPages:\t       0 kB
Threads:\t12
''';

/// `/proc/self/status` from Linux 4.4, which has no `RssAnon`, trimmed.
const linux44Status = '''
Name:\tdart
VmHWM:\t  402940 kB
VmRSS:\t  398212 kB
VmData:\t  612300 kB
VmSwap:\t       0 kB
Threads:\t12
''';

/// Zeroes a [TaskVmInfoRev1] and writes [value] as 8 bytes at [offset].
TaskVmInfoRev1 taskVmInfoWith(
  Pointer<TaskVmInfoRev1> memory,
  int offset,
  int value,
) {
  final size = sizeOf<TaskVmInfoRev1>();
  memory.cast<Uint8>().asTypedList(size).fillRange(0, size, 0);
  (memory.cast<Uint8>() + offset).cast<Uint64>().value = value;
  return memory.ref;
}

void main() {
  group('Linux /proc/self/status', () {
    test('sums RssAnon and VmSwap, ignoring file and shared pages', () {
      expect(linuxFootprintFrom(linuxStatus), (150020 + 2048) * 1024);
    });
    test('without a VmSwap line is unmeasurable', () {
      expect(
        linuxFootprintFrom(linuxStatus.replaceFirst(RegExp('VmSwap.*\n'), '')),
        isNull,
      );
    });
    test('without RssAnon, as before Linux 4.5, is unmeasurable', () {
      expect(linuxFootprintFrom(linux44Status), isNull);
    });
    test('a value without a kB unit is unmeasurable', () {
      expect(
        linuxFootprintFrom(linuxStatus.replaceFirst('150020 kB', '150020')),
        isNull,
      );
    });
  });

  group('Darwin task_vm_info', () {
    test('matches the revision 1 layout of <mach/task_info.h>', () {
      expect(taskVmInfoFlavor, 22);
      expect(taskVmInfoRev1Count, 38);
      expect(sizeOf<TaskVmInfoRev1>(), taskVmInfoRev1Count * 4);
      final memory = calloc<TaskVmInfoRev1>();
      addTearDown(() => calloc.free(memory));
      expect(
        taskVmInfoWith(memory, 144, 0x1234567890).physFootprint,
        0x1234567890,
      );
      expect(taskVmInfoWith(memory, 120, 77).compressed, 77);
      expect(taskVmInfoWith(memory, 16, 99).residentSize, 99);
    });
    test('matches the offsets the macOS SDK compiles', () async {
      final dir = await Directory.systemTemp.createTemp('task_vm_info');
      addTearDown(() => dir.delete(recursive: true));
      final source = File('${dir.path}/layout.c')
        ..writeAsStringSync('''
#include <stddef.h>
#include <stdio.h>
#include <mach/mach.h>
int main(void) {
  printf("%d %d %zu %zu %zu", TASK_VM_INFO, (int)TASK_VM_INFO_REV1_COUNT,
         offsetof(task_vm_info_data_t, phys_footprint),
         offsetof(task_vm_info_data_t, compressed),
         offsetof(task_vm_info_data_t, min_address));
  return 0;
}
''');
      final binary = '${dir.path}/layout';
      final compiled = await Process.run('cc', [source.path, '-o', binary]);
      expect(compiled.exitCode, 0, reason: '${compiled.stderr}');
      final printed = (await Process.run(binary, [])).stdout as String;
      expect(printed, '$taskVmInfoFlavor $taskVmInfoRev1Count 144 120 152');
    }, testOn: 'mac-os');
    test('reads phys_footprint only from a call that filled it', () {
      final memory = calloc<TaskVmInfoRev1>();
      addTearDown(() => calloc.free(memory));
      final info = taskVmInfoWith(memory, 144, 4096);
      expect(darwinFootprintFrom(0, taskVmInfoRev1Count, info), 4096);
      expect(darwinFootprintFrom(0, 93, info), 4096);
      expect(darwinFootprintFrom(5, taskVmInfoRev1Count, info), isNull);
      expect(darwinFootprintFrom(0, taskVmInfoRev1Count - 1, info), isNull);
    });
  });

  group('Windows PROCESS_MEMORY_COUNTERS_EX', () {
    test('matches the <psapi.h> layout', () {
      final word = sizeOf<IntPtr>();
      expect(sizeOf<ProcessMemoryCountersEx>(), 8 + 9 * word);
      final memory = calloc<ProcessMemoryCountersEx>();
      addTearDown(() => calloc.free(memory));
      final bytes = memory.cast<Uint8>();
      final counters = memory.ref;
      counters.cb = 1;
      counters.privateUsage = 0x1234;
      expect(bytes.cast<Uint32>().value, 1);
      final privateUsage = bytes + (8 + 8 * word);
      expect(
        word == 8
            ? privateUsage.cast<Uint64>().value
            : privateUsage.cast<Uint32>().value,
        0x1234,
      );
    });
    test('reads PrivateUsage only from a call that succeeded', () {
      final memory = calloc<ProcessMemoryCountersEx>();
      addTearDown(() => calloc.free(memory));
      memory.ref.privateUsage = 8192;
      expect(windowsFootprintFrom(1, memory.ref), 8192);
      expect(windowsFootprintFrom(0, memory.ref), isNull);
    });
  });

  group('counter selection', () {
    test('names the counter each platform reads', () {
      for (final (os, source, read) in [
        ('macos', darwinFootprintSource, readDarwinFootprint),
        ('ios', darwinFootprintSource, readDarwinFootprint),
        ('linux', linuxFootprintSource, readLinuxFootprint),
        ('android', linuxFootprintSource, readLinuxFootprint),
        ('windows', windowsFootprintSource, readWindowsFootprint),
      ]) {
        final counter = footprintCounterFor(os)!;
        expect(counter.source, source, reason: os);
        expect(identical(counter.read, read), isTrue, reason: os);
      }
      expect(footprintCounterFor('fuchsia'), isNull);
      expect(footprintCounterFor(''), isNull);
    });
    test('a failing, absent or empty counter samples null', () {
      expect(sampleFootprint(null), isNull);
      expect(sampleFootprint(() => throw StateError('no counter')), isNull);
      expect(sampleFootprint(() => null), isNull);
      expect(sampleFootprint(() => 0), isNull);
      expect(sampleFootprint(() => -1), isNull);
      expect(sampleFootprint(() => 1), 1);
    });
  });

  group('this process', () {
    test('reports the counter for this platform', () {
      expect(
        memoryFootprintSource,
        footprintCounterFor(Platform.operatingSystem)!.source,
      );
      expect(memoryFootprintBytes(), isPositive);
    });
    test('counts memory the process dirties', () {
      const size = 256 * mib;
      final before = memoryFootprintBytes()!;
      final memory = malloc<Uint8>(size);
      addTearDown(() => malloc.free(memory));
      memory.asTypedList(size).fillRange(0, size, 1);
      expect(memoryFootprintBytes()! - before, greaterThan(240 * mib));
    });
    test('ignores mapped file pages entering and leaving residency', () async {
      const size = 256 * mib;
      final dir = await Directory.systemTemp.createTemp('footprint');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/pages.bin')
        ..writeAsBytesSync(Uint8List(size)..fillRange(0, size, 7));
      final libc = DynamicLibrary.process();
      final open = libc
          .lookupFunction<
            Int32 Function(Pointer<Utf8>, Int32),
            int Function(Pointer<Utf8>, int)
          >('open');
      final close = libc
          .lookupFunction<Int32 Function(Int32), int Function(int)>('close');
      final mmap = libc
          .lookupFunction<
            Pointer<Uint8> Function(
              Pointer<Void>,
              Size,
              Int32,
              Int32,
              Int32,
              Int64,
            ),
            Pointer<Uint8> Function(Pointer<Void>, int, int, int, int, int)
          >('mmap');
      final munmap = libc
          .lookupFunction<
            Int32 Function(Pointer<Uint8>, Size),
            int Function(Pointer<Uint8>, int)
          >('munmap');
      final path = file.path.toNativeUtf8();
      final fd = open(path, 0);
      malloc.free(path);
      expect(fd, isNonNegative);
      const protRead = 1, mapShared = 1;
      final pages = mmap(nullptr, size, protRead, mapShared, fd, 0);
      close(fd);
      expect(pages.address, isNot(-1));
      addTearDown(() => munmap(pages, size));
      final bytes = pages.asTypedList(size);
      const pageSize = 4096;
      var sum = 0;
      void touch() {
        for (var i = 0; i < size; i += pageSize) {
          sum += bytes[i];
        }
      }

      void evict() {
        final result = Platform.isMacOS
            ? libc.lookupFunction<
                Int32 Function(Pointer<Uint8>, Size, Int32),
                int Function(Pointer<Uint8>, int, int)
              >('msync')(pages, size, 2)
            : libc.lookupFunction<
                Int32 Function(Pointer<Uint8>, Size, Int32),
                int Function(Pointer<Uint8>, int, int)
              >('madvise')(pages, size, 4);
        expect(result, 0);
      }

      final rss = ProcessInfo.currentRss;
      final footprint = memoryFootprintBytes()!;
      touch();
      final touchedRss = ProcessInfo.currentRss;
      final touchedFootprint = memoryFootprintBytes()!;
      evict();
      final evictedRss = ProcessInfo.currentRss;
      final evictedFootprint = memoryFootprintBytes()!;
      expect(sum, size ~/ pageSize * 7);
      expect(touchedRss - rss, greaterThan(200 * mib));
      expect(touchedRss - evictedRss, greaterThan(200 * mib));
      expect((touchedFootprint - footprint).abs(), lessThan(64 * mib));
      expect((evictedFootprint - touchedFootprint).abs(), lessThan(64 * mib));
    }, testOn: 'mac-os || linux');
  });
}
