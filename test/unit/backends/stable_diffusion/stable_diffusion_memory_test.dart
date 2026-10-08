@TestOn('vm')
library;

import 'dart:ffi';
import 'dart:io';

import 'package:test/test.dart';

import 'package:llamadart/src/backends/stable_diffusion/stable_diffusion_memory.dart';
import 'package:llamadart/src/core/image/image_generation_driver.dart';
import 'package:llamadart/src/core/models/config/log_level.dart';

import '../../../support/fake_stable_diffusion_runtime.dart';

const _gib = 1 << 30;

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
        // in the app.
        expect(
          read(
            Abi.androidArm64,
            memInfo: memInfo(totalKib: 5515000, availableKib: 1782579),
            status: _status,
          ),
          (
            bytes: 5515000 * 1024 ~/ 2 - (300 << 20),
            source: "half of MemTotal in /proc/meminfo less the app's memory",
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

      test('subtracts memory the app already holds, swapped or not', () {
        int? budget(String status) => read(
          Abi.androidArm64,
          memInfo: memInfo(totalKib: 8 << 20, availableKib: 1 << 20),
          status: status,
        )?.bytes;
        expect(budget('VmRSS:\t 2097152 kB\n'), 2 << 30);
        expect(budget('VmRSS:\t 1048576 kB\nVmSwap:\t 1048576 kB\n'), 2 << 30);
      });

      test("reads the app's memory from /proc/self/status by default", () {
        final budget = readStableDiffusionMemoryBudget(
          abi: Abi.androidArm64,
          readMemInfo: () => 'MemTotal:  1073741824 kB\nMemAvailable:  1 kB\n',
        );
        final status = File('/proc/self/status').readAsStringSync();
        final own =
            parseProcMemoryBytes(status, 'VmRSS')! +
            (parseProcMemoryBytes(status, 'VmSwap') ?? 0);
        expect(
          budget?.source,
          "half of MemTotal in /proc/meminfo less the app's memory",
        );
        // The process grows a little between the two reads.
        expect(budget!.bytes, closeTo((1 << 39) - own, 64 << 20));
      }, testOn: 'linux');

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

  group('readStableDiffusionGpuMemory', () {
    late FakeStableDiffusionRuntime runtime;

    setUp(() => runtime = FakeStableDiffusionRuntime());

    tearDown(() => runtime.close());

    StableDiffusionGpuMemory? read({
      LlamaLogLevel logLevel = LlamaLogLevel.none,
      String? vulkanDevice,
    }) => readStableDiffusionGpuMemory(
      resolveCalls: runtime.resolver,
      logLevel: logLevel,
      environment: (name) => name == 'SD_VK_DEVICE' ? vulkanDevice : null,
    );

    test('asks the default device, after the recorder is registered at the '
        'log level', () async {
      runtime.setGpuMemory(total: 24 * _gib, free: 21 * _gib);

      final memory = read(logLevel: LlamaLogLevel.warn);
      await runtime.flush();

      expect(memory, (
        name: 'Vulkan0 (Fake GPU)',
        totalBytes: 24 * _gib,
        freeBytes: 21 * _gib,
        integrated: false,
      ));
      expect(runtime.calls('caller'), [
        'sd_dart_log_enable',
        'sd_dart_log_set_level:3',
        'sd_dart_gpu_device_memory:-1',
      ]);
    });

    test('reports an integrated GPU as one', () {
      runtime.setGpuMemory(total: 16 * _gib, free: 12 * _gib, integrated: true);

      expect(read()?.integrated, isTrue);
    });

    test('is null for every status but OK: no backend, no device, memory '
        'unavailable, an invalid argument', () {
      for (final status in [-1, -2, -3, -4]) {
        runtime.setGpuMemory(status: status, total: 8 * _gib, free: _gib);

        expect(read(), isNull, reason: '$status');
      }
    });

    test('a runtime older than the query is not asked', () async {
      runtime
        ..olderRelease = true
        ..setGpuMemory(total: 8 * _gib, free: _gib);

      expect(read(), isNull);
      await runtime.flush();
      expect(runtime.calls('caller'), isEmpty);
    });

    test('is null without a runtime', () {
      expect(readStableDiffusionGpuMemory(resolveCalls: () => null), isNull);
    });

    test('SD_VK_DEVICE, which makes the runtime pick the device, skips the '
        'query', () async {
      runtime.setGpuMemory(total: 8 * _gib, free: _gib);

      expect(read(vulkanDevice: '1'), isNull);
      await runtime.flush();
      expect(runtime.calls('caller'), isEmpty);
      expect(read(), isNotNull);
    });
  });

  group('stableDiffusionGpuMemoryBudget', () {
    const host = (bytes: 5 * _gib, source: 'MemAvailable in /proc/meminfo');

    ImageGenerationMemoryBudget? budget(
      StableDiffusionGpuMemory? memory, {
      ImageGenerationMemoryBudget? hostBudget = host,
    }) => stableDiffusionGpuMemoryBudget(memory, hostBudget: () => hostBudget);

    StableDiffusionGpuMemory gpu({
      required int total,
      required int free,
      bool integrated = false,
    }) => (
      name: 'Vulkan0 (NVIDIA L4)',
      totalBytes: total,
      freeBytes: free,
      integrated: integrated,
    );

    test('a discrete GPU whose driver reports a budget gives its free '
        'memory', () {
      expect(budget(gpu(total: 24 * _gib, free: 9 * _gib)), (
        bytes: 9 * _gib,
        source: 'free GPU memory of Vulkan0 (NVIDIA L4), out of 24.0 GiB',
      ));
      expect(
        budget(gpu(total: 8 * _gib, free: 8 * _gib - 1))?.bytes,
        8 * _gib - 1,
      );
      expect(budget(gpu(total: 8 * _gib, free: 1))?.bytes, 1);
    });

    test('a discrete GPU that reports its total as free, or nothing as free, '
        'gives its total memory and says that free memory is unknown', () {
      for (final free in [8 * _gib, 0]) {
        expect(budget(gpu(total: 8 * _gib, free: free)), (
          bytes: 8 * _gib,
          source:
              'the GPU memory of Vulkan0 (NVIDIA L4), whose driver does not '
              'report how much of it is free',
        ), reason: '$free');
      }
    });

    test('an integrated GPU gives the host figure, never its own', () {
      for (final (total, free) in [(64 * _gib, 60 * _gib), (2 * _gib, _gib)]) {
        expect(budget(gpu(total: total, free: free, integrated: true)), (
          bytes: 5 * _gib,
          source:
              'MemAvailable in /proc/meminfo; Vulkan0 (NVIDIA L4) is an '
              'integrated GPU, which uses host memory',
        ));
      }
    });

    test('an integrated GPU has no budget where host memory is not read', () {
      expect(
        budget(
          gpu(total: 16 * _gib, free: 8 * _gib, integrated: true),
          hostBudget: null,
        ),
        isNull,
      );
    });

    test('unknown memory has no budget, and the host is not asked for a '
        'discrete GPU', () {
      ImageGenerationMemoryBudget? unasked() => fail('asked the host');

      expect(budget(null), isNull);
      expect(budget(gpu(total: 0, free: 0)), isNull);
      expect(
        stableDiffusionGpuMemoryBudget(
          gpu(total: 8 * _gib, free: _gib),
          hostBudget: unasked,
        )?.bytes,
        _gib,
      );
    });
  });

  test('readStableDiffusionFileRange reads a range and stops at the end of '
      'the file', () async {
    final directory = await Directory.systemTemp.createTemp('llamadart-sd-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/header.gguf')
      ..writeAsBytesSync(List.generate(10, (i) => i));

    expect(await readStableDiffusionFileRange(file.path, 2, 3), [2, 3, 4]);
    expect(await readStableDiffusionFileRange(file.path, 8, 64), [8, 9]);
    expect(await readStableDiffusionFileRange(file.path, 20, 4), isEmpty);
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

    test('sizes a file whose path holds %, # and ? literally', () async {
      final directory = await Directory.systemTemp.createTemp('llamadart-sd-');
      addTearDown(() => directory.delete(recursive: true));
      final name = Platform.isWindows ? 'a#b%zz%25' : 'a#b?c%zz%25';
      final file = File('${directory.path}/100% $name/sd 100%.gguf')
        ..createSync(recursive: true)
        ..writeAsBytesSync(List.filled(7, 1));

      expect(stableDiffusionFileSize(file.path), 7);
    });
  });
}
