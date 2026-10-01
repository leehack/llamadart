@TestOn('vm')
library;

import 'dart:ffi';
import 'dart:io';

import 'package:test/test.dart';

import 'package:llamadart/src/backends/stable_diffusion/stable_diffusion_memory.dart';
import 'package:llamadart/src/core/image/image_generation_driver.dart';

/// Whether `MTLCreateSystemDefaultDevice` returns a device, checked apart
/// from the code under test.
bool _hostHasMetalDevice() {
  final metal = DynamicLibrary.open(
    '/System/Library/Frameworks/Metal.framework/Metal',
  );
  final createDevice = metal
      .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
        'MTLCreateSystemDefaultDevice',
      );
  final release =
      DynamicLibrary.open(
        '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation',
      ).lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('CFRelease');
  final device = createDevice();
  if (device == nullptr) {
    return false;
  }
  release(device);
  return true;
}

const _memInfo = '''
MemTotal:        5750000 kB
MemFree:          300000 kB
MemAvailable:    2097152 kB
Buffers:           10000 kB
''';

const _status = '''
Name:	llamadart_chat_example
VmPeak:	  9000000 kB
VmRSS:	   307200 kB
''';

void main() {
  group('parseProcMemoryBytes', () {
    test('reads a kB field in bytes', () {
      expect(parseProcMemoryBytes(_memInfo, 'MemAvailable'), 2097152 * 1024);
      expect(parseProcMemoryBytes(_memInfo, 'MemTotal'), 5750000 * 1024);
      expect(parseProcMemoryBytes(_status, 'VmRSS'), 300 << 20);
    });

    test('is null without the field', () {
      expect(
        parseProcMemoryBytes('MemTotal: 5750000 kB\n', 'MemAvailable'),
        isNull,
      );
      expect(parseProcMemoryBytes('', 'MemAvailable'), isNull);
      expect(parseProcMemoryBytes(_status, 'VmHWM'), isNull);
    });
  });

  group('readStableDiffusionMemoryBudget', () {
    ({int bytes, String source})? read(
      Abi abi, {
      String? memInfo,
      String? status,
      int? ios,
      int? macos,
      int? metal,
      ImageGenerationComputeDevice device = ImageGenerationComputeDevice.cpu,
    }) => readStableDiffusionMemoryBudget(
      device: device,
      abi: abi,
      readMemInfo: () => memInfo,
      readProcessStatus: () => status,
      iosAvailableMemory: () => ios,
      macosPhysicalMemory: () => macos,
      metalRecommendedWorkingSet: () => metal,
    );

    test('uses MemAvailable on Linux', () {
      for (final abi in [Abi.linuxX64, Abi.linuxArm64]) {
        expect(read(abi, memInfo: _memInfo, status: _status, ios: 1), (
          bytes: 2 << 30,
          source: 'MemAvailable in /proc/meminfo',
        ));
        expect(read(abi), isNull, reason: 'unreadable /proc/meminfo');
      }
    });

    group('on Android', () {
      String memInfo({required int totalKib, int? availableKib}) =>
          'MemTotal:       $totalKib kB\n'
          'MemFree:          100000 kB\n'
          '${availableKib == null ? '' : 'MemAvailable:   $availableKib kB\n'}';

      test('uses half of MemTotal less the app when that is larger', () {
        // A 6 GB phone: 5.26 GiB MemTotal, 1.70 GiB MemAvailable, 300 MiB
        // resident.
        expect(
          read(
            Abi.androidArm64,
            memInfo: memInfo(totalKib: 5515000, availableKib: 1782579),
            status: _status,
          ),
          (
            bytes: 5515000 * 1024 ~/ 2 - (300 << 20),
            source:
                "half of MemTotal in /proc/meminfo less the app's resident "
                'memory',
          ),
        );
      });

      test('uses MemAvailable when that is larger', () {
        expect(
          read(
            Abi.androidArm64,
            memInfo: memInfo(totalKib: 15926000, availableKib: 9646000),
            status: _status,
          ),
          (bytes: 9646000 * 1024, source: 'MemAvailable in /proc/meminfo'),
        );
      });

      test('subtracts memory the app already holds', () {
        final budget = read(
          Abi.androidArm64,
          memInfo: memInfo(totalKib: 8 << 20, availableKib: 1 << 20),
          status: 'VmRSS:\t 2097152 kB\n',
        );
        expect(budget?.bytes, 2 << 30);
      });

      test('falls back to MemAvailable without MemTotal or VmRSS', () {
        expect(read(Abi.androidArm64, memInfo: _memInfo), (
          bytes: 2 << 30,
          source: 'MemAvailable in /proc/meminfo',
        ), reason: 'unreadable /proc/self/status');
        expect(
          read(
            Abi.androidArm64,
            memInfo: 'MemAvailable:    2097152 kB\n',
            status: _status,
          ),
          (bytes: 2 << 30, source: 'MemAvailable in /proc/meminfo'),
        );
        expect(read(Abi.androidArm64, status: _status), isNull);
      });

      test('uses half of MemTotal without MemAvailable', () {
        expect(
          read(
            Abi.androidArm64,
            memInfo: memInfo(totalKib: 4 << 20),
            status: _status,
          )?.bytes,
          (2 << 30) - (300 << 20),
        );
      });
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
      if (!Platform.isMacOS) {
        return;
      }
      expect(metal!.bytes, inInclusiveRange(1 << 30, physical!));
      if (_hostHasMetalDevice()) {
        // Apple GPUs recommend less than physical memory, so the cap applies.
        expect(metal.source, "Metal's recommended GPU working set");
        expect(metal.bytes, lessThan(physical));
      }
    }, skip: Platform.isMacOS ? false : 'macOS only');
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
