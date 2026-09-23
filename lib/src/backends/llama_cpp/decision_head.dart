import 'dart:ffi';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../../core/decision/decision_decoder.dart';
import '../../core/exceptions.dart';
import '../backend.dart';
import 'bindings.dart';
import 'ggml_graph_api.dart';
import 'safetensors.dart';

const double _layerNormEpsilon = 1e-5;

/// Decision-head weights read from a safetensors file, converted to F32.
final class DecisionHeadWeights {
  DecisionHeadWeights._({
    required this.hiddenSize,
    required this.heads,
    required this.layers,
    required this.ffnSize,
    required this.actHiddenSize,
    required this.actClasses,
    required Float32List typeEmbedding,
    required List<_LayerWeights> layerWeights,
    required _ScorerWeights scorer,
    required _ActWeights act,
  }) : _typeEmbedding = typeEmbedding,
       _layerWeights = layerWeights,
       _scorer = scorer,
       _act = act;

  /// Reads the head tensors of [file] for an encoder of width [hiddenSize].
  ///
  /// [config] is the head's Laya config; its `head_layers` (default 2) sets
  /// how many transformer layers are read. Tensors outside the head, such as
  /// `encoder.*` and `temperature`, are ignored. Throws [LlamaModelException]
  /// when `head_layers` is not a positive integer, when [hiddenSize] is not
  /// positive or not divisible by [heads], when the file has tensors for more
  /// head layers than `head_layers`, when a head tensor is missing (naming
  /// it) or mis-shaped (naming it with the expected and found shapes), and
  /// when [SafetensorsFile.readFloat32] cannot read one.
  static DecisionHeadWeights read(
    SafetensorsFile file, {
    required int hiddenSize,
    required Map<String, Object?> config,
  }) {
    final d = hiddenSize;
    if (d < 1) {
      throw LlamaModelException(
        'Decision head hidden size must be positive, got $d.',
      );
    }
    final heads = math.max(1, d ~/ 64);
    if (d % heads != 0) {
      throw LlamaModelException(
        'Decision head hidden size $d is not divisible by its $heads '
        'attention heads.',
      );
    }
    final layers = config['head_layers'] ?? 2;
    if (layers is! int || layers < 1) {
      throw LlamaModelException(
        'Decision head config "head_layers" must be a positive integer, got '
        '$layers.',
      );
    }
    final extraLayer = 'head.layers.$layers.';
    if (file.tensors.keys.any((name) => name.startsWith(extraLayer))) {
      throw LlamaModelException(
        'Decision head file "${file.path}" has tensors for more than the '
        '$layers layers its config "head_layers" names.',
      );
    }

    final shapes = _ShapeCheck(file);
    final ffn = shapes.rows('head.layers.0.linear1.weight', d, 'ffn');
    shapes.expect('type_emb.weight', [3, d]);
    for (var i = 0; i < layers; i++) {
      final p = 'head.layers.$i';
      shapes
        ..expect('$p.self_attn.in_proj_weight', [3 * d, d])
        ..expect('$p.self_attn.in_proj_bias', [3 * d])
        ..expect('$p.self_attn.out_proj.weight', [d, d])
        ..expect('$p.self_attn.out_proj.bias', [d])
        ..expect('$p.linear1.weight', [ffn, d])
        ..expect('$p.linear1.bias', [ffn])
        ..expect('$p.linear2.weight', [d, ffn])
        ..expect('$p.linear2.bias', [d])
        ..expect('$p.norm1.weight', [d])
        ..expect('$p.norm1.bias', [d])
        ..expect('$p.norm2.weight', [d])
        ..expect('$p.norm2.bias', [d]);
    }
    shapes
      ..expect('scorer.0.weight', [d])
      ..expect('scorer.0.bias', [d])
      ..expect('scorer.1.weight', [d, d])
      ..expect('scorer.1.bias', [d])
      ..expect('scorer.3.weight', [1, d])
      ..expect('scorer.3.bias', [1]);
    final actHidden = shapes.rows('act_head.0.weight', d + 4, 'act hidden');
    shapes.expect('act_head.0.bias', [actHidden]);
    final actClasses = shapes.rows('act_head.2.weight', actHidden, 'classes');
    shapes.expect('act_head.2.bias', [actClasses]);

    final read = file.readFloat32;
    return DecisionHeadWeights._(
      hiddenSize: d,
      heads: heads,
      layers: layers,
      ffnSize: ffn,
      actHiddenSize: actHidden,
      actClasses: actClasses,
      typeEmbedding: read('type_emb.weight'),
      layerWeights: [
        for (var i = 0; i < layers; i++) _LayerWeights(read, 'head.layers.$i'),
      ],
      scorer: _ScorerWeights(read),
      act: _ActWeights(read),
    );
  }

