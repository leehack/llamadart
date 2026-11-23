@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:dartpad_gguf_example/bridge_bootstrap_web.dart';
import 'package:flutter_test/flutter_test.dart';

const _assetGlobals = {
  '__llamadartBridgeCoreModuleUrlSt': 'llama_webgpu_core_st.js',
  '__llamadartBridgeWasmUrlSt': 'llama_webgpu_core_st.wasm',
  '__llamadartBridgeCoreModuleUrlMem64St': 'llama_webgpu_core_mem64_st.js',
  '__llamadartBridgeWasmUrlMem64St': 'llama_webgpu_core_mem64_st.wasm',
  '__llamadartBridgeWorkerUrl': 'llama_webgpu_bridge_worker.js',
};
const _optIn = '__llamadartBridgeAllowSingleThreadCore';
const _adaptive = '__llamadartBridgeAdaptiveSafariGpu';
const _error = '__llamadartBridgeLoadError';
const _constructor = 'LlamaWebGpuBridge';

void main() {
  setUp(() {
    final originals = {
      for (final key in [
        ..._assetGlobals.keys,
        _optIn,
        _adaptive,
        _error,
        _constructor,
      ])
        key: globalContext[key],
    };
    globalContext[_constructor] = null;
    addTearDown(() {
      for (final MapEntry(:key, :value) in originals.entries) {
        globalContext[key] = value;
      }
    });
  });

  test('installs absolute pinned URLs before importing the module', () async {
    final constructor = (() {}).toJS;
    constructor['supportsSafariAdaptiveGpu'] = true.toJS;
    final module = JSObject()..[_constructor] = constructor;
    final base = Uri.parse(
      'https://cdn.jsdelivr.net/gh/leehack/llama-web-bridge-assets@'
      '$defaultBridgeAssetsTag/',
    );
    await bootstrapBridge(
      importBridge: (url) async {
        expect(uriOf(url), base.resolve('llama_webgpu_bridge.js'));
        expect((globalContext[_optIn] as JSBoolean).toDart, isTrue);
        for (final MapEntry(:key, :value) in _assetGlobals.entries) {
          expect(
            uriOf((globalContext[key] as JSString).toDart),
            base.resolve(value),
          );
        }
        return module;
      },
    );
    expect(
      globalContext[_constructor].strictEquals(constructor).toDart,
      isTrue,
    );
    expect((globalContext[_adaptive] as JSBoolean).toDart, isTrue);
  });

  test('reuses an installed bridge and clears a stale load error', () async {
    globalContext[_constructor] = (() {}).toJS;
    globalContext[_error] = 'Stale error'.toJS;

    await bootstrapBridge(importBridge: (_) async => fail('Unexpected import'));
    expect((globalContext[_adaptive] as JSBoolean).toDart, isFalse);
    expect(globalContext[_error], isNull);
  });

  test('records import failure and allows another attempt', () async {
    final failure = StateError('Import unavailable');
    await expectLater(
      bootstrapBridge(importBridge: (_) async => throw failure),
      throwsA(same(failure)),
    );
    expect(
      (globalContext[_error] as JSString).toDart,
      contains(failure.message),
    );

    final module = JSObject()..[_constructor] = (() {}).toJS;
    await bootstrapBridge(importBridge: (_) async => module);
    expect(globalContext[_error], isNull);
  });

  test('rejects a module without a bridge constructor', () async {
    await expectLater(
      bootstrapBridge(importBridge: (_) async => JSObject()),
      throwsStateError,
    );
    expect((globalContext[_error] as JSString).toDart, contains(_constructor));
  });
}

Uri uriOf(String value) {
  final uri = Uri.parse(value);
  expect(uri.scheme, 'https');
  expect(uri.hasAuthority, isTrue);
  return uri;
}
