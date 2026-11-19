@TestOn('vm')
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:mirrors';

import 'package:ffi/ffi.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/llama_cpp/bindings.dart';
import 'package:llamadart/src/backends/llama_cpp/exit_teardown_api.dart';
import 'package:llamadart/src/backends/llama_cpp/gpu_memory_fit.dart';
import 'package:llamadart/src/backends/llama_cpp/llama_cpp_service.dart';
import 'package:llamadart/src/backends/llama_cpp/load_device_selection.dart';
import 'package:llamadart/src/backends/llama_cpp/vulkan_device_probe.dart';
import 'package:test/test.dart';

import '../../../support/recording_allocator.dart';
import '../../../support/recording_exit_teardown.dart';
import '../../../support/synthetic_embedding_gguf.dart';

const _load = 'llama_dart_model_load_from_file';
final int _gpu = ggml_backend_dev_type.GGML_BACKEND_DEVICE_TYPE_GPU.value;
const _gib = 1 << 30;

GgmlDeviceEntry _cuda(int index) => GgmlDeviceEntry(
  name: 'CUDA$index',
  registry: 'CUDA',
  description: 'CUDA$index',
  type: _gpu,
  device: Pointer.fromAddress(0x1000 * (index + 1)),
);

GpuMemoryFitDevice _device({int free = 3 * _gib, int projected = 2 * _gib}) =>
    GpuMemoryFitDevice(
      name: 'CUDA0',
      freeBytes: free,
      totalBytes: 8 * _gib,
      modelBytes: projected ~/ 2,
      contextBytes: projected ~/ 4,
      computeBytes: projected - projected ~/ 2 - projected ~/ 4,
    );

/// What a fit runner was asked for and what it answers.
final class _FakeFit {
  GpuMemoryFitStatus status = GpuMemoryFitStatus.success;
  String? error;
  int? fittedLayers;
  int? fittedContext;
  List<double> split = const [];
  List<String> overridePatterns = const [];
  int offloadableLayers = 28;
  int skippedLayers = 0;
  int trainedContext = 1024;
  List<GpuMemoryFitDevice> devices = [_device()];
  Object? throws;

  final List<_Seen> seen = [];
  final List<Pointer<Utf8>> patterns = [];

  GpuMemoryFitNativeResult run(GpuMemoryFitRequest request) {
    final context = request.contextParams.ref;
    seen.add(
      _Seen(
        layers: request.modelParams.ref.n_gpu_layers,
        margins: [
          for (var i = 0; i < request.deviceSlots; i++) request.margins[i],
        ],
        minContextSize: request.minContextSize,
        nCtx: context.n_ctx,
        nBatch: context.n_batch,
        nUbatch: context.n_ubatch,
        nSeqMax: context.n_seq_max,
        typeK: context.type_kAsInt,
        typeV: context.type_vAsInt,
        kvUnified: context.kv_unified,
        flashAttn: context.flash_attn_typeAsInt,
        offloadKqv: context.offload_kqv,
        opOffload: context.op_offload,
        deviceSlots: request.deviceSlots,
      ),
    );
    if (throws case final error?) throw error;
    if (status != GpuMemoryFitStatus.success) {
      return GpuMemoryFitNativeResult(status: status, error: error);
    }
    if (fittedLayers case final layers?) {
      request.modelParams.ref.n_gpu_layers = layers;
    }
    if (fittedContext case final nCtx?) {
      request.contextParams.ref.n_ctx = nCtx;
    }
    for (final (i, value) in split.indexed) {
      request.tensorSplit[i] = value;
    }
    for (final (i, pattern) in overridePatterns.indexed) {
      final native = pattern.toNativeUtf8();
      patterns.add(native);
      request.tensorBufferOverrides[i]
        ..pattern = native.cast()
        ..buft = Pointer.fromAddress(0x10);
    }
    return GpuMemoryFitNativeResult(
      status: status,
      offloadableLayers: offloadableLayers,
      skippedLayers: skippedLayers,
      trainedContextSize: trainedContext,
      devices: devices,
    );
  }