  /// Width of the encoder output and of the head layers.
  final int hiddenSize;

  /// Attention heads per layer, `max(1, hiddenSize ~/ 64)`.
  final int heads;

  /// Transformer layers, the config's `head_layers`.
  final int layers;

  /// Feed-forward width of each layer.
  final int ffnSize;

  /// Hidden width of the act MLP.
  final int actHiddenSize;

  /// Number of act-head outputs.
  final int actClasses;

  final Float32List _typeEmbedding;
  final List<_LayerWeights> _layerWeights;
  final _ScorerWeights _scorer;
  final _ActWeights _act;
}

final class _ShapeCheck {
  _ShapeCheck(this.file);

  final SafetensorsFile file;

  List<int> _shape(String name) {
    final tensor = file.tensors[name];
    if (tensor == null) {
      throw LlamaModelException(
        'Decision head file "${file.path}" has no tensor "$name".',
      );
    }
    return tensor.shape;
  }

  void expect(String name, List<int> expected) {
    final found = _shape(name);
    if (found.length != expected.length ||
        Iterable<int>.generate(
          found.length,
        ).any((i) => found[i] != expected[i])) {
      throw LlamaModelException(
        'Decision head tensor "$name" in "${file.path}" has shape $found; '
        'expected $expected.',
      );
    }
  }

  int rows(String name, int columns, String rowName) {
    final found = _shape(name);
    if (found.length != 2 || found[0] < 1 || found[1] != columns) {
      throw LlamaModelException(
        'Decision head tensor "$name" in "${file.path}" has shape $found; '
        'expected [$rowName, $columns] with $rowName >= 1.',
      );
    }
    return found[0];
  }
}

final class _LayerWeights {
  _LayerWeights(Float32List Function(String) read, String p)
    : inProjWeight = read('$p.self_attn.in_proj_weight'),
      inProjBias = read('$p.self_attn.in_proj_bias'),
      outProjWeight = read('$p.self_attn.out_proj.weight'),
      outProjBias = read('$p.self_attn.out_proj.bias'),
      linear1Weight = read('$p.linear1.weight'),
      linear1Bias = read('$p.linear1.bias'),
      linear2Weight = read('$p.linear2.weight'),
      linear2Bias = read('$p.linear2.bias'),
      norm1Weight = read('$p.norm1.weight'),
      norm1Bias = read('$p.norm1.bias'),
      norm2Weight = read('$p.norm2.weight'),
      norm2Bias = read('$p.norm2.bias');

  final Float32List inProjWeight;
  final Float32List inProjBias;
  final Float32List outProjWeight;
  final Float32List outProjBias;
  final Float32List linear1Weight;
  final Float32List linear1Bias;
  final Float32List linear2Weight;
  final Float32List linear2Bias;
  final Float32List norm1Weight;
  final Float32List norm1Bias;
  final Float32List norm2Weight;
  final Float32List norm2Bias;
}

final class _ScorerWeights {
  _ScorerWeights(Float32List Function(String) read)
    : normWeight = read('scorer.0.weight'),
      normBias = read('scorer.0.bias'),
      hiddenWeight = read('scorer.1.weight'),
      hiddenBias = read('scorer.1.bias'),
      outWeight = read('scorer.3.weight'),
      outBias = read('scorer.3.bias');

  final Float32List normWeight;
  final Float32List normBias;
  final Float32List hiddenWeight;
  final Float32List hiddenBias;
  final Float32List outWeight;
  final Float32List outBias;
}

final class _ActWeights {
  _ActWeights(Float32List Function(String) read)
    : hiddenWeight = read('act_head.0.weight'),
      hiddenBias = read('act_head.0.bias'),
      outWeight = read('act_head.2.weight'),
      outBias = read('act_head.2.bias');

  final Float32List hiddenWeight;
  final Float32List hiddenBias;
  final Float32List outWeight;
  final Float32List outBias;
}

