@TestOn('vm')
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:llamadart/src/backends/llama_cpp/bindings.dart';
import 'package:llamadart/src/backends/llama_cpp/gpu_memory_fit.dart';
import 'package:llamadart/src/backends/llama_cpp/native_gpu_memory_fit.dart';
import 'package:test/test.dart';

import '../../../support/synthetic_embedding_gguf.dart';

void main() {
  late Directory dir;
  late GpuMemoryFitRunner runner;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('llamadart_native_fit_');
    final resolved = resolveNativeGpuMemoryFitRunner();
    expect(resolved, isNotNull, reason: 'the pinned runtime exports the fit');
    runner = resolved!;
  });

  tearDown(() => dir.deleteSync(recursive: true));

  GpuMemoryFitNativeResult run(
    String path, {
    int contextSize = 0,
    int? gpuLayers,
    int marginBytes = 0,
  }) {
    final pathPtr = path.toNativeUtf8();
    final model = calloc<llama_model_params>();
    final context = calloc<llama_context_params>();
    final defaults = llama_model_default_params();
    model.ref = defaults;
    if (gpuLayers != null) model.ref.n_gpu_layers = gpuLayers;
    context.ref = llama_context_default_params();
    context.ref.n_ctx = contextSize;
    final slots = llama_max_devices();
    final split = calloc<Float>(slots);
    final overrides = calloc<llama_model_tensor_buft_override>(
      llama_max_tensor_buft_overrides(),
    );
    final margins = calloc<Size>(slots);
    for (var i = 0; i < slots; i++) {
      margins[i] = marginBytes;
    }
    try {
      return runner(
        GpuMemoryFitRequest(
          modelPath: pathPtr.cast(),
          modelParams: model,
          contextParams: context,
          tensorSplit: split,
          tensorBufferOverrides: overrides,
          margins: margins,
          deviceSlots: slots,
          overrideSlots: llama_max_tensor_buft_overrides(),
          minContextSize: gpuMemoryFitKeepContext,
        ),
      );
    } finally {
      for (final pointer in [
        pathPtr,
        model,
        context,
        split,
        overrides,
        margins,
      ]) {
        calloc.free(pointer);
      }
    }
  }

  test('fits a real model and reports its layers', () {
    final path = writeSyntheticLlamaGguf('${dir.path}/model.gguf').path;
    final result = run(path, contextSize: 256);
    expect(result.status, GpuMemoryFitStatus.success, reason: result.error);
    expect(result.offloadableLayers, 1);
    expect(result.trainedContextSize, 1024);
    expect(result.modelLayers, greaterThanOrEqualTo(2));
    for (final device in result.devices) {
      expect(device.name, isNotEmpty);
      expect(device.totalBytes, greaterThan(0));
    }
  });

  test('a fit that cannot change a preset layer count is a failed fit', () {
    final path = writeSyntheticLlamaGguf('${dir.path}/model.gguf').path;
    final result = run(
      path,
      contextSize: 256,
      gpuLayers: 0,
      marginBytes: 1 << 60,
    );
    expect(result.status, GpuMemoryFitStatus.failure);
    expect(result.devices, isEmpty);
  });

  test('an unreadable model is an error that carries the native message', () {
    final result = run('${dir.path}/missing.gguf');
    expect(result.status, isNot(GpuMemoryFitStatus.success));
    expect(result.devices, isEmpty);
  });
}
