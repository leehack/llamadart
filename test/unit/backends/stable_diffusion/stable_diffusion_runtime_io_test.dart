@TestOn('vm')
library;

import 'dart:ffi';
import 'dart:io';

import 'package:test/test.dart';

import 'package:llamadart/src/backends/stable_diffusion/stable_diffusion_runtime_io.dart';
import 'package:llamadart/src/core/exceptions.dart';

const _dotProductCpuInfo =
    'Features\t: fp asimd atomics fphp asimdhp asimddp\n';
const _haswellCpuInfo = 'flags\t\t: fpu sse4_2 avx f16c fma avx2 bmi2\n';

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
      for (final abi in [Abi.androidX64, Abi.windowsArm64, Abi.linuxArm]) {
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
            contains('Armv8.2 dot-product and fp16 (asimddp, fphp, asimdhp)'),
          ),
          reason: cpuInfo,
        );
      }
    });

    test('Android arm64 with the required features on every core loads the '
        'library', () {
      final api = _FakeApi();
      final status = probeStableDiffusionRuntime(
        abi: Abi.androidArm64,
        readCpuInfo: () => _dotProductCpuInfo * 8,
        api: api,
      );

      expect(status.isAvailable, isTrue);
      expect(api.calls, greaterThan(0));
    });

    test('Arm desktop and Apple probes check no CPU features', () {
      for (final abi in [Abi.linuxArm64, Abi.macosArm64, Abi.macosX64]) {
        final status = probeStableDiffusionRuntime(
          abi: abi,
          readCpuInfo: () => fail('cpuinfo is not read on $abi'),
          windowsHasAvx2: () => fail('Windows is not queried on $abi'),
          api: _FakeApi(),
        );

        expect(status.isAvailable, isTrue, reason: '$abi');
      }
    });

    test('Linux x64 without AVX2, FMA, F16C or BMI2 never loads the '
        'library', () {
      for (final cpuInfo in [
        'flags\t\t: fpu sse4_2 avx popcnt\n',
        '$_haswellCpuInfo${'flags\t\t: fpu sse4_2 avx avx2\n'}',
        null,
      ]) {
        final api = _FakeApi();
        final status = probeStableDiffusionRuntime(
          abi: Abi.linuxX64,
          readCpuInfo: () => cpuInfo,
          api: api,
        );

        expect(api.calls, 0, reason: cpuInfo);
        expect(
          status.unavailableReason?.message,
          allOf(
            contains('linux-x64'),
            contains('AVX2, FMA, F16C, BMI2'),
            cpuInfo == null
                ? contains('could not be read')
                : contains('does not report them'),
          ),
          reason: cpuInfo,
        );
      }
    });

    test('Linux x64 with the required features on every core loads the '
        'library', () {
      final api = _FakeApi();
      final status = probeStableDiffusionRuntime(
        abi: Abi.linuxX64,
        readCpuInfo: () => _haswellCpuInfo * 8,
        api: api,
      );

      expect(status.isAvailable, isTrue);
      expect(api.calls, greaterThan(0));
    });

    test('Windows x64 requires AVX2 before loading the library', () {
      final api = _FakeApi();
      final rejected = probeStableDiffusionRuntime(
        abi: Abi.windowsX64,
        readCpuInfo: () => fail('cpuinfo is not read on Windows'),
        windowsHasAvx2: () => false,
        api: api,
      );

      expect(api.calls, 0);
      expect(
        rejected.unavailableReason?.message,
        allOf(contains('windows-x64'), contains('does not report AVX2')),
      );

      final accepted = probeStableDiffusionRuntime(
        abi: Abi.windowsX64,
        windowsHasAvx2: () => true,
        api: api,
      );
      expect(accepted.isAvailable, isTrue);
    });

    test('the x86_64 iOS simulator loads without a CPU feature check', () {
      final api = _FakeApi();
      final status = probeStableDiffusionRuntime(abi: Abi.iosX64, api: api);

      expect(status.isAvailable, isTrue);
      expect(api.calls, greaterThan(0));
    });

    test('a missing native asset reports how to opt in', () {
      final status = probeStableDiffusionRuntime(
        abi: Abi.linuxX64,
        readCpuInfo: () => _haswellCpuInfo,
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
      expect(message, contains('llamadart_stable_diffusion_backends to [cpu]'));
      expect(message, isNot(contains('/app/lib')));
    });

    test('a missing asset beside llama.cpp Vulkan assets is not a loader '
        'failure', () {
      // Default Linux and Windows builds bundle llama.cpp's ggml-vulkan, and
      // the VM lists every bundled asset in the missing-asset message.
      final message = messageFor(
        "Couldn't resolve native function 'sd_version' in "
        "'package:llamadart/stable_diffusion' : No asset with id "
        "'package:llamadart/stable_diffusion' found. Available native "
        'assets: package:llamadart/llamadart, package:llamadart/ggml-base, '
        'package:llamadart/ggml-cpu, package:llamadart/ggml-vulkan. Attempted '
        'to fallback to process lookup.',
      );

      expect(message, contains('not bundled for linux-x64'));
      expect(message, isNot(contains('Vulkan variant')));
    });

    test('a path containing "vulkan" is not a loader failure', () {
      final message = messageFor(
        "Couldn't resolve native function 'sd_version' in "
        "'package:llamadart/stable_diffusion' : Failed to load dynamic "
        "library '/opt/vulkan-demo/lib/libstable-diffusion.so': "
        'libstdc++.so.6: cannot open shared object file',
      );

      expect(message, isNot(contains('Vulkan variant')));
      expect(message, contains('could not be loaded on linux-x64'));
    });

    test('reports a symbol missing from a mismatched runtime', () {
      final message = messageFor(
        "Couldn't resolve native function 'sd_list_devices' in "
        "'package:llamadart/stable_diffusion' : Failed to lookup symbol "
        "'sd_list_devices': undefined symbol: sd_list_devices",
      );

      expect(message, contains('does not export the stable-diffusion.h API'));
    });

    test('names the Flutter Apple companion only on iOS and macOS', () {
      const missingAsset =
          "Couldn't resolve native function 'sd_version' in "
          "'package:llamadart/stable_diffusion' : No asset with id "
          "'package:llamadart/stable_diffusion' found.";
      for (final platform in ['ios-arm64', 'macos-x64']) {
        final message = stableDiffusionLoadFailure(
          platform: platform,
          error: ArgumentError(missingAsset),
        ).message;
        expect(
          message,
          allOf(
            contains('not bundled for $platform'),
            contains('llamadart_native_runtimes'),
            contains('llamadart_stable_diffusion_flutter'),
          ),
          reason: platform,
        );
      }
      expect(
        messageFor(missingAsset),
        isNot(contains('llamadart_stable_diffusion_flutter')),
      );
    });

    test('an unlinked Apple framework points at Swift Package Manager', () {
      final message = stableDiffusionLoadFailure(
        platform: 'ios-arm64',
        error: ArgumentError(
          "Couldn't resolve native function 'sd_version' in "
          "'package:llamadart/stable_diffusion' : Failed to lookup symbol "
          "'sd_version': dlsym(RTLD_DEFAULT, sd_version): symbol not found",
        ),
      ).message;

      expect(
        message,
        allOf(
          contains('not linked into the process on ios-arm64'),
          contains('flutter config --enable-swift-package-manager'),
          contains('llamadart_stable_diffusion_flutter'),
        ),
      );
    });

    group('Windows error 126', () {
      final error126 = ArgumentError(
        "Couldn't resolve native function 'sd_version' in "
        "'package:llamadart/stable_diffusion' : Failed to load dynamic "
        "library 'stable-diffusion.dll': The specified module could not be "
        'found.\r\n (error code: 126).\n',
      );

      String messageWithMissing(Set<String> missing) {
        final checked = <String>[];
        final message = stableDiffusionLoadFailure(
          platform: 'windows-x64',
          error: error126,
          missingWindowsLibraries: (names) {
            checked.addAll(names);
            return [
              for (final name in names)
                if (missing.contains(name)) name,
            ];
          },
        ).message;
        expect(checked, isNotEmpty);
        return message;
      }

      test('names a missing Visual C++ runtime before the Vulkan loader', () {
        final message = messageWithMissing({'msvcp140.dll', 'vulkan-1.dll'});

        expect(message, contains('could not be loaded on windows-x64'));
        expect(
          message,
          contains('latest Microsoft Visual C++ v14 Redistributable (x64)'),
        );
        expect(message, contains('msvcp140.dll could not be loaded'));
        expect(message, isNot(contains('vulkan-1.dll')));
        expect(message, isNot(contains('..')));
      });

      test('names the Vulkan loader when the runtime is present', () {
        final message = messageWithMissing({'vulkan-1.dll'});

        expect(message, contains('vulkan-1.dll could not be loaded'));
        expect(
          message,
          contains('llamadart_stable_diffusion_backends to [cpu]'),
        );
        expect(message, isNot(contains('Visual C++')));
        expect(message, isNot(contains('..')));
      });

      test(
        'the default check probes every Visual C++ DLL the runtime imports',
        () {
          // Off Windows none of these load, so the real check must report all
          // of them: this pins the list against stable-diffusion.dll's PE
          // imports (MSVCP140, MSVCP140_CODECVT_IDS, VCRUNTIME140,
          // VCRUNTIME140_1).
          final message = stableDiffusionLoadFailure(
            platform: 'windows-x64',
            error: error126,
          ).message;

          expect(
            message,
            contains(
              'msvcp140.dll, msvcp140_codecvt_ids.dll, vcruntime140.dll, '
              'vcruntime140_1.dll could not be loaded',
            ),
          );
          expect(message, contains('could not be found. It requires'));
        },
        skip: Platform.isWindows
            ? 'the Visual C++ runtime loads on Windows hosts'
            : false,
      );

      test('recognizes error 126 without an English system message', () {
        final message = stableDiffusionLoadFailure(
          platform: 'windows-x64',
          error: ArgumentError(
            "Couldn't resolve native function 'sd_version' in "
            "'package:llamadart/stable_diffusion' : Failed to load dynamic "
            "library 'stable-diffusion.dll': error code 126",
          ),
          missingWindowsLibraries: (names) =>
              names.contains('msvcp140.dll') ? ['msvcp140.dll'] : const [],
        ).message;

        expect(message, contains("'stable-diffusion.dll': error code 126."));
        expect(message, contains('msvcp140.dll could not be loaded'));
      });

      test('does not treat error 1260 as error 126', () {
        final checked = <String>[];
        final message = stableDiffusionLoadFailure(
          platform: 'windows-x64',
          error: ArgumentError(
            "Failed to load dynamic library 'stable-diffusion.dll': This "
            'program is blocked by group policy.\r\n (error code: 1260).\n',
          ),
          missingWindowsLibraries: (names) {
            checked.addAll(names);
            return names;
          },
        ).message;

        expect(checked, isEmpty);
        expect(message, isNot(contains('Visual C++')));
      });

      test('says neither dependency is missing when both load', () {
        final message = messageWithMissing(const {});

        expect(message, contains('does not name the missing dependency'));
        expect(message, isNot(contains('install')));
      });
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