final class _LayerTensors {
  late final Pointer<ggml_tensor> norm1Weight, norm1Bias;
  late final Pointer<ggml_tensor> queryWeight, queryBias;
  late final Pointer<ggml_tensor> keyWeight, keyBias;
  late final Pointer<ggml_tensor> valueWeight, valueBias;
  late final Pointer<ggml_tensor> outWeight, outBias;
  late final Pointer<ggml_tensor> norm2Weight, norm2Bias;
  late final Pointer<ggml_tensor> linear1Weight, linear1Bias;
  late final Pointer<ggml_tensor> linear2Weight, linear2Bias;
}

/// The decision head as a ggml graph whose weights live on one device; the
/// act MLP runs in Dart.
final class DecisionHeadRuntime {
  DecisionHeadRuntime._(this._api, DecisionHeadWeights weights)
    : _hiddenSize = weights.hiddenSize,
      _heads = weights.heads,
      _graphSize = 64 + 64 * weights.layers,
      _typeEmbedding = weights._typeEmbedding,
      _act = weights._act;

  /// Uploads [weights] to a backend buffer and creates a scheduler.
  ///
  /// With [device] null or the CPU device the head runs on the CPU only.
  /// Otherwise its weights live on [device], and the scheduler lists [device]
  /// first and the CPU backend last. [cpuThreads] sets the CPU backend's
  /// thread count when that backend exposes `ggml_backend_set_n_threads`;
  /// [opOffload] is passed to `ggml_backend_sched_new`. [api] is the ggml
  /// function table the head calls, [GgmlGraphApi.current] by default. What
  /// was created before a failure is freed. Throws [ArgumentError] when
  /// [cpuThreads] is below 1, [LlamaUnsupportedException] when the native
  /// library does not export a ggml function the head calls, and
  /// [LlamaModelException] when a backend, the weights buffer or the
  /// scheduler cannot be created or filled.
  static DecisionHeadRuntime create(
    DecisionHeadWeights weights, {
    ggml_backend_dev_t? device,
    required int cpuThreads,
    required bool opOffload,
    GgmlGraphApi? api,
  }) {
    if (cpuThreads < 1) {
      throw ArgumentError.value(cpuThreads, 'cpuThreads', 'must be at least 1');
    }
    final runtime = DecisionHeadRuntime._(api ?? GgmlGraphApi.current, weights);
    try {
      withGgmlGraphSymbols(
        () => runtime._initialize(weights, device, cpuThreads, opOffload),
      );
    } catch (_) {
      runtime.dispose();
      rethrow;
    }
    return runtime;
  }

  final GgmlGraphApi _api;
  final int _hiddenSize;
  final int _heads;
  final int _graphSize;
  final Float32List _typeEmbedding;
  final _ActWeights _act;
  final List<_LayerTensors> _layers = [];
  late final Pointer<ggml_tensor> _scorerNormWeight, _scorerNormBias;
  late final Pointer<ggml_tensor> _scorerHiddenWeight, _scorerHiddenBias;
  late final Pointer<ggml_tensor> _scorerOutWeight, _scorerOutBias;

  ggml_backend_t _cpuBackend = nullptr;
  ggml_backend_t _deviceBackend = nullptr;
  Pointer<ggml_context> _weightsContext = nullptr;
  ggml_backend_buffer_t _weightsBuffer = nullptr;
  ggml_backend_sched_t _sched = nullptr;
  String _deviceName = '';
  bool _disposed = false;

  /// Name of the backend holding the head's weights, such as `CPU` or `MTL0`.
  String get deviceName => _deviceName;

