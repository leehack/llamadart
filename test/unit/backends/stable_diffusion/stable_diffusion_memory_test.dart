@TestOn('vm')
library;

import 'dart:ffi';
import 'dart:io';

import 'package:test/test.dart';

import 'package:llamadart/src/backends/stable_diffusion/stable_diffusion_memory.dart';
import 'package:llamadart/src/core/image/image_generation_driver.dart';

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
      int? metal,
      ImageGenerationComputeDevice device = ImageGenerationComputeDevice.cpu,
    }) => readStableDiffusionMemoryBudget(
      device: device,
      abi: abi,
      readMemInfo: () => memInfo,
      iosAvailableMemory: () => ios,
      macosPhysicalMemory: () => macos,
      metalRecommendedWorkingSet: () => metal,
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

    test("caps Metal on macOS at the GPU's recommended working set", () {
      expect(
        read(
          Abi.macosArm64,
          macos: 16 << 30,
          metal: 11 << 30,
          device: ImageGenerationComputeDevice.metal,
        ),
        (bytes: 11 << 30, source: "Metal's recommended GPU working set"),
      );
      for (final metal in [null, 0, 20 << 30]) {
        expect(
          read(
            Abi.macosArm64,
            macos: 16 << 30,
            metal: metal,
            device: ImageGenerationComputeDevice.metal,
          ),
          (bytes: 16 << 30, source: 'physical memory'),
          reason: 'working set $metal',
        );
      }
      expect(
        read(
          Abi.macosArm64,
          macos: 16 << 30,
          metal: 11 << 30,
          device: ImageGenerationComputeDevice.cpu,
        ),
        (bytes: 16 << 30, source: 'physical memory'),
      );
      expect(
        read(
          Abi.iosArm64,
          ios: 3 << 30,
          metal: 1 << 30,
          device: ImageGenerationComputeDevice.metal,
        ),
        (bytes: 3 << 30, source: "the app's remaining iOS memory limit"),
      );
    });

    test('reports nothing for GPUs whose device memory is unknown', () {
      for (final abi in [Abi.linuxX64, Abi.macosArm64, Abi.windowsX64]) {
        expect(
          read(
            abi,
            memInfo: _memInfo,
            macos: 64 << 30,
            metal: 48 << 30,
            device: ImageGenerationComputeDevice.otherGpu,
          ),
          isNull,
        );
      }
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

    test("reads the host Metal device's working set on macOS", () {
      final physical = readStableDiffusionMemoryBudget()?.bytes;
      final metal = readStableDiffusionMemoryBudget(
        device: ImageGenerationComputeDevice.metal,
      );
      if (Platform.isMacOS) {
        expect(metal!.bytes, inInclusiveRange(1 << 30, physical!));
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
