@TestOn('browser')
@Tags(['local-only', 'e2e'])
@Timeout(Duration(minutes: 20))
library;

import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/webgpu/interop.dart';
import 'package:llamadart/src/backends/webgpu/webgpu_backend.dart';
import 'package:test/test.dart';
import 'package:web/web.dart' show window;

import '../../support/embedding_contract.dart';

// Local assets/reference only; setup and recorded qualification are documented in
// doc/multimodal_embeddings_web.md. No default model or network download.
void main() {
  test('scenario contract compares vector elements in reverse order', () {
    _expectOrderedVectors(
      [
        [3.0, 4.0],
        [1.0, 2.0],
      ],
      [
        [3.0, 4.0],
        [1.0, 2.0],
      ],
    );
    expect(
      () => _expectOrderedVectors(
        [
          [1.0, 2.0],
        ],
        [
          [2.0, 1.0],
        ],
      ),
      throwsA(isA<TestFailure>()),
    );
  });
  test('scenario contract rejects missing or extra vectors', () {
    for (final actual in <List<List<double>>>[
      [],
      [
        [1.0],
        [2.0],
      ],
    ]) {
      expect(
        () => _expectOrderedVectors(actual, [
          [1.0],
        ]),
        throwsA(isA<TestFailure>()),
      );
    }
  });
  test('scenario contract configures memory64 with the bridge API keys', () {
    final config = _bridgeConfig(true, (key) => key);
    expect(
      config.getProperty<JSString>('coreModuleUrlMem64'.toJS).toDart,
      'coreMem64',
    );
    expect(
      config.getProperty<JSString>('wasmUrlMem64'.toJS).toDart,
      'wasmMem64',
    );
    expect(config.getProperty<JSBoolean>('preferMemory64'.toJS).toDart, isTrue);
  });
  final configUrl = Uri.base.resolve(
    '../../../build/webgpu_embeddings_e2e/config.json',
  );
  Future<JSAny?> fetch(String url) async {
    final response = await window.fetch(url.toJS).toDart;
    expect(response.ok, isTrue, reason: 'Local embedding fixture unavailable.');
    return response;
  }

  for (final worker in [false, true]) {
    test(
      '${worker ? 'worker' : 'direct'} local media reference qualification',
      () async {
        final response = await fetch(configUrl.toString());
        final text = await (response as JSObject)
            .callMethod<JSPromise<JSString>>('text'.toJS)
            .toDart;
        final config = jsonDecode(text.toDart) as Map<String, dynamic>;
        String url(String key) =>
            configUrl.resolve(config[key] as String).toString();
        final module = await importModule(url('bridge').toJS).toDart;
        final constructor = module.getProperty<JSFunction>(
          'LlamaWebGpuBridge'.toJS,
        );
        final bridgeConfig = _bridgeConfig(worker, url);
        final bridge = constructor.callAsConstructor<LlamaWebGpuBridge>(
          bridgeConfig,
        );
        final engine = LlamaEngine(
          WebGpuLlamaBackend(bridgeFactory: ([config]) => bridge),
        );
        addTearDown(engine.dispose);
        await engine.loadModelFromUrl(
          url('model'),
          modelParams: const ModelParams(
            contextSize: 4096,
            batchSize: 4096,
            microBatchSize: 4096,
            gpuLayers: 0,
          ),
        );
        final core = (await engine
            .getMetadata())['llamadart.webgpu.core_variant'];
        print('${worker ? 'worker' : 'direct'} embedding core: $core');
        expect(
          core,
          'wasm64',
          reason: 'Repeated media batches require memory64.',
        );
        await engine.loadMultimodalProjector(url('projector'));
        expect(
          (bridge as JSObject).getProperty<JSAny?>('_workerProxy'.toJS) != null,
          worker,
          reason: 'Worker fallback must not count as worker qualification.',
        );
        final caps = await engine.embeddingCapabilities;
        expect([caps.text, caps.image, caps.audio], [true, true, true]);
        Future<Uint8List> bytes(String key) async {
          final response = (await fetch(url(key)))! as JSObject;
          final buffer = await response
              .callMethod<JSPromise<JSArrayBuffer>>('arrayBuffer'.toJS)
              .toDart;
          return buffer.toDart.asUint8List();
        }

        final image = LlamaImageContent(bytes: await bytes('image'));
        final audio = LlamaAudioContent(bytes: await bytes('audio'));
        final inputs = [
          LlamaEmbeddingInput([LlamaTextContent(config['text'] as String)]),
          LlamaEmbeddingInput([image]),
          LlamaEmbeddingInput([audio]),
          LlamaEmbeddingInput([
            const LlamaTextContent('first '),
            image,
            const LlamaTextContent(' between '),
            audio,
            const LlamaTextContent(' last '),
          ]),
        ];
        final actual = await engine.embedContentBatch(inputs);
        final expected = (config['normalizedVectors'] as List)
            .map(
              (row) => (row as List).map((v) => (v as num).toDouble()).toList(),
            )
            .toList();
        expect(expected, hasLength(inputs.length));
        for (var i = 0; i < inputs.length; i++) {
          expect(actual[i], hasLength(expected[i].length));
          double dot = 0, aa = 0, bb = 0;
          for (var j = 0; j < actual[i].length; j++) {
            expect(actual[i][j].isFinite, isTrue);
            dot += actual[i][j] * expected[i][j];
            aa += actual[i][j] * actual[i][j];
            bb += expected[i][j] * expected[i][j];
          }
          expect(math.sqrt(aa), closeTo(1, 1e-5));
          // Qualified CPU wasm/native cosine exceeds 0.99998. Keep a portable
          // gate; changes require exact-artifact evidence.
          expect(dot / math.sqrt(aa * bb), greaterThanOrEqualTo(0.999));
        }
        expect(
          await engine.embedContent(inputs.first),
          orderedEquals(actual.first),
        );
        final reversed = await engine.embedContentBatch(
          inputs.reversed.toList(),
        );
        _expectOrderedVectors(reversed, actual.reversed.toList());
        final raw = await engine.embedContentBatch(inputs, normalize: false);
        for (var i = 0; i < raw.length; i++) {
          final norm = math.sqrt(raw[i].fold<double>(0, (s, x) => s + x * x));
          for (var j = 0; j < raw[i].length; j++) {
            expect(raw[i][j] / norm, closeTo(actual[i][j], 1e-5));
          }
        }
        await expectAdjacentTextEmbeddingEquivalence(
          engine.embedContent,
          before: [image],
          after: [audio],
        );
      },
    );
  }
}

JSObject _bridgeConfig(bool worker, String Function(String) url) {
  return JSObject()
    ..setProperty('disableWorker'.toJS, (!worker).toJS)
    ..setProperty('workerUrl'.toJS, url('worker').toJS)
    ..setProperty('coreModuleUrl'.toJS, url('core').toJS)
    ..setProperty('wasmUrl'.toJS, url('wasm').toJS)
    ..setProperty('coreModuleUrlMem64'.toJS, url('coreMem64').toJS)
    ..setProperty('wasmUrlMem64'.toJS, url('wasmMem64').toJS)
    ..setProperty('preferMemory64'.toJS, true.toJS);
}

void _expectOrderedVectors(
  List<List<double>> actual,
  List<List<double>> expected,
) {
  expect(actual, hasLength(expected.length));
  for (var i = 0; i < actual.length; i++) {
    expect(actual[i], orderedEquals(expected[i]));
  }
}
