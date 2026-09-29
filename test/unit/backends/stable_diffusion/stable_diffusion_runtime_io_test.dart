@TestOn('vm')
library;

import 'dart:ffi';

import 'package:test/test.dart';

import 'package:llamadart/src/backends/stable_diffusion/stable_diffusion_runtime_io.dart';
import 'package:llamadart/src/core/exceptions.dart';

const _dotProductCpuInfo = 'Features\t: fp asimd atomics asimddp\n';

void main() {
  group('probeStableDiffusionRuntime', () {
    test('reports version, commit and devices from a loaded runtime', () {
      final status = probeStableDiffusionRuntime(
        abi: Abi.macosArm64,
        api: _FakeApi(devices: 'CPU\tApple M4\nMTL0\tApple M4\n'),
      );

      expect(status.isAvailable, isTrue);
      expect(status.version, 'v-test');
      expect(status.commit, 'c0ffee');
      expect(status.devices.map((device) => device.name), ['CPU', 'MTL0']);
    });

    test('rejects an unpublished ABI before touching the library', () {
      for (final abi in [Abi.androidX64, Abi.windowsArm64, Abi.iosX64]) {
        final api = _FakeApi();
        final status = probeStableDiffusionRuntime(abi: abi, api: api);

        expect(api.calls, 0, reason: '$abi');
        expect(
          status.unavailableReason?.message,
          allOf(
            contains('stable_diffusion runtime is not published for'),
            contains(abi.toString().replaceAll('_', '-')),
          ),
        );
      }
    });

    test('Android arm64 without asimddp never loads the library', () {
      for (final cpuInfo in [
        'Features\t: fp asimd atomics\n',
        '${_dotProductCpuInfo}Features\t: fp asimd\n',
        null,
      ]) {
        final api = _FakeApi();
        final status = probeStableDiffusionRuntime(
          abi: Abi.androidArm64,
          readCpuInfo: () => cpuInfo,
          api: api,
        );

        expect(api.calls, 0, reason: cpuInfo);
        expect(
          status.unavailableReason?.message,
          allOf(
            contains('android-arm64'),
            contains('Armv8.2 dot-product (asimddp)'),
          ),
          reason: cpuInfo,
        );
      }
    });

    test('Android arm64 with asimddp on every core loads the library', () {
      final api = _FakeApi();
      final status = probeStableDiffusionRuntime(
        abi: Abi.androidArm64,
        readCpuInfo: () => _dotProductCpuInfo * 8,
        api: api,
      );

      expect(status.isAvailable, isTrue);
      expect(api.calls, greaterThan(0));
    });

    test('desktop probes ignore /proc/cpuinfo', () {
      final status = probeStableDiffusionRuntime(
        abi: Abi.linuxArm64,
        readCpuInfo: () => fail('cpuinfo is only read on Android'),
        api: _FakeApi(),
      );

      expect(status.isAvailable, isTrue);
    });

    test('a missing native asset reports how to opt in', () {
      final status = probeStableDiffusionRuntime(
        abi: Abi.linuxX64,
        api: _FakeApi(
          error: ArgumentError(
            "Couldn't resolve native function 'sd_version' in "
            "'package:llamadart/stable_diffusion' : No asset with id "
            "'package:llamadart/stable_diffusion' found. Available native "
            'assets: package:llamadart/llamadart. Attempted to fallback to '
            'process lookup. dlsym(RTLD_DEFAULT, sd_version): symbol not '
            'found.',
          ),
        ),
      );

      expect(
        status.unavailableReason,
        isA<LlamaUnsupportedException>().having(
          (error) => error.message,
          'message',
          allOf(
            contains('stable_diffusion runtime is not bundled for linux-x64'),
            contains('llamadart_native_runtimes'),
          ),
        ),
      );
    });
  });

  group('stableDiffusionLoadFailure', () {
    String messageFor(String detail) => stableDiffusionLoadFailure(
      platform: 'linux-x64',
      error: ArgumentError(detail),
    ).message;

    test('names the Vulkan loader when the Vulkan variant cannot load', () {
      final message = messageFor(
        "Couldn't resolve native function 'sd_version' in "
        "'package:llamadart/stable_diffusion' : Failed to load dynamic "
        "library '/app/lib/libstable-diffusion.so': libvulkan.so.1: cannot "
        'open shared object file: No such file or directory',
      );

      expect(message, contains('Vulkan variant'));
      expect(message, contains('libvulkan.so.1'));
      expect(message, contains('select the CPU backend'));
      expect(message, isNot(contains('/app/lib')));
    });

    test('reports a symbol missing from a mismatched runtime', () {
      final message = messageFor(
        "Couldn't resolve native function 'sd_list_devices' in "
        "'package:llamadart/stable_diffusion' : Failed to lookup symbol "
        "'sd_list_devices': undefined symbol: sd_list_devices",
      );

      expect(message, contains('does not export the stable-diffusion.h API'));
    });

    test('keeps the first line of any other loader failure', () {
      final message = messageFor('dlopen failed: bad ELF magic\nsecond line');

      expect(
        message,
        'stable_diffusion runtime could not be loaded on linux-x64: '
        'dlopen failed: bad ELF magic',
      );
    });
  });
}

final class _FakeApi implements StableDiffusionNativeApi {
  _FakeApi({this.devices = 'CPU\tHost CPU\n', this.error});

  final String devices;
  final ArgumentError? error;
  int calls = 0;

  T _call<T>(T value) {
    calls++;
    final failure = error;
    if (failure != null) {
      throw failure;
    }
    return value;
  }

  @override
  String version() => _call('v-test');

  @override
  String commit() => _call('c0ffee');

  @override
  String listDevices() => _call(devices);
}
