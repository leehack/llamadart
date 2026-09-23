@TestOn('vm')
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;
import 'dart:mirrors';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:llamadart/src/backends/llama_cpp/bindings.dart';
import 'package:llamadart/src/backends/llama_cpp/decision_head.dart';
import 'package:llamadart/src/backends/llama_cpp/ggml_graph_api.dart';
import 'package:llamadart/src/backends/llama_cpp/llama_cpp_service.dart';
import 'package:llamadart/src/backends/llama_cpp/safetensors.dart';
import 'package:llamadart/src/core/decision/decision_decoder.dart';
import 'package:llamadart/src/core/exceptions.dart';
import 'package:test/test.dart';

import '../../../support/safetensors_writer.dart';

void main() {
  late Directory dir;

  setUpAll(() => LlamaCppService().initializeBackend());

  setUp(() {
    dir = Directory.systemTemp.createTempSync('llamadart_decision_head_');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  SafetensorsFile writeHead(_SyntheticHead head, [String file = 'head']) {
    final path = '${dir.path}${Platform.pathSeparator}$file.safetensors';
    writeSafetensors(path, {
      for (final MapEntry(key: name, value: tensor) in head.tensors.entries)
        name: TestTensor.f32(tensor.shape, tensor.values),
    });
    final opened = SafetensorsFile.open(path);
    addTearDown(opened.close);
    return opened;
  }

  DecisionHeadRuntime createRuntime(
    _SyntheticHead head, {
    Map<String, Object?>? config,
  }) {
    final weights = DecisionHeadWeights.read(
      writeHead(head),
      hiddenSize: head.d,
      config: config ?? {'head_layers': head.layers},
    );
    final runtime = DecisionHeadRuntime.create(
      weights,
      cpuThreads: 2,
      opOffload: false,
    );
    addTearDown(runtime.dispose);
    return runtime;
  }

  void expectMatchesReference(
    DecisionHeadRuntime runtime,
    _SyntheticHead head, {
    required int tokens,
    required int questionType,
    required List<int> markers,
  }) {
    final hidden = head.randomHidden(tokens);
    final output = runtime.run(
      hidden,
      tokens,
      questionType,
      Int32List.fromList(markers),
    );
    final (logits, actLogits) = head.reference(hidden, questionType, markers);

    expect(output.logits, hasLength(markers.length));
    expect(output.actLogits, hasLength(_SyntheticHead.actClasses));
    for (var i = 0; i < logits.length; i++) {
      expect(output.logits[i], closeTo(logits[i], 1e-4), reason: 'logit $i');
    }
    for (var i = 0; i < actLogits.length; i++) {
      expect(
        output.actLogits[i],
        closeTo(actLogits[i], 1e-4 * math.max(1, actLogits[i].abs())),
        reason: 'act logit $i',
      );
    }
  }

  group('DecisionHeadRuntime', () {
    test('matches a pure-Dart reference with one attention head', () {
      final head = _SyntheticHead(d: 64, layers: 2, seed: 1);
      final runtime = createRuntime(head);

      expect(runtime.deviceName, 'CPU');
      for (final type in [0, 1, 2]) {
        expectMatchesReference(
          runtime,
          head,
          tokens: 12,
          questionType: type,
          markers: [3, 5, 8],
        );
      }
    });

    test('matches the reference with two heads, one layer and one option', () {
      final head = _SyntheticHead(d: 128, layers: 1, seed: 2);
      final runtime = createRuntime(head);

      expectMatchesReference(
        runtime,
        head,
        tokens: 7,
        questionType: 2,
        markers: [4],
      );
      expectMatchesReference(
        runtime,
        head,
        tokens: 1,
        questionType: 0,
        markers: [0],
      );
    });

    test('distinguishes question types through type_emb', () {
      final head = _SyntheticHead(d: 64, layers: 1, seed: 3);
      final runtime = createRuntime(head);
      final hidden = head.randomHidden(6);
      final markers = Int32List.fromList([2, 4]);

      final choice = runtime.run(hidden, 6, 0, markers).logits;
      final noul = runtime.run(hidden, 6, 2, markers).logits;

      expect(choice, isNot(orderedEquals(noul)));
    });

    test('runs on an explicitly passed CPU device', () {
      final head = _SyntheticHead(d: 64, layers: 1, seed: 4);
      final weights = DecisionHeadWeights.read(
        writeHead(head),
        hiddenSize: 64,
        config: const {'head_layers': 1},
      );
      final cpu = GgmlGraphApi.current.devByType(
        ggml_backend_dev_type.GGML_BACKEND_DEVICE_TYPE_CPU.value,
      );
      final runtime = DecisionHeadRuntime.create(
        weights,
        device: cpu,
        cpuThreads: 1,
        opOffload: true,
      );
      addTearDown(runtime.dispose);

      expect(runtime.deviceName, 'CPU');
      expectMatchesReference(
        runtime,
        head,
        tokens: 5,
        questionType: 1,
        markers: [1, 2, 3],
      );
    });

    test('rejects inputs outside the run contract', () {
      final head = _SyntheticHead(d: 64, layers: 1, seed: 5);
      final runtime = createRuntime(head);
      final hidden = head.randomHidden(4);

      expect(
        () => runtime.run(hidden, 5, 0, Int32List.fromList([1])),
        throwsArgumentError,
      );
      expect(
        () => runtime.run(hidden, 4, 3, Int32List.fromList([1])),
        throwsArgumentError,
      );
      expect(
        () => runtime.run(hidden, 4, 0, Int32List(0)),
        throwsArgumentError,
      );
      expect(
        () => runtime.run(hidden, 4, 0, Int32List.fromList([1, 4])),
        throwsArgumentError,
      );
      expect(
        () => runtime.run(hidden, 4, 0, Int32List.fromList([-1])),
        throwsArgumentError,
      );
    });

    test('rejects fewer than one CPU thread', () {
      final head = _SyntheticHead(d: 64, layers: 1, seed: 6);
      final weights = DecisionHeadWeights.read(
        writeHead(head),
        hiddenSize: 64,
        config: const {'head_layers': 1},
      );

      expect(
        () => DecisionHeadRuntime.create(
          weights,
          cpuThreads: 0,
          opOffload: false,
        ),
        throwsArgumentError,
      );
    });

    test('fails runs after dispose and disposes idempotently', () {
      final head = _SyntheticHead(d: 64, layers: 1, seed: 7);
      final runtime = createRuntime(head)
        ..dispose()
        ..dispose();

      expect(
        () => runtime.run(head.randomHidden(2), 2, 0, Int32List.fromList([1])),
        throwsA(isA<LlamaStateException>()),
      );
    });
  });

  group('DecisionHeadRuntime native resources', () {
    DecisionHeadWeights weightsOf(_SyntheticHead head) =>
        DecisionHeadWeights.read(
          writeHead(head),
          hiddenSize: head.d,
          config: {'head_layers': head.layers},
        );

    test('dispose frees everything create made, scheduler first', () {
      final ledger = _GgmlLedger();
      final head = _SyntheticHead(d: 64, layers: 1, seed: 20);
      final runtime = DecisionHeadRuntime.create(
        weightsOf(head),
        cpuThreads: 1,
        opOffload: false,
        api: ledger.api,
      );
      runtime.run(head.randomHidden(3), 3, 0, Int32List.fromList([1, 2]));
      expect(ledger.live, hasLength(4));
      final beforeDispose = ledger.events.length;

      runtime
        ..dispose()
        ..dispose();

      expect(ledger.live, isEmpty);
      expect(ledger.events.sublist(beforeDispose).map((e) => e.$1), [
        'schedSynchronize',
        'schedFree',
        'bufferFree',
        'free',
        'backendFree',
      ]);
    });

    test('create frees what it made when the scheduler fails', () {
      final ledger = _GgmlLedger(failSched: true);

      expect(
        () => DecisionHeadRuntime.create(
          weightsOf(_SyntheticHead(d: 64, layers: 1, seed: 21)),
          cpuThreads: 1,
          opOffload: false,
          api: ledger.api,
        ),
        throwsA(
          isA<LlamaModelException>().having(
            (error) => error.message,
            'message',
            contains('scheduler'),
          ),
        ),
      );
      expect(ledger.events.map((e) => e.$1), contains('bufferFree'));
      expect(ledger.live, isEmpty);
    });

    test('sets the CPU thread count through the CPU registry', () {
      final ledger = _GgmlLedger();
      final runtime = DecisionHeadRuntime.create(
        weightsOf(_SyntheticHead(d: 64, layers: 1, seed: 22)),
        cpuThreads: 3,
        opOffload: false,
        api: ledger.api,
      );
      addTearDown(runtime.dispose);

      expect(ledger.threadCounts, [3]);
    });

    test('starts one backend for an explicitly passed CPU device', () {
      final ledger = _GgmlLedger();
      final cpu = GgmlGraphApi.current.devByType(
        ggml_backend_dev_type.GGML_BACKEND_DEVICE_TYPE_CPU.value,
      );
      final runtime = DecisionHeadRuntime.create(
        weightsOf(_SyntheticHead(d: 64, layers: 1, seed: 23)),
        device: cpu,
        cpuThreads: 1,
        opOffload: true,
        api: ledger.api,
      );
      addTearDown(runtime.dispose);

      expect(ledger.events.where((e) => e.$1 == 'devInit'), hasLength(1));
      expect(ledger.schedulerBackends.single, hasLength(1));
    });

    test('schedules the device backend first and the CPU backend last', () {
      final ledger = _GgmlLedger(deviceStandIn: true);
      final head = _SyntheticHead(d: 64, layers: 1, seed: 24);
      final runtime = DecisionHeadRuntime.create(
        weightsOf(head),
        device: _GgmlLedger.standInDevice,
        cpuThreads: 1,
        opOffload: true,
        api: ledger.api,
      );
      final backends = ledger.events
          .where((e) => e.$1 == 'devInit')
          .map((e) => e.$2)
          .toList();

      expect(backends, hasLength(2));
      expect(ledger.schedulerBackends.single, [backends[1], backends[0]]);
      runtime.dispose();
      expect(ledger.live, isEmpty);
    });
  });

  group('DecisionHeadWeights.read', () {
    Matcher modelError(List<String> parts) => throwsA(
      isA<LlamaModelException>().having(
        (error) => error.message,
        'message',
        allOf([for (final part in parts) contains(part)]),
      ),
    );

    test('reports dimensions and ignores unrelated tensors', () {
      final head = _SyntheticHead(d: 128, layers: 2, seed: 8)
        ..tensors['encoder.embeddings.weight'] = _Tensor([2, 2], [1, 2, 3, 4])
        ..tensors['temperature'] = _Tensor([3], [1, 1, 1]);

      final weights = DecisionHeadWeights.read(
        writeHead(head),
        hiddenSize: 128,
        config: const {},
      );

      expect(weights.hiddenSize, 128);
      expect(weights.heads, 2);
      expect(weights.layers, 2);
      expect(weights.ffnSize, 512);
      expect(weights.actHiddenSize, 8);
      expect(weights.actClasses, 2);
    });

    test('names a missing tensor', () {
      final head = _SyntheticHead(d: 64, layers: 2, seed: 9)
        ..tensors.remove('head.layers.1.norm2.bias');
      final file = writeHead(head);

      expect(
        () => DecisionHeadWeights.read(file, hiddenSize: 64, config: const {}),
        modelError([file.path, '"head.layers.1.norm2.bias"']),
      );
    });

    test('names a mis-shaped tensor with expected and found shapes', () {
      final cases = [
        (
          'scorer.1.weight',
          _Tensor([64, 63], List.filled(64 * 63, 0.0)),
          ['[64, 63]', 'expected [64, 64]'],
        ),
        (
          'type_emb.weight',
          _Tensor([2, 64], List.filled(128, 0.0)),
          ['[2, 64]', 'expected [3, 64]'],
        ),
        (
          'head.layers.0.linear1.weight',
          _Tensor([256, 32], List.filled(256 * 32, 0.0)),
          ['[256, 32]', 'expected [ffn, 64]'],
        ),
        (
          'act_head.0.weight',
          _Tensor([8, 64], List.filled(8 * 64, 0.0)),
          ['[8, 64]', 'expected [act hidden, 68]'],
        ),
        (
          'act_head.0.weight',
          _Tensor([0, 68], const []),
          ['[0, 68]', 'act hidden >= 1'],
        ),
        ('act_head.2.bias', _Tensor([3], [0, 0, 0]), ['[3]', 'expected [2]']),
      ];
      for (final (index, (name, tensor, parts)) in cases.indexed) {
        final head = _SyntheticHead(d: 64, layers: 1, seed: 10)
          ..tensors[name] = tensor;
        final file = writeHead(head, 'case_$index');

        expect(
          () => DecisionHeadWeights.read(
            file,
            hiddenSize: 64,
            config: const {'head_layers': 1},
          ),
          modelError(['"$name"', ...parts]),
          reason: '$name $parts',
        );
      }
    });

    test('rejects a hidden size that does not match the head', () {
      final file = writeHead(_SyntheticHead(d: 64, layers: 1, seed: 11));

      expect(
        () => DecisionHeadWeights.read(
          file,
          hiddenSize: 128,
          config: const {'head_layers': 1},
        ),
        modelError(['"head.layers.0.linear1.weight"', 'expected [ffn, 128]']),
      );
    });

    test('rejects unusable head_layers and hidden sizes', () {
      final file = writeHead(_SyntheticHead(d: 64, layers: 2, seed: 12));

      for (final layers in [0, -1, '2', 1.5]) {
        expect(
          () => DecisionHeadWeights.read(
            file,
            hiddenSize: 64,
            config: {'head_layers': layers},
          ),
          modelError(['"head_layers" must be a positive integer', '$layers']),
        );
      }
      expect(
        () => DecisionHeadWeights.read(
          file,
          hiddenSize: 64,
          config: const {'head_layers': 1},
        ),
        modelError(['more than the 1 layers']),
      );
      expect(
        () => DecisionHeadWeights.read(file, hiddenSize: 0, config: const {}),
        modelError(['must be positive']),
      );
      expect(
        () => DecisionHeadWeights.read(file, hiddenSize: 129, config: const {}),
        modelError(['129', '2 attention heads']),
      );
    });
  });

  test('decisionErf matches correctly rounded values', () {
    final values = {
      0.0: 0.0,
      1e-10: 1.128379167095512573892398e-10,
      0.1: 0.1124629160182848922032751,
      -0.3: -0.328626759459127427638914,
      0.5: 0.5204998778130465376827467,
      0.84375: 0.7672256612323416334589782,
      1.0: 0.8427007929497148693412206,
      -1.0: -0.8427007929497148693412206,
      1.25: 0.9229001282564582301365235,
      2.0: 0.9953222650189527341620693,
      2.857142857142857: 0.9999466876886116771394024,
      3.0: 0.9999779095030014145586272,
      -3.0: -0.9999779095030014145586272,
      4.0: 0.9999999845827420997199811,
      5.9: 0.9999999999999999280959022,
    };
    for (final MapEntry(key: x, value: erf) in values.entries) {
      expect(
        decisionErf(x),
        closeTo(erf, erf.abs() * 3e-16),
        reason: 'erf($x)',
      );
    }
    expect(decisionErf(6.0), 1.0);
    expect(decisionErf(-40.0), -1.0);
    expect(decisionErf(double.infinity), 1.0);
    expect(decisionErf(double.negativeInfinity), -1.0);
    expect(decisionErf(double.nan).isNaN, isTrue);
    expect(decisionErf(5e-324), 5e-324);
  });
}

final class _Tensor {
  _Tensor(this.shape, List<double> values) : values = List.of(values);

  final List<int> shape;
  final List<double> values;
}

final class _SyntheticHead {
  _SyntheticHead({required this.d, required this.layers, required int seed})
    : _random = math.Random(seed) {
    final f = 4 * d;
    tensors['type_emb.weight'] = _uniform([3, d], 0.5);
    for (var i = 0; i < layers; i++) {
      final p = 'head.layers.$i';
      tensors
        ..['$p.self_attn.in_proj_weight'] = _uniform([
          3 * d,
          d,
        ], 1 / math.sqrt(d))
        ..['$p.self_attn.in_proj_bias'] = _uniform([3 * d], 0.1)
        ..['$p.self_attn.out_proj.weight'] = _uniform([d, d], 1 / math.sqrt(d))
        ..['$p.self_attn.out_proj.bias'] = _uniform([d], 0.1)
        ..['$p.linear1.weight'] = _uniform([f, d], 1 / math.sqrt(d))
        ..['$p.linear1.bias'] = _uniform([f], 0.1)
        ..['$p.linear2.weight'] = _uniform([d, f], 1 / math.sqrt(f))
        ..['$p.linear2.bias'] = _uniform([d], 0.1)
        ..['$p.norm1.weight'] = _uniform([d], 0.2, 1)
        ..['$p.norm1.bias'] = _uniform([d], 0.1)
        ..['$p.norm2.weight'] = _uniform([d], 0.2, 1)
        ..['$p.norm2.bias'] = _uniform([d], 0.1);
    }
    tensors
      ..['scorer.0.weight'] = _uniform([d], 0.2, 1)
      ..['scorer.0.bias'] = _uniform([d], 0.1)
      ..['scorer.1.weight'] = _uniform([d, d], 1 / math.sqrt(d))
      ..['scorer.1.bias'] = _uniform([d], 0.1)
      ..['scorer.3.weight'] = _uniform([1, d], 1 / math.sqrt(d))
      ..['scorer.3.bias'] = _uniform([1], 0.1)
      ..['act_head.0.weight'] = _uniform([actHidden, d + 4], 0.4)
      ..['act_head.0.bias'] = _uniform([actHidden], 0.1)
      ..['act_head.2.weight'] = _uniform([actClasses, actHidden], 0.5)
      ..['act_head.2.bias'] = _uniform([actClasses], 0.1);
  }

  static const int actHidden = 8;
  static const int actClasses = 2;

  final int d;
  final int layers;
  final math.Random _random;
  final Map<String, _Tensor> tensors = {};

  _Tensor _uniform(List<int> shape, double scale, [double center = 0]) {
    final count = shape.fold(1, (a, b) => a * b);
    return _Tensor(shape, [
      for (var i = 0; i < count; i++)
        _float(center + scale * (2 * _random.nextDouble() - 1)),
    ]);
  }

  Float32List randomHidden(int tokens) => Float32List.fromList([
    for (var i = 0; i < tokens * d; i++) 2 * _random.nextDouble() - 1,
  ]);

  List<double> _t(String name) => tensors[name]!.values;

  (List<double>, List<double>) reference(
    Float32List hidden,
    int questionType,
    List<int> markers,
  ) {
    final n = hidden.length ~/ d;
    final typeRow = _t(
      'type_emb.weight',
    ).sublist(questionType * d, (questionType + 1) * d);
    var x = [
      for (var i = 0; i < n; i++)
        [for (var j = 0; j < d; j++) hidden[i * d + j] + typeRow[j]],
    ];
    final heads = math.max(1, d ~/ 64);
    final size = d ~/ heads;
    for (var l = 0; l < layers; l++) {
      final p = 'head.layers.$l';
      final inW = _t('$p.self_attn.in_proj_weight');
      final inB = _t('$p.self_attn.in_proj_bias');
      final a = [
        for (final row in x)
          _layerNorm(row, _t('$p.norm1.weight'), _t('$p.norm1.bias')),
      ];
      final qkv = [for (final row in a) _linear(row, inW, inB)];
      final attended = [for (var i = 0; i < n; i++) List.filled(d, 0.0)];
      for (var h = 0; h < heads; h++) {
        for (var i = 0; i < n; i++) {
          final scores = [
            for (var j = 0; j < n; j++)
              [
                    for (var c = 0; c < size; c++)
                      qkv[i][h * size + c] * qkv[j][d + h * size + c],
                  ].reduce((s, v) => s + v) /
                  math.sqrt(size),
          ];
          final p = decisionSoftmax(scores);
          for (var j = 0; j < n; j++) {
            for (var c = 0; c < size; c++) {
              attended[i][h * size + c] += p[j] * qkv[j][2 * d + h * size + c];
            }
          }
        }
      }
      x = [
        for (var i = 0; i < n; i++)
          _add(
            x[i],
            _linear(
              attended[i],
              _t('$p.self_attn.out_proj.weight'),
              _t('$p.self_attn.out_proj.bias'),
            ),
          ),
      ];
      x = [
        for (final row in x)
          _add(
            row,
            _linear(
              _linear(
                _layerNorm(row, _t('$p.norm2.weight'), _t('$p.norm2.bias')),
                _t('$p.linear1.weight'),
                _t('$p.linear1.bias'),
              ).map((v) => math.max(0.0, v)).toList(),
              _t('$p.linear2.weight'),
              _t('$p.linear2.bias'),
            ),
          ),
      ];
    }
    final logits = [
      for (final m in markers)
        _linear(
          _linear(
            _layerNorm(x[m], _t('scorer.0.weight'), _t('scorer.0.bias')),
            _t('scorer.1.weight'),
            _t('scorer.1.bias'),
          ).map(_gelu).toList(),
          _t('scorer.3.weight'),
          _t('scorer.3.bias'),
        ).single,
    ];
    final actInput = [...x[0], ...decisionActFeatures(logits)];
    final actLogits = _linear(
      _linear(
        actInput,
        _t('act_head.0.weight'),
        _t('act_head.0.bias'),
      ).map(_gelu).toList(),
      _t('act_head.2.weight'),
      _t('act_head.2.bias'),
    );
    return (logits, actLogits);
  }
}

double _float(double value) => (Float32List(1)..[0] = value)[0];

double _gelu(double x) => 0.5 * x * (1 + decisionErf(x / math.sqrt2));

List<double> _add(List<double> a, List<double> b) => [
  for (var i = 0; i < a.length; i++) a[i] + b[i],
];

List<double> _linear(List<double> x, List<double> weight, List<double> bias) {
  final columns = x.length;
  return [
    for (var o = 0; o < bias.length; o++)
      bias[o] +
          [
            for (var i = 0; i < columns; i++) weight[o * columns + i] * x[i],
          ].reduce((s, v) => s + v),
  ];
}

List<double> _layerNorm(
  List<double> x,
  List<double> weight,
  List<double> bias,
) {
  final mean = x.reduce((s, v) => s + v) / x.length;
  final variance =
      x.map((v) => (v - mean) * (v - mean)).reduce((s, v) => s + v) / x.length;
  final scale = 1 / math.sqrt(variance + 1e-5);
  return [
    for (var i = 0; i < x.length; i++)
      (x[i] - mean) * scale * weight[i] + bias[i],
  ];
}

/// Records the ggml resources a [DecisionHeadRuntime] creates and frees.
final class _GgmlLedger {
  _GgmlLedger({bool failSched = false, bool deviceStandIn = false}) {
    final real = GgmlGraphApi.current;
    final cpu = real.devByType(
      ggml_backend_dev_type.GGML_BACKEND_DEVICE_TYPE_CPU.value,
    );
    T made<T extends Pointer>(String kind, T pointer) {
      events.add((kind, pointer.address));
      if (pointer != nullptr) live.add(pointer.address);
      return pointer;
    }

    void freed(String kind, Pointer pointer) {
      events.add((kind, pointer.address));
      live.remove(pointer.address);
    }

    _threads = NativeCallable<Void Function(ggml_backend_t, Int)>.isolateLocal(
      (ggml_backend_t backend, int threads) => threadCounts.add(threads),
    );
    api = _withOverrides(real, {
      #init: (ggml_init_params params) => made('init', real.init(params)),
      #free: (Pointer<ggml_context> context) {
        freed('free', context);
        real.free(context);
      },
      #devInit: (ggml_backend_dev_t device, Pointer<Char> params) => made(
        'devInit',
        real.devInit(
          deviceStandIn && device == standInDevice ? cpu : device,
          params,
        ),
      ),
      #backendFree: (ggml_backend_t backend) {
        freed('backendFree', backend);
        real.backendFree(backend);
      },
      #regGetProcAddress: (ggml_backend_reg_t registry, Pointer<Char> name) =>
          name.cast<Utf8>().toDartString() == 'ggml_backend_set_n_threads'
          ? _threads.nativeFunction.cast<Void>()
          : real.regGetProcAddress(registry, name),
      #buftAllocBuffer: (ggml_backend_buffer_type_t type, int size) =>
          made('bufferAlloc', real.buftAllocBuffer(type, size)),
      #bufferFree: (ggml_backend_buffer_t buffer) {
        freed('bufferFree', buffer);
        real.bufferFree(buffer);
      },
      #schedNew:
          (
            Pointer<ggml_backend_t> backends,
            Pointer<ggml_backend_buffer_type_t> types,
            int count,
            int graphSize,
            bool parallel,
            bool opOffload,
          ) {
            schedulerBackends.add([
              for (var i = 0; i < count; i++) backends[i].address,
            ]);
            return made(
              'schedNew',
              failSched
                  ? Pointer<ggml_backend_sched>.fromAddress(0)
                  : real.schedNew(
                      backends,
                      types,
                      count,
                      graphSize,
                      parallel,
                      opOffload,
                    ),
            );
          },
      #schedSynchronize: (ggml_backend_sched_t sched) {
        events.add(('schedSynchronize', sched.address));
        real.schedSynchronize(sched);
      },
      #schedFree: (ggml_backend_sched_t sched) {
        freed('schedFree', sched);
        real.schedFree(sched);
      },
    });
    addTearDown(_threads.close);
  }

  /// A device pointer that the ledger starts as a second CPU backend.
  static final ggml_backend_dev_t standInDevice = Pointer.fromAddress(8);

  late final GgmlGraphApi api;
  late final NativeCallable<Void Function(ggml_backend_t, Int)> _threads;
  final List<(String, int)> events = [];
  final Set<int> live = {};
  final List<int> threadCounts = [];
  final List<List<int>> schedulerBackends = [];

  static GgmlGraphApi _withOverrides(
    GgmlGraphApi base,
    Map<Symbol, Function> overrides,
  ) {
    final type = reflectClass(GgmlGraphApi);
    final instance = reflect(base);
    return type.newInstance(
          MirrorSystem.getSymbol('_', type.owner as LibraryMirror),
          const [],
          {
            for (final field
                in type.declarations.values.whereType<VariableMirror>())
              if (!field.isStatic)
                field.simpleName:
                    overrides[field.simpleName] ??
                    instance.getField(field.simpleName).reflectee,
          },
        ).reflectee
        as GgmlGraphApi;
  }
}