  void dispose() {
    for (final pattern in patterns) {
      malloc.free(pattern);
    }
  }
}

final class _Seen {
  const _Seen({
    required this.layers,
    required this.margins,
    required this.minContextSize,
    required this.nCtx,
    required this.nBatch,
    required this.nUbatch,
    required this.nSeqMax,
    required this.typeK,
    required this.typeV,
    required this.kvUnified,
    required this.flashAttn,
    required this.offloadKqv,
    required this.opOffload,
    required this.deviceSlots,
  });

  final int layers;
  final List<int> margins;
  final int minContextSize;
  final int nCtx;
  final int nBatch;
  final int nUbatch;
  final int nSeqMax;
  final int typeK;
  final int typeV;
  final bool kvUnified;
  final int flashAttn;
  final bool offloadKqv;
  final bool opOffload;
  final int deviceSlots;
}

// Fake devices must never reach llama.cpp: the recording boundary replaces the
// device params of the load with a CPU load, as the multi-GPU tests do.
void main() {
  late Directory dir;
  late String model;
  late RecordingExitTeardown recorder;
  late RecordingAllocator allocator;
  late LlamaCppService service;
  late _FakeFit fit;
  late List<LlamaLogRecord> records;

  void start({
    String operatingSystem = 'linux',
    bool withRunner = true,
    bool isAndroid = false,
    List<GgmlDeviceEntry>? devices,
    bool noBackendDevices = false,
  }) {
    final registered = devices ?? [_cuda(0)];
    allocator = RecordingAllocator();
    recorder = RecordingExitTeardown(
      ExitTeardownApi.tryResolve(isWindows: Platform.isWindows)!,
    );
    recorder.modelLoad = (path, params) {
      params.devices = nullptr;
      params.tensor_split = nullptr;
      params.tensor_buft_overrides = nullptr;
      params.n_gpu_layers = 0;
      return recorder.real.modelLoadFromFile(path, params);
    };
    service = LlamaCppService(
      isMacosX64: false,
      isAndroid: isAndroid,
      operatingSystem: operatingSystem,
      gpuMemoryFitRunner: () => withRunner ? fit.run : null,
      objectCalls: LlamaCppObjectCalls.tracked(
        recorder.api,
        isWindows: Platform.isWindows,
      ),
      registeredDevices: () => registered,
      vulkanDeviceProbe: () => const VulkanDeviceProbe.unavailable('test'),
      linuxVulkanProbe: () => null,
      backendDevices: (_) =>
          noBackendDevices ? null : [for (final d in registered) d.device!],
      deviceTypes: (_) => [_gpu],
      modelLoadAllocator: allocator,
    )..initializeBackend();
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('llamadart_gpu_memory_fit_');
    model = writeSyntheticLlamaGguf('${dir.path}/model.gguf').path;
    fit = _FakeFit();
    records = [];
    LlamaLogger.instance
      ..setLevel(LlamaLogLevel.info)
      ..setHandler(records.add);
  });

  tearDown(() {
    service.dispose();
    fit.dispose();
    LlamaLogger.instance
      ..setLevel(LlamaLogLevel.none)
      ..setHandler(null);
    dir.deleteSync(recursive: true);
  });

  const withFit = GpuMemoryFit(marginBytes: _gib);
  ModelParams params({
    GpuMemoryFit? gpuMemoryFit = withFit,
    ComputeDevice device = ComputeDevice.auto,
    int contextSize = 512,
    List<int>? gpuDevices,
  }) => ModelParams(
    contextSize: contextSize,
    device: device,
    preferredBackend: GpuBackend.cuda,
    gpuMemoryFit: gpuMemoryFit,
    gpuDevices: gpuDevices,
  );

  List<LlamaLogRecord> warnings() =>
      records.where((r) => r.level == LlamaLogLevel.warn).toList();

  test('without gpuMemoryFit the load asks for every layer and reports '
      'nothing', () {
    start();
    final handle = service.loadModel(model, params(gpuMemoryFit: null));
    expect(fit.seen, isEmpty);
    expect(recorder.loadGpuLayers, [ModelParams.maxGpuLayers]);
    expect(service.getGpuMemoryFitReport(), isNull);
    expect(service.getResolvedGpuLayers(), ModelParams.maxGpuLayers);
    service.freeModel(handle);
    allocator.expectAllFreed();
  });

  test('a partial fit loads only the fitted layers, split and overrides', () {
    fit
      ..fittedLayers = 14
      ..overridePatterns = ['blk\\.1[5-9]\\.ffn_.*_exps']
      ..devices = [_device(free: 3 * _gib, projected: 2 * _gib)];
    start();
    service.loadModel(model, params());

    final seen = fit.seen.single;
    expect(seen.layers, -1);
    expect(seen.margins, everyElement(_gib));
    expect(seen.margins, hasLength(seen.deviceSlots));
    expect(seen.minContextSize, 0xFFFFFFFF);
    expect(recorder.loadGpuLayers, [14]);
    expect(recorder.loadTensorOverrides, [
      ['blk\\.1[5-9]\\.ffn_.*_exps'],
    ]);
    final report = service.getGpuMemoryFitReport()!;
    expect(report.outcome, GpuMemoryFitOutcome.reduced);
    expect(report.gpuLayers, 14);
    expect(report.modelLayers, 29);
    expect(report.marginBytes, _gib);
    expect(report.devices.single.freeBytes, 3 * _gib);
    expect(report.devices.single.projectedBytes, 2 * _gib);
    expect(service.getResolvedGpuLayers(), 14);
    expect(warnings(), hasLength(1));
    expect(warnings().single.message, contains('14 of 29'));
    allocator.expectAllFreed();
  });

  test('skipped NextN layers count toward the full offload bound', () {
    fit
      ..skippedLayers = 1
      ..fittedLayers = 29;
    start();
    service.loadModel(model, params());
    // 28 layers + 1 skipped + the output layer: 29 is partial, not full.
    final report = service.getGpuMemoryFitReport()!;
    expect(report.modelLayers, 30);
    expect(report.outcome, GpuMemoryFitOutcome.reduced);
    expect(report.gpuLayers, 29);
    expect(recorder.loadGpuLayers, [29]);
    allocator.expectAllFreed();
  });

  test('freeModel removes that model\'s fit report', () {
    start();
    final first = service.loadModel(model, params());
    final firstReport = service.getGpuMemoryFitReport();
    final second = service.loadModel(model, params());
    final secondReport = service.getGpuMemoryFitReport();
    expect(firstReport, isNotNull);
    expect(secondReport, isNotNull);
    expect(secondReport, isNot(same(firstReport)));

    service.freeModel(first);

    final library = reflectClass(LlamaCppService).owner as LibraryMirror;
    final reports =
        reflect(service)
                .getField(
                  MirrorSystem.getSymbol('_modelGpuMemoryFitReports', library),
                )
                .reflectee
            as Map<int, GpuMemoryFitReport>;
    expect(reports, {second: secondReport});
    expect(service.getGpuMemoryFitReport(), same(secondReport));

    service.freeModel(second);
    expect(reports, isEmpty);
    expect(service.getGpuMemoryFitReport(), isNull);
  });

  test('a load that fits keeps every requested layer', () {
    start();
    service.loadModel(model, params());
    expect(recorder.loadGpuLayers, [ModelParams.maxGpuLayers]);
    final report = service.getGpuMemoryFitReport()!;
    expect(report.outcome, GpuMemoryFitOutcome.unchanged);
    expect(report.gpuLayers, report.modelLayers);
    expect(warnings(), isEmpty);
    allocator.expectAllFreed();
  });

  test('nothing fitting under auto loads on the CPU and says so', () {
    fit.fittedLayers = 0;
    start();
    service.loadModel(model, params());
    final cpuDevice = _invokePrivate<List<ggml_backend_dev_t>>(
      service,
      '_resolvePreferredDevices',
      [GpuBackend.cpu],
    ).single;
    expect(recorder.loadDevices.single, [cpuDevice.address]);
    expect(
      recorder.loadDevices.single,
      isNot(contains(_cuda(0).device!.address)),
    );
    expect(recorder.loadGpuLayers, [0]);
    final report = service.getGpuMemoryFitReport()!;
    expect(report.outcome, GpuMemoryFitOutcome.cpu);
    expect(report.gpuLayers, 0);
    expect(service.getActiveBackendName(), 'CPU');
    expect(service.getResolvedGpuLayers(), 0);
    expect(warnings(), hasLength(1));
    allocator.expectAllFreed();
  });

  test('nothing fitting under ComputeDevice.gpu throws before the load', () {
    fit.fittedLayers = 0;
    start();
    expect(
      () => service.loadModel(model, params(device: ComputeDevice.gpu)),
      throwsA(
        isA<LlamaGpuMemoryFitException>().having(
          (e) => e.report?.outcome,
          'report.outcome',
          GpuMemoryFitOutcome.cpu,
        ),
      ),
    );
    expect(recorder.loadGpuLayers, isEmpty);
    expect(recorder.calls, isNot(contains(_load)));
    allocator.expectAllFreed();
  });

  for (final status in [
    GpuMemoryFitStatus.failure,
    GpuMemoryFitStatus.error,
    GpuMemoryFitStatus.exception,
  ]) {
    test('a ${status.name} status throws instead of loading everything', () {
      fit
        ..status = status
        ..error = 'native said no';
      start();
      expect(
        () => service.loadModel(model, params()),
        throwsA(
          isA<LlamaGpuMemoryFitException>().having(
            (e) => e.message,
            'message',
            contains('native said no'),
          ),
        ),
      );
      expect(recorder.loadGpuLayers, isEmpty);
      expect(recorder.calls, isNot(contains(_load)));
      allocator.expectAllFreed();
    });
  }

  test('a runner that throws releases what the fit allocated', () {
    fit.throws = StateError('boom');
    start();
    expect(() => service.loadModel(model, params()), throwsStateError);
    expect(recorder.calls, isNot(contains(_load)));
    allocator.expectAllFreed();
  });

  test('a runtime without the fit export is unsupported', () {
    start(withRunner: false);
    expect(
      () => service.loadModel(model, params()),
      throwsA(
        isA<LlamaUnsupportedException>().having(
          (e) => e.message,
          'message',
          allOf(contains('gpuMemoryFit'), contains('llama_dart_fit_params')),
        ),
      ),
    );
    expect(recorder.calls, isNot(contains(_load)));
    allocator.expectAllFreed();
  });

  for (final os in ['macos', 'ios', 'android']) {
    test('on $os the fit is skipped and the load is unchanged', () {
      fit.fittedLayers = 14;
      start(operatingSystem: os);
      service.loadModel(model, params());
      expect(fit.seen, isEmpty);
      expect(recorder.loadGpuLayers, [ModelParams.maxGpuLayers]);
      final report = service.getGpuMemoryFitReport()!;
      expect(report.outcome, GpuMemoryFitOutcome.skipped);
      expect(report.reason, contains(os));
      allocator.expectAllFreed();
    });
  }

  test('a load that offloads nothing skips the fit', () {
    start(isAndroid: true);
    service.loadModel(
      model,
      const ModelParams(contextSize: 512, gpuMemoryFit: withFit),
    );
    expect(fit.seen, isEmpty);
    expect(recorder.loadGpuLayers, [0]);
    expect(
      service.getGpuMemoryFitReport()!.outcome,
      GpuMemoryFitOutcome.skipped,
    );
    allocator.expectAllFreed();
  });

  test('a forced CPU fallback skips the fit', () {
    start(noBackendDevices: true);
    final moduleDir = Directory('${dir.path}/modules')..createSync();
    _setBackendModuleDirectory(service, moduleDir.path);
    service.loadModel(model, params());
    expect(fit.seen, isEmpty);
    expect(recorder.loadGpuLayers, [0]);
    expect(
      service.getGpuMemoryFitReport()!.outcome,
      GpuMemoryFitOutcome.skipped,
    );
    allocator.expectAllFreed();
  });

  test('an automatic context takes the fitted size at context creation', () {
    fit
      ..fittedContext = 512
      ..trainedContext = 1024;
    start();
    const requested = ModelParams(
      contextSize: 0,
      preferredBackend: GpuBackend.cuda,
      gpuMemoryFit: GpuMemoryFit(marginBytes: _gib, minContextSize: 256),
    );
    final handle = service.loadModel(model, requested);
    final seen = fit.seen.single;
    expect(seen.nCtx, 0);
    expect(seen.minContextSize, 256);
    service.createContext(handle, requested);
    expect(recorder.contextConfigs.single.nCtx, 512);
    final report = service.getGpuMemoryFitReport()!;
    expect(report.outcome, GpuMemoryFitOutcome.reduced);
    expect(report.contextSize, 512);
    allocator.expectAllFreed();
  });

  test('an automatic context measures the batches it will be created with', () {
    model = writeSyntheticLlamaGguf(
      '${dir.path}/long.gguf',
      contextLength: 8192,
    ).path;
    fit.trainedContext = 8192;
    start();
    const requested = ModelParams(
      contextSize: 0,
      preferredBackend: GpuBackend.cuda,
      gpuMemoryFit: GpuMemoryFit(marginBytes: _gib),
      batchSize: 4096,
      microBatchSize: 4096,
    );
    final handle = service.loadModel(model, requested);
    // The synthetic model's head size rejects the context after the
    // recorder has seen its parameters.
    try {
      service.createContext(handle, requested);
    } on Object {
      // Only the recorded parameters matter.
    }
    final seen = fit.seen.single;
    final created = recorder.contextConfigs.single;
    expect((seen.nBatch, seen.nUbatch), (created.nBatch, created.nUbatch));
    expect((seen.nBatch, seen.nUbatch), (4096, 4096));
  });

  test(
    'an automatic context measures distinct batch and micro-batch sizes',
    () {
      model = writeSyntheticLlamaGguf(
        '${dir.path}/long-ubatch.gguf',
        contextLength: 8192,
      ).path;
      fit.trainedContext = 8192;
      start();
      const requested = ModelParams(
        contextSize: 0,
        preferredBackend: GpuBackend.cuda,
        gpuMemoryFit: GpuMemoryFit(marginBytes: _gib),
        batchSize: 4096,
        microBatchSize: 1024,
      );
      final handle = service.loadModel(model, requested);
      try {
        service.createContext(handle, requested);
      } on Object {
        // Only the recorded parameters matter.
      }
      final seen = fit.seen.single;
      final created = recorder.contextConfigs.single;
      expect((seen.nBatch, seen.nUbatch), (created.nBatch, created.nUbatch));
      expect((seen.nBatch, seen.nUbatch), (4096, 1024));
    },
  );

  test('the fit measures the context that is created', () {
    start();
    final measured = ModelParams(
      contextSize: 512,
      preferredBackend: GpuBackend.cuda,
      gpuMemoryFit: withFit,
      cacheTypeK: KvCacheType.q8_0,
      cacheTypeV: KvCacheType.q8_0,
      kvUnified: true,
      maxParallelSequences: 2,
      batchSize: 256,
      microBatchSize: 128,
    );
    final handle = service.loadModel(model, measured);
    // The synthetic model's head size rejects a quantized KV cache; the
    // recorder has seen the context parameters by then.
    expect(() => service.createContext(handle, measured), throwsException);
    final seen = fit.seen.single;
    final created = recorder.contextConfigs.single;
    expect(
      (
        seen.nCtx,
        seen.nBatch,
        seen.nUbatch,
        seen.nSeqMax,
        seen.typeK,
        seen.typeV,
        seen.kvUnified,
      ),
      (
        created.nCtx,
        created.nBatch,
        created.nUbatch,
        created.nSeqMax,
        created.typeK,
        created.typeV,
        created.kvUnified,
      ),
    );
    expect(seen.typeK, isNot(ggml_type.GGML_TYPE_F16.value));
    expect(seen.nSeqMax, 2);
    allocator.expectAllFreed();
  });

  test('the override array and split are freed after the load, their static '
      'patterns never', () {
    fit
      ..fittedLayers = 14
      ..split = [3, 1]
      ..overridePatterns = ['a', 'b'];
    start(devices: [_cuda(0), _cuda(1)]);
    recorder.modelLoad = (path, loadParams) {
      expect(allocator.live, contains(loadParams.tensor_split));
      expect(allocator.live, contains(loadParams.tensor_buft_overrides));
      loadParams.devices = nullptr;
      loadParams.tensor_split = nullptr;
      loadParams.tensor_buft_overrides = nullptr;
      loadParams.n_gpu_layers = 0;
      return recorder.real.modelLoadFromFile(path, loadParams);
    };
    service.loadModel(model, params(gpuDevices: [0, 1]));
    expect(recorder.loadTensorOverrides.single, ['a', 'b']);
    allocator.expectAllFreed();
  });

  test('a fitted tensor split across devices reaches the load', () {
    fit
      ..fittedLayers = 20
      ..split = [3, 1];
    start(devices: [_cuda(0), _cuda(1)]);
    service.loadModel(model, params(gpuDevices: [0, 1]));
    expect(recorder.loadDevices.single, hasLength(2));
    expect(recorder.loadTensorSplits.single, [3.0, 1.0]);
    expect(recorder.loadGpuLayers, [20]);
    allocator.expectAllFreed();
  });

  test('an encoder-only model that would batch more than measured is '
      'refused', () {
    final encoder = writeSyntheticT5EncoderGguf(
      '${dir.path}/encoder.gguf',
    ).path;
    start();
    expect(
      () => service.loadModel(
        encoder,
        const ModelParams(
          contextSize: 4096,
          preferredBackend: GpuBackend.cuda,
          gpuMemoryFit: withFit,
        ),
      ),
      throwsA(
        isA<LlamaUnsupportedException>().having(
          (e) => e.message,
          'message',
          contains('batchSize'),
        ),
      ),
    );
    expect(service.getGpuMemoryFitReport(), isNull);
    allocator.expectAllFreed();
  });

  test('a tensor split with the fit is refused before any native call', () {
    start();
    expect(
      () => service.loadModel(
        model,
        const ModelParams(
          preferredBackend: GpuBackend.cuda,
          tensorSplit: [1, 1],
          gpuMemoryFit: withFit,
        ),
      ),
      throwsA(isA<LlamaArgumentException>()),
    );
    expect(fit.seen, isEmpty);
  });
}

void _setBackendModuleDirectory(LlamaCppService service, String directory) {
  final owner = reflectClass(LlamaCppService).owner as LibraryMirror;
  reflect(service).setField(
    MirrorSystem.getSymbol('_backendModuleDirectory', owner),
    directory,
  );
}

T _invokePrivate<T>(
  LlamaCppService service,
  String method,
  List<Object?> args,
) {
  final owner = reflectClass(LlamaCppService).owner as LibraryMirror;
  return reflect(
        service,
      ).invoke(MirrorSystem.getSymbol(method, owner), args).reflectee
      as T;
}