  void _initialize(
    DecisionHeadWeights weights,
    ggml_backend_dev_t? device,
    int cpuThreads,
    bool opOffload,
  ) {
    final api = _api;
    final cpuDevice = api.devByType(
      ggml_backend_dev_type.GGML_BACKEND_DEVICE_TYPE_CPU.value,
    );
    if (cpuDevice == nullptr) {
      throw LlamaModelException(
        'No ggml CPU device is registered; initialize the llama.cpp backend '
        'before loading a decision head.',
      );
    }
    _cpuBackend = api.devInit(cpuDevice, nullptr);
    if (_cpuBackend == nullptr) {
      throw LlamaModelException(
        'Could not start the ggml CPU backend for the decision head.',
      );
    }
    _setCpuThreads(cpuThreads);
    if (device != null && device != nullptr && device != cpuDevice) {
      _deviceBackend = api.devInit(device, nullptr);
      if (_deviceBackend == nullptr) {
        throw LlamaModelException(
          'Could not start the ggml backend of the model device for the '
          'decision head.',
        );
      }
    }
    final primary = _deviceBackend != nullptr ? _deviceBackend : _cpuBackend;
    _deviceName = api.backendName(primary).cast<Utf8>().toDartString();

    final uploads = <(Pointer<ggml_tensor>, Float32List)>[];
    final tensorCount = 16 * weights.layers + 6;
    _weightsContext = _newContext(api.tensorOverhead() * tensorCount);
    Pointer<ggml_tensor> vector(Float32List data) {
      final tensor = api.newTensor1d(
        _weightsContext,
        ggml_type.GGML_TYPE_F32.value,
        data.length,
      );
      uploads.add((tensor, data));
      return tensor;
    }

    Pointer<ggml_tensor> matrix(Float32List data, int columns) {
      final tensor = api.newTensor2d(
        _weightsContext,
        ggml_type.GGML_TYPE_F32.value,
        columns,
        data.length ~/ columns,
      );
      uploads.add((tensor, data));
      return tensor;
    }

    final d = _hiddenSize;
    for (final layer in weights._layerWeights) {
      Float32List part(Float32List data, int index, int size) =>
          Float32List.sublistView(data, index * size, (index + 1) * size);
      final inWeight = layer.inProjWeight;
      final inBias = layer.inProjBias;
      _layers.add(
        _LayerTensors()
          ..norm1Weight = vector(layer.norm1Weight)
          ..norm1Bias = vector(layer.norm1Bias)
          ..queryWeight = matrix(part(inWeight, 0, d * d), d)
          ..keyWeight = matrix(part(inWeight, 1, d * d), d)
          ..valueWeight = matrix(part(inWeight, 2, d * d), d)
          ..queryBias = vector(part(inBias, 0, d))
          ..keyBias = vector(part(inBias, 1, d))
          ..valueBias = vector(part(inBias, 2, d))
          ..outWeight = matrix(layer.outProjWeight, d)
          ..outBias = vector(layer.outProjBias)
          ..norm2Weight = vector(layer.norm2Weight)
          ..norm2Bias = vector(layer.norm2Bias)
          ..linear1Weight = matrix(layer.linear1Weight, d)
          ..linear1Bias = vector(layer.linear1Bias)
          ..linear2Weight = matrix(layer.linear2Weight, weights.ffnSize)
          ..linear2Bias = vector(layer.linear2Bias),
      );
    }
    final scorer = weights._scorer;
    _scorerNormWeight = vector(scorer.normWeight);
    _scorerNormBias = vector(scorer.normBias);
    _scorerHiddenWeight = matrix(scorer.hiddenWeight, d);
    _scorerHiddenBias = vector(scorer.hiddenBias);
    _scorerOutWeight = matrix(scorer.outWeight, d);
    _scorerOutBias = vector(scorer.outBias);

    final bufferType = api.defaultBufferType(primary);
    final alignment = api.buftGetAlignment(bufferType);
    int align(int offset) => (offset + alignment - 1) ~/ alignment * alignment;
    var total = 0;
    for (final (tensor, _) in uploads) {
      total = align(total) + api.buftGetAllocSize(bufferType, tensor);
    }
    total = align(total);
    _weightsBuffer = api.buftAllocBuffer(bufferType, total);
    if (_weightsBuffer == nullptr) {
      throw LlamaModelException(
        'Could not allocate $total bytes for decision head weights on '
        '$_deviceName.',
      );
    }
    api.bufferSetUsage(
      _weightsBuffer,
      ggml_backend_buffer_usage.GGML_BACKEND_BUFFER_USAGE_WEIGHTS.value,
    );
    final base = api.bufferGetBase(_weightsBuffer).address;
    var offset = 0;
    final largest = uploads.fold(0, (size, e) => math.max(size, e.$2.length));
    final staging = malloc<Float>(math.max(1, largest));
    try {
      for (final (tensor, data) in uploads) {
        offset = align(offset);
        final status = api.tensorAlloc(
          _weightsBuffer,
          tensor,
          Pointer.fromAddress(base + offset),
        );
        if (status != ggml_status.GGML_STATUS_SUCCESS.value) {
          throw LlamaModelException(
            'Could not place a decision head tensor in its $_deviceName '
            'buffer (ggml status $status).',
          );
        }
        offset += api.buftGetAllocSize(bufferType, tensor);
        staging.asTypedList(data.length).setAll(0, data);
        api.tensorSet(tensor, staging.cast(), 0, data.lengthInBytes);
      }
    } finally {
      malloc.free(staging);
    }

    final backends = calloc<ggml_backend_t>(2);
    try {
      var count = 0;
      if (_deviceBackend != nullptr) backends[count++] = _deviceBackend;
      backends[count++] = _cpuBackend;
      _sched = api.schedNew(
        backends,
        nullptr,
        count,
        math.max(2048, _graphSize),
        false,
        opOffload,
      );
    } finally {
      calloc.free(backends);
    }
    if (_sched == nullptr) {
      throw LlamaModelException(
        'Could not create the ggml scheduler for the decision head on '
        '$_deviceName.',
      );
    }
  }

