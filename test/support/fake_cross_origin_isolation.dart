import 'dart:js_interop';
import 'dart:js_interop_unsafe';

@JS('Object.defineProperty')
external void _defineProperty(
  JSObject object,
  String name,
  JSObject descriptor,
);

@JS('Object.getOwnPropertyDescriptor')
external JSObject? _getOwnPropertyDescriptor(JSObject object, String name);

/// Overrides browser isolation and returns a function that restores it.
void Function() fakeCrossOriginIsolation({bool isolated = true}) {
  const property = 'crossOriginIsolated';
  final original = _getOwnPropertyDescriptor(globalContext, property);
  _defineProperty(
    globalContext,
    property,
    JSObject()
      ..['value'] = isolated.toJS
      ..['configurable'] = true.toJS,
  );
  return () {
    if (original == null) {
      globalContext.delete(property.toJS);
    } else {
      _defineProperty(globalContext, property, original);
    }
  };
}

/// Keeps threaded fixtures on that core when Dart's test server serves pages
/// without COOP/COEP and the Chrome test flags enable shared memory.
void useDartTestThreadedCore() {
  if (globalContext['SharedArrayBuffer'].isA<JSFunction>()) {
    fakeCrossOriginIsolation();
  }
}
