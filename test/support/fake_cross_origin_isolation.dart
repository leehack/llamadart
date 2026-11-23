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
void Function() fakeCrossOriginIsolation({bool? isolated = true}) =>
    overrideBrowserProperty(
      globalContext,
      'crossOriginIsolated',
      isolated?.toJS,
    );

/// Overrides a browser property and returns a function that restores it.
void Function() overrideBrowserProperty(
  JSObject object,
  String property,
  JSAny? value,
) {
  final original = _getOwnPropertyDescriptor(object, property);
  final descriptor = JSObject()..['configurable'] = true.toJS;
  if (value == null) {
    descriptor['get'] = (() {}).toJS;
  } else {
    descriptor['value'] = value;
  }
  _defineProperty(object, property, descriptor);
  return () {
    if (original == null) {
      object.delete(property.toJS);
    } else {
      _defineProperty(object, property, original);
    }
  };
}
