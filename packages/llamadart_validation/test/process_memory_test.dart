import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
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
    /// The last round the probe printed, and its whole output.
    Future<(List<Map<String, dynamic>>, Map<String, dynamic>)> probe(
      List<String> args,
    ) async {
      final result = await Process.run(Platform.resolvedExecutable, [
        '--packages=${(await Isolate.packageConfig)!.toFilePath()}',
        'test/fixtures/process_memory_probe.dart',
        ...args,
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      final output =
          jsonDecode(result.stdout as String) as Map<String, dynamic>;
      final rounds = output['rounds'] as List;
      return ((rounds.last as List).cast<Map<String, dynamic>>(), output);
    }

    test('reports the counter for this platform', () {
      expect(
        memoryFootprintSource,
        footprintCounterFor(Platform.operatingSystem)!.source,
      );
      expect(memoryFootprintBytes(), isPositive);
    });
    test('counts memory it dirties', () async {
      const size = 256 * mib;
      final ([before, after], output) = await probe(['dirty', '$size']);
      expect(
        after['footprint'] - before['footprint'],
        greaterThan(240 * mib),
        reason: '$output',
      );
    });
    test('ignores mapped file pages entering and leaving residency', () async {
      const size = 256 * mib;
      final dir = await Directory.systemTemp.createTemp('footprint');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/pages.bin')
        ..writeAsBytesSync(Uint8List(size)..fillRange(0, size, 7));
      final ([before, touched, evicted], output) = await probe([
        'mapped',
        file.path,
      ]);
      final reason = '$output';
      expect(output['sum'], size ~/ 4096 * 7);
      expect(
        touched['rss'] - before['rss'],
        greaterThan(200 * mib),
        reason: reason,
      );
      expect(
        touched['rss'] - evicted['rss'],
        greaterThan(200 * mib),
        reason: reason,
      );
      expect(
        (touched['footprint'] - before['footprint']).abs(),
        lessThan(64 * mib),
        reason: reason,
      );
      expect(
        (evicted['footprint'] - touched['footprint']).abs(),
        lessThan(64 * mib),
        reason: reason,
      );
    }, testOn: 'mac-os || linux');
  });
}