  void _setCpuThreads(int threads) {
    final api = _api;
    final registry = api.devBackendReg(api.backendGetDevice(_cpuBackend));
    final name = 'ggml_backend_set_n_threads'.toNativeUtf8();
    try {
      final setThreads = api.regGetProcAddress(registry, name.cast());
      if (setThreads == nullptr) return;
      setThreads
          .cast<NativeFunction<Void Function(ggml_backend_t, Int)>>()
          .asFunction<void Function(ggml_backend_t, int)>()(
        _cpuBackend,
        threads,
      );
    } finally {
      malloc.free(name);
    }
  }

  Pointer<ggml_context> _newContext(int bytes) {
    final params = calloc<ggml_init_params>();
    try {
      params.ref
        ..mem_size = bytes
        ..mem_buffer = nullptr
        ..no_alloc = true;
      return _api.init(params.ref);
    } finally {
      calloc.free(params);
    }
  }

  /// Runs the head on the encoder output of one sequence.
  ///
  /// [hidden] is the encoder's last hidden state, row-major
  /// `[tokenCount, hiddenSize]`. [questionType] (0 choice, 1 score, 2 noul)
  /// selects the `type_emb` row, and [markers] holds at least one option
  /// position in `[0, tokenCount)`. Returns one raw logit per marker and the
  /// act-head logits. Throws [ArgumentError] for inputs outside these bounds,
  /// [LlamaInferenceException] when the graph cannot be allocated or computed,
  /// [LlamaUnsupportedException] when the native library does not export a
  /// ggml function the head calls, and [LlamaStateException] after [dispose].
  BackendDecisionOutput run(
    Float32List hidden,
    int tokenCount,
    int questionType,
    Int32List markers,
  ) {
    if (_disposed) {
      throw LlamaStateException('The decision head has been freed.');
    }
    if (tokenCount < 1 || hidden.length != tokenCount * _hiddenSize) {
      throw ArgumentError(
        'Decision head input has ${hidden.length} values for $tokenCount '
        'tokens of width $_hiddenSize.',
      );
    }
    if (questionType < 0 || questionType > 2) {
      throw ArgumentError.value(questionType, 'questionType', 'must be 0..2');
    }
    if (markers.isEmpty || markers.any((m) => m < 0 || m >= tokenCount)) {
      throw ArgumentError.value(
        markers,
        'markers',
        'must hold at least one position in [0, $tokenCount)',
      );
    }
    final (logits, cls) = withGgmlGraphSymbols(
      () => _computeGraph(hidden, tokenCount, questionType, markers),
    );
    return BackendDecisionOutput(
      logits: logits,
      actLogits: _actLogits(cls, logits),
    );
  }

