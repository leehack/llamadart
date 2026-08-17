@TestOn('vm')
library;

import 'package:test/test.dart';

import 'package:llamadart/src/backends/llama_cpp/windows_cuda_selector.dart';

void main() {
  test('recognizes only versioned CUDA sidecar backend names', () {
    expect(windowsCudaMajorFromFileName('ggml-cuda-12.dll'), 12);
    expect(windowsCudaMajorFromFileName('ggml-cuda-13-windows-x64.dll'), 13);
    expect(windowsCudaMajorFromFileName('ggml-cuda.dll'), isNull);
    expect(windowsCudaMajorFromFileName('ggml-vulkan-13.dll'), isNull);
  });

  test('prefers CUDA 13 when the driver and GPU satisfy its contract', () {
    expect(
      selectWindowsCudaMajor(
        availableMajors: const {12, 13},
        probe: const WindowsCudaDriverProbe(
          driverApiVersion: 13000,
          computeCapabilities: [89],
        ),
      ),
      13,
    );
  });

  test('falls back to CUDA 12 at driver and GPU boundaries', () {
    for (final probe in const [
      WindowsCudaDriverProbe(
        driverApiVersion: 12000,
        computeCapabilities: [89],
      ),
      WindowsCudaDriverProbe(
        driverApiVersion: 13000,
        computeCapabilities: [70],
      ),
    ]) {
      expect(
        selectWindowsCudaMajor(availableMajors: const {12, 13}, probe: probe),
        12,
      );
    }
  });

  test('uses the oldest visible GPU for a mixed-GPU system', () {
    expect(
      selectWindowsCudaMajor(
        availableMajors: const {12, 13},
        probe: const WindowsCudaDriverProbe(
          driverApiVersion: 13000,
          computeCapabilities: [89, 70],
        ),
      ),
      12,
    );
  });

  test('rejects unsupported driver and compute capability combinations', () {
    expect(
      selectWindowsCudaMajor(
        availableMajors: const {12, 13},
        probe: const WindowsCudaDriverProbe(
          driverApiVersion: 11080,
          computeCapabilities: [89],
        ),
      ),
      isNull,
    );
    expect(
      selectWindowsCudaMajor(
        availableMajors: const {12, 13},
        probe: const WindowsCudaDriverProbe(
          driverApiVersion: 13000,
          computeCapabilities: [49],
        ),
      ),
      isNull,
    );
  });
}
