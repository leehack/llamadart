import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:llamadart/llamadart.dart';

const String defaultBridgeAssetsTag = 'v0.1.95';
final _assetBase =
    'https://cdn.jsdelivr.net/npm/llama-web-bridge@'
    '${defaultBridgeAssetsTag.substring(1)}/dist/';

Future<JSObject> _importBridge(String url) => importModule(url.toJS).toDart;

Future<void> bootstrapBridge({
  Future<JSObject> Function(String url) importBridge = _importBridge,
}) async {
  // The preview iframe has no app asset directory.
  const assets = {
    'CoreModuleUrlSt': 'llama_webgpu_core_st.js',
    'WasmUrlSt': 'llama_webgpu_core_st.wasm',
    'CoreModuleUrlMem64St': 'llama_webgpu_core_mem64_st.js',
    'WasmUrlMem64St': 'llama_webgpu_core_mem64_st.wasm',
    'WorkerUrl': 'llama_webgpu_bridge_worker.js',
  };
  for (final MapEntry(:key, :value) in assets.entries) {
    globalContext['__llamadartBridge$key'] = '$_assetBase$value'.toJS;
  }

  final module = await importBridge('${_assetBase}llama_webgpu_bridge.js')
      .onError((Object _, StackTrace _) {
        throw LlamaUnsupportedException(
          'Could not load the Web bridge. Check access to cdn.jsdelivr.net.',
        );
      });
  final constructor = module['LlamaWebGpuBridge'];
  if (!constructor.isA<JSFunction>()) {
    throw LlamaUnsupportedException('The Web bridge has no constructor.');
  }
  globalContext['LlamaWebGpuBridge'] = constructor;
  globalContext['__llamadartBridgeAdaptiveSafariGpu'] =
      (constructor as JSObject)['supportsSafariAdaptiveGpu'];
}
