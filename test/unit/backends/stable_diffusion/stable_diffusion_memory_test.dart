@TestOn('vm')
library;

import 'dart:ffi';
import 'dart:io';

import 'package:test/test.dart';

import 'package:llamadart/src/backends/stable_diffusion/stable_diffusion_memory.dart';

const _memInfo = '''
MemTotal:        5750000 kB
MemFree:          300000 kB
MemAvailable:    2097152 kB
Buffers:           10000 kB
''';

void main() {
  group('parseMemAvailableBytes', () {
    test('reads MemAvailable in bytes', () {
      expect(parseMemAvailableBytes(_memInfo), 2097152 * 1024);
    });

    test('is null without a MemAvailable line', () {
      expect(parseMemAvailableBytes('MemTotal: 5750000 kB\n'), isNull);
      expect(parseMemAvailableBytes(''), isNull);
    });
  });

  group('readStableDiffusionMemoryBudget', () {
    ({int bytes, String source})? read(
      Abi abi, {
      String? memInfo,
      int? ios,
      int? macos,
    }) => readStableDiffusionMemoryBudget(
      abi: abi,
      readMemInfo: () => memInfo,
      iosAvailableMemory: () => ios,
      macosPhysicalMemory: () => macos,
    );

    test('uses MemAvailable on Android and Linux', () {
      for (final abi in [Abi.androidArm64, Abi.linuxX64, Abi.linuxArm64]) {
        expect(read(abi, memInfo: _memInfo, ios: 1, macos: 1), (
          bytes: 2 << 30,
          source: 'MemAvailable in /proc/meminfo',
        ));
        expect(read(abi), isNull, reason: 'unreadable /proc/meminfo');
      }
    });

    test("uses the app's remaining memory limit on iOS", () {
      expect(read(Abi.iosArm64, memInfo: _memInfo, ios: 3 << 30, macos: 1), (
        bytes: 3 << 30,
        source: "the app's remaining iOS memory limit",
      ));
      expect(read(Abi.iosArm64, ios: 0), isNull);
    });

    test('uses physical memory on macOS', () {
      expect(read(Abi.macosArm64, ios: 1, macos: 64 << 30), (
        bytes: 64 << 30,
        source: 'physical memory',
      ));
    });

    test('reports nothing on Windows', () {
      expect(read(Abi.windowsX64, memInfo: _memInfo, ios: 1, macos: 1), isNull);
    });

    test('reads the host', () {
      final budget = readStableDiffusionMemoryBudget();
      if (Platform.isMacOS || Platform.isLinux) {
        expect(budget!.bytes, greaterThan(1 << 30));
      }
    });
  });

  group('stableDiffusionFileSize', () {
    test('sizes a file and ignores directories and missing paths', () async {
      final directory = await Directory.systemTemp.createTemp('llamadart-sd-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/taesd.safetensors')
        ..writeAsBytesSync(List.filled(42, 1));

      expect(stableDiffusionFileSize(file.path), 42);
      expect(stableDiffusionFileSize(directory.path), isNull);
      expect(stableDiffusionFileSize('${file.path}.missing'), isNull);
    });
  });
}