  (Float32List, Float32List) _computeGraph(
    Float32List hidden,
    int tokenCount,
    int questionType,
    Int32List markers,
  ) {
    final api = _api;
    final d = _hiddenSize;
    final n = tokenCount;
    final headSize = d ~/ _heads;
    final rowCount = markers.length + 1;
    final g = _newContext(
      api.tensorOverhead() * _graphSize +
          api.graphOverheadCustom(_graphSize, false),
    );
    try {
      Pointer<ggml_tensor> norm(
        Pointer<ggml_tensor> x,
        Pointer<ggml_tensor> weight,
        Pointer<ggml_tensor> bias,
      ) => api.add(
        g,
        api.mul(g, api.norm(g, x, _layerNormEpsilon), weight),
        bias,
      );
      Pointer<ggml_tensor> linear(
        Pointer<ggml_tensor> x,
        Pointer<ggml_tensor> weight,
        Pointer<ggml_tensor> bias,
      ) => api.add(g, api.mulMat(g, weight, x), bias);
      Pointer<ggml_tensor> splitHeads(Pointer<ggml_tensor> x) =>
          api.permute(g, api.reshape3d(g, x, headSize, _heads, n), 0, 2, 1, 3);

      final f32 = ggml_type.GGML_TYPE_F32.value;
      final hiddenInput = api.newTensor2d(g, f32, d, n);
      final typeInput = api.newTensor1d(g, f32, d);
      final rowsInput = api.newTensor1d(
        g,
        ggml_type.GGML_TYPE_I32.value,
        rowCount,
      );
      for (final input in [hiddenInput, typeInput, rowsInput]) {
        api.setInput(input);
      }

      var x = api.add(g, hiddenInput, typeInput);
      for (final layer in _layers) {
        final a = norm(x, layer.norm1Weight, layer.norm1Bias);
        final q = splitHeads(linear(a, layer.queryWeight, layer.queryBias));
        final k = splitHeads(linear(a, layer.keyWeight, layer.keyBias));
        final v = splitHeads(linear(a, layer.valueWeight, layer.valueBias));
        final scores = api.softMaxExt(
          g,
          api.mulMat(g, k, q),
          nullptr,
          1 / math.sqrt(headSize),
          0,
        );
        final attended = api.mulMat(
          g,
          api.cont(g, api.transpose(g, v)),
          scores,
        );
        final merged = api.cont2d(
          g,
          api.permute(g, attended, 0, 2, 1, 3),
          d,
          n,
        );
        x = api.add(g, x, linear(merged, layer.outWeight, layer.outBias));
        final ff = norm(x, layer.norm2Weight, layer.norm2Bias);
        x = api.add(
          g,
          x,
          linear(
            api.relu(g, linear(ff, layer.linear1Weight, layer.linear1Bias)),
            layer.linear2Weight,
            layer.linear2Bias,
          ),
        );
      }
      final rows = api.getRows(g, x, rowsInput);
      api.setOutput(rows);
      var scores = norm(rows, _scorerNormWeight, _scorerNormBias);
      scores = api.geluErf(
        g,
        linear(scores, _scorerHiddenWeight, _scorerHiddenBias),
      );
      scores = linear(scores, _scorerOutWeight, _scorerOutBias);
      api.setOutput(scores);

      final graph = api.newGraphCustom(g, _graphSize, false);
      api.buildForwardExpand(graph, scores);
      api.buildForwardExpand(graph, rows);
      api.schedReset(_sched);
      if (!api.schedAllocGraph(_sched, graph)) {
        throw LlamaInferenceException(
          'Could not allocate decision head compute buffers on $_deviceName '
          'for $n tokens.',
        );
      }

      final staging = malloc<Float>(math.max(n * d, rowCount));
      try {
        final values = staging.asTypedList(n * d)..setAll(0, hidden);
        api.tensorSet(hiddenInput, staging.cast(), 0, values.lengthInBytes);
        staging
            .asTypedList(d)
            .setAll(
              0,
              Float32List.sublistView(
                _typeEmbedding,
                questionType * d,
                (questionType + 1) * d,
              ),
            );
        api.tensorSet(typeInput, staging.cast(), 0, d * 4);
        staging.cast<Int32>().asTypedList(rowCount)
          ..[0] = 0
          ..setAll(1, markers);
        api.tensorSet(rowsInput, staging.cast(), 0, rowCount * 4);

        final status = api.schedGraphCompute(_sched, graph);
        if (status != ggml_status.GGML_STATUS_SUCCESS.value) {
          throw LlamaInferenceException(
            'Decision head compute failed on $_deviceName (ggml status '
            '$status).',
          );
        }
        api.tensorGet(scores, staging.cast(), 0, rowCount * 4);
        final logits = Float32List.fromList(
          staging.asTypedList(rowCount).sublist(1),
        );
        api.tensorGet(rows, staging.cast(), 0, d * 4);
        final cls = Float32List.fromList(staging.asTypedList(d));
        return (logits, cls);
      } finally {
        malloc.free(staging);
      }
    } finally {
      api.free(g);
    }
  }

