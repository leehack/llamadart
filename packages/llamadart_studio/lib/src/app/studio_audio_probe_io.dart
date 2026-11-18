import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

const _installHint =
    'Install gstreamer1.0-plugins-base and gstreamer1.0-plugins-good '
    '(Ubuntu/Debian), then restart Studio.';

/// Checks the Linux elements needed by the pinned playback plugin and WAV clips.
///
/// Injected functions allow deterministic missing-runtime controls on any host.
String? probeAudioPlaybackUnavailableReason({
  bool? isLinux,
  bool Function()? initialize,
  bool Function(String)? canCreateElement,
}) {
  if (!(isLinux ?? Platform.isLinux)) return null;
  try {
    final bindings = initialize == null || canCreateElement == null
        ? _GStreamer()
        : null;
    if (!(initialize ?? bindings!.initialize)()) {
      return 'Linux audio playback could not initialize GStreamer. $_installHint';
    }
    final create = canCreateElement ?? bindings!.canCreateElement;
    for (final name in <String>['playbin', 'autoaudiosink', 'wavparse']) {
      if (!create(name)) {
        return 'Linux audio playback is unavailable: GStreamer cannot create '
            '$name. $_installHint';
      }
    }
    return null;
  } catch (_) {
    return 'Linux audio playback could not load its GStreamer runtime. '
        '$_installHint';
  }
}

class _GStreamer {
  final DynamicLibrary _library = DynamicLibrary.open('libgstreamer-1.0.so.0');

  late final _init = _library
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Void>, Pointer<Void>),
        int Function(Pointer<Void>, Pointer<Void>, Pointer<Void>)
      >('gst_init_check');
  late final _make = _library
      .lookupFunction<
        Pointer<Void> Function(Pointer<Utf8>, Pointer<Utf8>),
        Pointer<Void> Function(Pointer<Utf8>, Pointer<Utf8>)
      >('gst_element_factory_make');
  late final _unref = _library
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('gst_object_unref');

  bool initialize() => _init(nullptr, nullptr, nullptr) != 0;

  bool canCreateElement(String name) {
    final nativeName = name.toNativeUtf8();
    try {
      final element = _make(nativeName, nullptr);
      if (element == nullptr) return false;
      _unref(element);
      return true;
    } finally {
      malloc.free(nativeName);
    }
  }
}
