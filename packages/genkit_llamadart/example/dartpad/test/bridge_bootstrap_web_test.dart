@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:genkit_llamadart_dartpad_example/bridge_bootstrap_web.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';

const _assets = {
  '__llamadartBridgeCoreModuleUrlSt': 'llama_webgpu_core_st.js',
  '__llamadartBridgeWasmUrlSt': 'llama_webgpu_core_st.wasm',
  '__llamadartBridgeCoreModuleUrlMem64St': 'llama_webgpu_core_mem64_st.js',
  '__llamadartBridgeWasmUrlMem64St': 'llama_webgpu_core_mem64_st.wasm',
  '__llamadartBridgeWorkerUrl': 'llama_webgpu_bridge_worker.js',
};
const _optIn = '__llamadartBridgeAllowSingleThreadCore';
const _adaptive = '__llamadartBridgeAdaptiveSafariGpu';
const _constructor = 'LlamaWebGpuBridge';
const _liteRtModule = '__llamadartLiteRtLmModuleUrl';

void main() {
  setUp(() {
    final originals = {
      for (final key in [
        ..._assets.keys,
        _optIn,
        _adaptive,
        _constructor,
        _liteRtModule,
      ])
        key: globalContext[key],
    };
    addTearDown(() {
      for (final MapEntry(:key, :value) in originals.entries) {
        globalContext[key] = value;
      }
    });
  });

  test('installs absolute single-thread URLs and the bridge', () async {
    final constructor = (() {}).toJS;
    constructor['supportsSafariAdaptiveGpu'] = true.toJS;
    final base =
        'https://cdn.jsdelivr.net/npm/llama-web-bridge@'
        '${defaultBridgeAssetsTag.substring(1)}/dist/';

    await bootstrapBridge(
      importBridge: (url) async {
        expect(url, '${base}llama_webgpu_bridge.js');
        expect((globalContext[_optIn] as JSBoolean).toDart, isTrue);
        for (final MapEntry(:key, :value) in _assets.entries) {
          expect((globalContext[key] as JSString).toDart, '$base$value');
        }
        return JSObject()..[_constructor] = constructor;
      },
    );

    expect(
      globalContext[_constructor].strictEquals(constructor).toDart,
      isTrue,
    );
    expect((globalContext[_adaptive] as JSBoolean).toDart, isTrue);
  });

  test('configures LiteRT-LM without initializing the GGUF bridge', () async {
    final sentinel = JSObject();
    globalContext[_constructor] = sentinel;
    await bootstrapLiteRtLm();
    expect(
      (globalContext[_liteRtModule] as JSString).toDart,
      'https://cdn.jsdelivr.net/npm/@litert-lm/core@0.19.0/+esm',
    );
    expect(globalContext[_constructor].strictEquals(sentinel).toDart, isTrue);
  });

  test('reports a typed error for an unavailable bridge', () async {
    await expectLater(
      bootstrapBridge(importBridge: (_) async => throw StateError('CDN error')),
      throwsA(isA<LlamaUnsupportedException>()),
    );
    await expectLater(
      bootstrapBridge(importBridge: (_) async => JSObject()),
      throwsA(isA<LlamaUnsupportedException>()),
    );
  });
}
