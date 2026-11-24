@TestOn('browser')
@Tags(<String>['local-only', 'e2e'])
@Timeout(Duration(minutes: 10))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/litert_lm/litert_lm_embedding.dart';
import 'package:test/test.dart';
import 'package:web/web.dart';

import 'multimodal_embedding_litert_inputs.dart';

// Exercises upstream directly because the production adapter fails closed until
// every input meets the native CPU parity gate. No production bypass is exposed.
void main() {
  for (final backend in ['cpu', 'gpu']) {
    test(
      'pinned upstream Web ${backend.toUpperCase()} embeddings meet native CPU parity',
      () => _compareEmbeddings(backend),
    );
  }
}

Future<void> _compareEmbeddings(String backend) async {
  const origin = String.fromEnvironment(
    'LITERT_EMBEDDING_ORIGIN',
    defaultValue: 'http://127.0.0.1:5197',
  );
  const moduleUrl = 'https://cdn.jsdelivr.net/npm/@litert-lm/core@0.20.0/+esm';
  if (backend == 'gpu') {
    final gpu = globalContext
        .getProperty<JSObject>('navigator'.toJS)
        .getProperty<JSObject?>('gpu'.toJS);
    expect(
      gpu,
      isNotNull,
      reason: 'Launch Chrome with --enable-unsafe-webgpu.',
    );
    final adapter = await gpu!
        .callMethod<JSPromise<JSObject?>>('requestAdapter'.toJS)
        .toDart;
    expect(adapter, isNotNull, reason: 'A real WebGPU adapter is required.');
    final info = adapter!.getProperty<JSObject>('info'.toJS);
    print(
      'adapter: ${info.getProperty<JSString>('vendor'.toJS).toDart} '
      '${info.getProperty<JSString>('architecture'.toJS).toDart}',
    );
  }
  final loaded = Completer<void>();
  const callback = '__llamadartEmbeddingReferenceLoaded';
  globalContext.setProperty(callback.toJS, (() => loaded.complete()).toJS);
  final script = HTMLScriptElement()
    ..type = 'module'
    ..text =
        '''
import * as mod from '$moduleUrl';
window.__llamadartEmbeddingReference = mod;
window.$callback();
''';
  document.head!.append(script);
  addTearDown(() {
    script.remove();
    globalContext.delete(callback.toJS);
    globalContext.delete('__llamadartEmbeddingReference'.toJS);
  });
  await loaded.future.timeout(const Duration(seconds: 60));
  final module = globalContext.getProperty<JSObject>(
    '__llamadartEmbeddingReference'.toJS,
  );
  final backends = module.getProperty<JSObject>('Backend'.toJS);
  final selectedBackend = backends.getProperty<JSNumber>(
    backend.toUpperCase().toJS,
  );
  final cpu = backends.getProperty<JSNumber>('CPU'.toJS);
  final settings = JSObject()
    ..setProperty('model'.toJS, '$origin/model.litertlm'.toJS)
    ..setProperty('backend'.toJS, selectedBackend)
    ..setProperty('visionBackend'.toJS, cpu)
    ..setProperty('audioBackend'.toJS, cpu)
    ..setProperty('maxInputLength'.toJS, 1024.toJS);
  final constructor = module.getProperty<JSObject>('EmbeddingEngine'.toJS);
  late JSObject engine;
  try {
    engine = await constructor
        .callMethod<JSPromise<JSObject>>('create'.toJS, settings)
        .toDart;
  } catch (error) {
    print('Upstream engine creation failed: $error');
    rethrow;
  }
  addTearDown(() => engine.callMethod<JSPromise<JSAny?>>('delete'.toJS).toDart);
  final resolvedBackend = engine
      .getProperty<JSObject>('settings'.toJS)
      .getProperty<JSNumber>('backend'.toJS)
      .toDartInt;
  expect(resolvedBackend, selectedBackend.toDartInt);
  print(
    'module: $moduleUrl, backend: $backend ($resolvedBackend), browser: '
    '${window.navigator.userAgent}',
  );
  final overflow = JSObject()
    ..setProperty(
      'value'.toJS,
      module
          .getProperty<JSObject>('InputOverflowStrategy'.toJS)
          .getProperty<JSNumber>('ERROR'.toJS),
    );
  Future<List<double>> embed(LlamaEmbeddingInput input) async {
    final parts = prepareLiteRtLmEmbedding(input)
        .map<JSAny>((part) {
          if (part.type == 0) return utf8.decode(part.bytes).toJS;
          return JSObject()
            ..setProperty(
              'type'.toJS,
              (part.type == 1 ? 'image' : 'audio').toJS,
            )
            ..setProperty('data'.toJS, part.bytes.buffer.toJS);
        })
        .toList()
        .toJS;
    // The 0.20.0 wrapper passes the enum through to embind.
    final options = JSObject()
      ..setProperty('normalize'.toJS, true.toJS)
      ..setProperty('inputOverflowStrategy'.toJS, overflow);
    final response = await engine
        .callMethod<JSPromise<JSObject>>(
          'computeEmbedding'.toJS,
          parts,
          options,
        )
        .toDart;
    expect(response.getProperty<JSNumber>('numChunks'.toJS).toDartInt, 1);
    return response
        .getProperty<JSArray<JSNumber>>('embedding'.toJS)
        .toDart
        .map((v) => v.toDartDouble)
        .toList();
  }

  final vectors = <String, List<double>>{};
  for (final input in liteRtEmbeddingInputs().entries) {
    vectors[input.key] = await embed(input.value);
    expect(vectors[input.key], hasLength(768));
  }
  // Persist every vector before asserting so a failed gate retains all inputs.
  final receipt = await window
      .fetch(
        '$origin/results/$backend'.toJS,
        RequestInit(method: 'POST', body: jsonEncode(vectors).toJS),
      )
      .toDart;
  expect(receipt.ok, isTrue);
  final response = await window.fetch('$origin/native.json'.toJS).toDart;
  final native =
      jsonDecode((await response.text().toDart).toDart) as Map<String, dynamic>;
  final distances = <String, ({double cosine, double relL2})>{};
  for (final entry in vectors.entries) {
    final distance = embeddingDistance(
      (native[entry.key] as List).cast<num>().map((n) => n.toDouble()).toList(),
      entry.value,
    );
    distances[entry.key] = distance;
    print('${entry.key}: cosine=${distance.cosine}, relL2=${distance.relL2}');
  }
  final failed = distances.entries
      .where(
        (entry) => !(entry.value.cosine >= 0.9998 && entry.value.relL2 < 0.02),
      )
      .map((entry) => entry.key)
      .toList();
  print(
    'parity failures: ${failed.length}/${vectors.length}: ${failed.join(', ')}',
  );
  expect(
    failed,
    isEmpty,
    reason: 'Native CPU parity requires cosine >= 0.9998 and relative L2 < 2%.',
  );
}
