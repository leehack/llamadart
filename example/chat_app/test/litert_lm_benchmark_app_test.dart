import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_chat_example/litert_lm_benchmark_app.dart';

void main() {
  group('LiteRT-LM benchmark backend selection', () {
    test('chooses platform defaults for LiteRT-LM comparisons', () {
      expect(
        resolveLiteRtLmBenchmarkBackendName('auto', operatingSystem: 'ios'),
        'cpu',
      );
      expect(
        resolveLiteRtLmBenchmarkBackendName('', operatingSystem: 'macos'),
        'gpu',
      );
      expect(
        resolveLiteRtLmBenchmarkBackendName('auto', operatingSystem: 'android'),
        'gpu',
      );
    });

    test('honors explicit LiteRT-LM backend overrides', () {
      expect(resolveLiteRtLmBenchmarkBackendName(' cpu '), 'cpu');
      expect(resolveLiteRtLmBenchmarkBackendName('gpu'), 'gpu');
      expect(resolveLiteRtLmBenchmarkBackendName('npu'), 'npu');
      expect(
        () => resolveLiteRtLmBenchmarkBackendName('metal'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('chooses platform defaults for fair llama.cpp comparisons', () {
      expect(
        resolveLlamaCppBenchmarkBackend('auto', operatingSystem: 'macos'),
        GpuBackend.metal,
      );
      expect(
        resolveLlamaCppBenchmarkBackend('', operatingSystem: 'ios'),
        GpuBackend.metal,
      );
      expect(
        resolveLlamaCppBenchmarkBackend('auto', operatingSystem: 'android'),
        GpuBackend.vulkan,
      );
      expect(
        resolveLlamaCppBenchmarkBackend('auto', operatingSystem: 'linux'),
        GpuBackend.vulkan,
      );
      expect(
        resolveLlamaCppBenchmarkBackend('auto', operatingSystem: 'windows'),
        GpuBackend.vulkan,
      );
    });

    test('honors explicit llama.cpp backend overrides', () {
      expect(resolveLlamaCppBenchmarkBackend('cpu'), GpuBackend.cpu);
      expect(resolveLlamaCppBenchmarkBackend(' metal '), GpuBackend.metal);
      expect(resolveLlamaCppBenchmarkBackend('cuda'), GpuBackend.cuda);
      expect(resolveLlamaCppBenchmarkBackend('opencl'), GpuBackend.opencl);
      expect(resolveLlamaCppBenchmarkBackend('hip'), GpuBackend.hip);
      expect(resolveLlamaCppBenchmarkBackend('blas'), GpuBackend.blas);
    });

    test('labels requested llama.cpp backend in benchmark metrics', () {
      expect(llamaCppBenchmarkBackendLabel(GpuBackend.vulkan), 'Vulkan');
      expect(llamaCppBenchmarkBackendLabel(GpuBackend.metal), 'Metal');
      expect(llamaCppBenchmarkBackendLabel(GpuBackend.cpu), 'CPU');
    });

    test('normalizes UI backend names from environment values', () {
      expect(normalizeLlamaCppBenchmarkBackendName(' Metal '), 'metal');
      expect(normalizeLlamaCppBenchmarkBackendName('directml'), 'auto');
    });

    test('resolves relative model names from app documents when requested', () {
      expect(
        resolveBenchmarkModelPath(
          'gemma-4-E2B-it.litertlm',
          homeDirectory: '/app/home',
          useDocumentsForRelative: true,
        ),
        '/app/home/Documents/gemma-4-E2B-it.litertlm',
      );
      expect(
        resolveBenchmarkModelPath(
          'documents:gemma-4-E2B-it-Q4_K_S.gguf',
          homeDirectory: '/app/home',
          useDocumentsForRelative: false,
        ),
        '/app/home/Documents/gemma-4-E2B-it-Q4_K_S.gguf',
      );
      expect(
        resolveBenchmarkModelPath(
          '/tmp/gemma.gguf',
          homeDirectory: '/app/home',
          useDocumentsForRelative: true,
        ),
        '/tmp/gemma.gguf',
      );
    });

    test('rejects unknown backend override names', () {
      expect(
        () => resolveLlamaCppBenchmarkBackend('directml'),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
