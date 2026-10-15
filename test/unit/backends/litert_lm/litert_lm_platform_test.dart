@TestOn('vm')
library;

import 'dart:ffi';
import 'dart:io';

import 'package:llamadart/src/backends/litert_lm/litert_lm_platform.dart';
import 'package:llamadart/src/backends/litert_lm/litert_lm_runtime.dart';
import 'package:llamadart/src/core/exceptions.dart';
import 'package:test/test.dart';

void main() {
  test('desktop GPU qualification is restricted to x64 Linux and Windows', () {
    for (final abi in Abi.values) {
      expect(
        liteRtLmDesktopGpuSupportedForAbi(abi),
        abi == Abi.linuxX64 || abi == Abi.windowsX64,
        reason: '$abi must retain its independently qualified support boundary',
      );
    }
    expect(liteRtLmDesktopGpuSupportedForAbi(Abi.linuxArm64), isFalse);
    expect(liteRtLmDesktopGpuSupportedForAbi(Abi.windowsArm64), isFalse);
  });

  test('normalizes native backend overrides', () {
    expect(normalizeLiteRtLmNativeBackendOverride(null), isNull);
    expect(normalizeLiteRtLmNativeBackendOverride(''), isNull);
    expect(normalizeLiteRtLmNativeBackendOverride(' GPU '), liteRtLmGpuBackend);
    expect(normalizeLiteRtLmNativeBackendOverride('npu'), liteRtLmNpuBackend);
    expect(
      () => normalizeLiteRtLmNativeBackendOverride('directml'),
      throwsA(
        isA<ArgumentError>().having(
          (error) => error.message,
          'message',
          contains('must be cpu, gpu, or npu'),
        ),
      ),
    );
  });

  test('reports current native platform backend defaults', () {
    final available = liteRtLmAvailableNativeBackendsForCurrentPlatform();

    if (Platform.isAndroid) {
      expect(available, const <String>[
        liteRtLmCpuBackend,
        liteRtLmGpuBackend,
        liteRtLmNpuBackend,
      ]);
      expect(liteRtLmDefaultNativeBackendForCurrentPlatform(), 'gpu');
      expect(liteRtLmNativeGpuSupportedOnCurrentPlatform(), isTrue);
      return;
    }

    if (Platform.isIOS || liteRtLmGateAbi() == Abi.macosArm64) {
      expect(available, const <String>[liteRtLmCpuBackend, liteRtLmGpuBackend]);
      expect(liteRtLmDefaultNativeBackendForCurrentPlatform(), 'gpu');
      expect(liteRtLmNativeGpuSupportedOnCurrentPlatform(), isTrue);
      return;
    }

    if (Abi.current() == Abi.linuxX64 || Abi.current() == Abi.windowsX64) {
      expect(available, const <String>[liteRtLmCpuBackend, liteRtLmGpuBackend]);
      expect(liteRtLmDefaultNativeBackendForCurrentPlatform(), 'cpu');
      expect(liteRtLmNativeGpuSupportedOnCurrentPlatform(), isTrue);
      return;
    }

    expect(available, const <String>[liteRtLmCpuBackend]);
    expect(liteRtLmDefaultNativeBackendForCurrentPlatform(), 'cpu');
    expect(liteRtLmNativeGpuSupportedOnCurrentPlatform(), isFalse);
  });

  group('macOS ABI backend defaults', () {
    void runOn(Abi abi) {
      debugLiteRtLmAbiOverride = abi;
      addTearDown(() => debugLiteRtLmAbiOverride = null);
    }

    final macOsX64Gpu = throwsA(
      isA<LlamaUnsupportedException>().having(
        (error) => error.message,
        'message',
        allOf(
          contains('LiteRT-LM GPU is not available on macOS x86_64'),
          contains('leehack/litert-lm-native#72'),
          contains('not under Rosetta'),
          contains('llama.cpp backend'),
        ),
      ),
    );

    test('macOS arm64 defaults to GPU and accepts a GPU request', () {
      runOn(Abi.macosArm64);

      expect(liteRtLmDefaultNativeBackendForCurrentPlatform(), 'gpu');
      expect(liteRtLmNativeGpuSupportedOnCurrentPlatform(), isTrue);
      expect(liteRtLmAvailableNativeBackendsForCurrentPlatform(), const [
        liteRtLmCpuBackend,
        liteRtLmGpuBackend,
      ]);
      expect(
        () => liteRtLmEnsureNativeBackendSupported('gpu'),
        returnsNormally,
      );
    });

    test('macOS x86_64 defaults to CPU and rejects a GPU request', () {
      runOn(Abi.macosX64);

      expect(liteRtLmDefaultNativeBackendForCurrentPlatform(), 'cpu');
      expect(liteRtLmNativeGpuSupportedOnCurrentPlatform(), isFalse);
      expect(liteRtLmAvailableNativeBackendsForCurrentPlatform(), const [
        liteRtLmCpuBackend,
      ]);
      expect(() => liteRtLmEnsureNativeBackendSupported('gpu'), macOsX64Gpu);
      expect(
        () => liteRtLmEnsureNativeBackendSupported('cpu'),
        returnsNormally,
      );
    });

    test('other ABIs keep their unavailable-backend handling', () {
      for (final abi in Abi.values.where((abi) => abi != Abi.macosX64)) {
        runOn(abi);
        for (final backend in const ['cpu', 'gpu', 'npu']) {
          expect(
            () => liteRtLmEnsureNativeBackendSupported(backend),
            returnsNormally,
            reason: '$abi $backend',
          );
        }
      }
    });
  });
}