  Float32List _actLogits(Float32List cls, Float32List logits) {
    final d = _hiddenSize;
    final inputs = Float64List(d + 4)
      ..setAll(0, cls)
      ..setAll(d, decisionActFeatures(logits));
    final hiddenWeight = _act.hiddenWeight;
    final hiddenBias = _act.hiddenBias;
    final hidden = Float64List(hiddenBias.length);
    for (var j = 0; j < hidden.length; j++) {
      var sum = hiddenBias[j].toDouble();
      final row = j * inputs.length;
      for (var i = 0; i < inputs.length; i++) {
        sum += hiddenWeight[row + i] * inputs[i];
      }
      hidden[j] = 0.5 * sum * (1 + decisionErf(sum / math.sqrt2));
    }
    final outWeight = _act.outWeight;
    final outBias = _act.outBias;
    final result = Float32List(outBias.length);
    for (var c = 0; c < result.length; c++) {
      var sum = outBias[c].toDouble();
      final row = c * hidden.length;
      for (var j = 0; j < hidden.length; j++) {
        sum += outWeight[row + j] * hidden[j];
      }
      result[c] = sum;
    }
    return result;
  }

  /// Synchronizes and frees the scheduler, then frees the weights and the
  /// backends.
  ///
  /// Later [run] calls throw; disposing again does nothing.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final api = _api;
    if (_sched != nullptr) {
      api.schedSynchronize(_sched);
      api.schedFree(_sched);
      _sched = nullptr;
    }
    if (_weightsBuffer != nullptr) {
      api.bufferFree(_weightsBuffer);
      _weightsBuffer = nullptr;
    }
    if (_weightsContext != nullptr) {
      api.free(_weightsContext);
      _weightsContext = nullptr;
    }
    if (_deviceBackend != nullptr) {
      api.backendFree(_deviceBackend);
      _deviceBackend = nullptr;
    }
    if (_cpuBackend != nullptr) {
      api.backendFree(_cpuBackend);
      _cpuBackend = nullptr;
    }
  }
}

/// The error function, ported from fdlibm's `s_erf.c`.
double decisionErf(double x) {
  _erfBits.setFloat64(0, x);
  final high = _erfBits.getInt32(0);
  final ix = high & 0x7fffffff;
  if (ix >= 0x7ff00000) {
    if (x.isNaN) return x;
    return x > 0 ? 1.0 : -1.0;
  }
  if (ix < 0x3feb0000) {
    if (ix < 0x3e300000) {
      if (ix < 0x00800000) return 0.125 * (8.0 * x + _efx8 * x);
      return x + _efx * x;
    }
    final z = x * x;
    final r = _pp0 + z * (_pp1 + z * (_pp2 + z * (_pp3 + z * _pp4)));
    final s =
        1.0 + z * (_qq1 + z * (_qq2 + z * (_qq3 + z * (_qq4 + z * _qq5))));
    return x + x * (r / s);
  }
  if (ix < 0x3ff40000) {
    final s = x.abs() - 1.0;
    final p =
        _pa0 +
        s *
            (_pa1 +
                s * (_pa2 + s * (_pa3 + s * (_pa4 + s * (_pa5 + s * _pa6)))));
    final q =
        1.0 +
        s *
            (_qa1 +
                s * (_qa2 + s * (_qa3 + s * (_qa4 + s * (_qa5 + s * _qa6)))));
    return high >= 0 ? _erx + p / q : -_erx - p / q;
  }
  if (ix >= 0x40180000) return high >= 0 ? 1.0 - _tiny : _tiny - 1.0;
  final ax = x.abs();
  final s = 1.0 / (ax * ax);
  final double r;
  final double t;
  if (ix < 0x4006db6e) {
    r =
        _ra0 +
        s *
            (_ra1 +
                s *
                    (_ra2 +
                        s *
                            (_ra3 +
                                s *
                                    (_ra4 +
                                        s * (_ra5 + s * (_ra6 + s * _ra7))))));
    t =
        1.0 +
        s *
            (_sa1 +
                s *
                    (_sa2 +
                        s *
                            (_sa3 +
                                s *
                                    (_sa4 +
                                        s *
                                            (_sa5 +
                                                s *
                                                    (_sa6 +
                                                        s *
                                                            (_sa7 +
                                                                s * _sa8)))))));
  } else {
    r =
        _rb0 +
        s *
            (_rb1 +
                s * (_rb2 + s * (_rb3 + s * (_rb4 + s * (_rb5 + s * _rb6)))));
    t =
        1.0 +
        s *
            (_sb1 +
                s *
                    (_sb2 +
                        s *
                            (_sb3 +
                                s *
                                    (_sb4 +
                                        s * (_sb5 + s * (_sb6 + s * _sb7))))));
  }
  _erfBits
    ..setFloat64(0, ax)
    ..setUint32(4, 0);
  final z = _erfBits.getFloat64(0);
  final e = math.exp(-z * z - 0.5625) * math.exp((z - ax) * (z + ax) + r / t);
  return high >= 0 ? 1.0 - e / ax : e / ax - 1.0;
}

