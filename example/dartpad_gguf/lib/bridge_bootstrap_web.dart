import 'dart:js_interop';
import 'dart:js_interop_unsafe';

const String defaultBridgeAssetsTag = 'v0.1.93';
const _assetBase =
    'https://cdn.jsdelivr.net/gh/leehack/llama-web-bridge-assets@'
    '$defaultBridgeAssetsTag/';

const _constructor = 'LlamaWebGpuBridge';
const _loadError = '__llamadartBridgeLoadError';

Future<JSObject> _importBridge(String url) async =>
    await importModule(url.toJS).toDart;

Future<void> bootstrapBridge({
  Future<JSObject> Function(String url) importBridge = _importBridge,
}) async {
  // DartPad runs the app in an about:srcdoc frame with no app asset directory.
  const assets = {
    '__llamadartBridgeCoreModuleUrlSt': 'llama_webgpu_core_st.js',
    '__llamadartBridgeWasmUrlSt': 'llama_webgpu_core_st.wasm',
    '__llamadartBridgeCoreModuleUrlMem64St': 'llama_webgpu_core_mem64_st.js',
    '__llamadartBridgeWasmUrlMem64St': 'llama_webgpu_core_mem64_st.wasm',
    '__llamadartBridgeWorkerUrl': 'llama_webgpu_bridge_worker.js',
  };
  for (final MapEntry(:key, :value) in assets.entries) {
    globalContext[key] = '$_assetBase$value'.toJS;
  }
  globalContext['__llamadartBridgeAllowSingleThreadCore'] = true.toJS;

  try {
    var constructor = globalContext[_constructor];
    if (!constructor.isA<JSFunction>()) {
      final module = await importBridge('${_assetBase}llama_webgpu_bridge.js');
      constructor = module[_constructor];
      if (!constructor.isA<JSFunction>()) {
        throw StateError('The bridge module has no LlamaWebGpuBridge export.');
      }
      globalContext[_constructor] = constructor;
    }
    final adaptive = (constructor as JSObject)['supportsSafariAdaptiveGpu'];
    globalContext['__llamadartBridgeAdaptiveSafariGpu'] =
        (adaptive.isA<JSBoolean>() && (adaptive as JSBoolean).toDart).toJS;
    globalContext[_loadError] = null;
  } catch (error) {
    globalContext[_loadError] = error.toString().toJS;
    rethrow;
  }
}

bool isCrossOriginIsolated() {
  final isolated = globalContext['crossOriginIsolated'];
  return isolated.isA<JSBoolean>() && (isolated as JSBoolean).toDart;
}

bool hasWebGpu() => (globalContext['navigator'] as JSObject?)?['gpu'] != null;