final ByteData _erfBits = ByteData(8);

const double _tiny = 1e-300;
const double _erx = 8.45062911510467529297e-01;
const double _efx = 1.28379167095512586316e-01;
const double _efx8 = 1.02703333676410069053e+00;
const double _pp0 = 1.28379167095512558561e-01;
const double _pp1 = -3.25042107247001499370e-01;
const double _pp2 = -2.84817495755985104766e-02;
const double _pp3 = -5.77027029648944159157e-03;
const double _pp4 = -2.37630166566501626084e-05;
const double _qq1 = 3.97917223959155352819e-01;
const double _qq2 = 6.50222499887672944485e-02;
const double _qq3 = 5.08130628187576562776e-03;
const double _qq4 = 1.32494738004321644526e-04;
const double _qq5 = -3.96022827877536812320e-06;
const double _pa0 = -2.36211856075265944077e-03;
const double _pa1 = 4.14856118683748331666e-01;
const double _pa2 = -3.72207876035701323847e-01;
const double _pa3 = 3.18346619901161753674e-01;
const double _pa4 = -1.10894694282396677476e-01;
const double _pa5 = 3.54783043256182359371e-02;
const double _pa6 = -2.16637559486879084300e-03;
const double _qa1 = 1.06420880400844228286e-01;
const double _qa2 = 5.40397917702171048937e-01;
const double _qa3 = 7.18286544141962662868e-02;
const double _qa4 = 1.26171219808761642112e-01;
const double _qa5 = 1.36370839120290507362e-02;
const double _qa6 = 1.19844998467991074170e-02;
const double _ra0 = -9.86494403484714822705e-03;
const double _ra1 = -6.93858572707181764372e-01;
const double _ra2 = -1.05586262253232909814e+01;
const double _ra3 = -6.23753324503260060396e+01;
const double _ra4 = -1.62396669462573470355e+02;
const double _ra5 = -1.84605092906711035994e+02;
const double _ra6 = -8.12874355063065934246e+01;
const double _ra7 = -9.81432934416914548592e+00;
const double _sa1 = 1.96512716674392571292e+01;
const double _sa2 = 1.37657754143519042600e+02;
const double _sa3 = 4.34565877475229228821e+02;
const double _sa4 = 6.45387271733267880336e+02;
const double _sa5 = 4.29008140027567833386e+02;
const double _sa6 = 1.08635005541779435134e+02;
const double _sa7 = 6.57024977031928170135e+00;
const double _sa8 = -6.04244152148580987438e-02;
const double _rb0 = -9.86494292470009928597e-03;
const double _rb1 = -7.99283237680523006574e-01;
const double _rb2 = -1.77579549177547519889e+01;
const double _rb3 = -1.60636384855821916062e+02;
const double _rb4 = -6.37566443368389627722e+02;
const double _rb5 = -1.02509513161107724954e+03;
const double _rb6 = -4.83519191608651397019e+02;
const double _sb1 = 3.03380607434824582924e+01;
const double _sb2 = 3.25792512996573918826e+02;
const double _sb3 = 1.53672958608443695994e+03;
const double _sb4 = 3.19985821950859553908e+03;
const double _sb5 = 2.55305040643316442583e+03;
const double _sb6 = 4.74528541206955367215e+02;
const double _sb7 = -2.24409524465858183362e+01;
