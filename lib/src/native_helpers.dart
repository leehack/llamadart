import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'generated/llama_bindings.dart';
import 'loader.dart';

/// Helper class to interact with native ggml backend functions.
class NativeHelpers {
  /// Returns the number of available compute devices.
  static int getDeviceCount() => llama.ggml_backend_dev_count();

  /// Returns a pointer to the device at the given [index].
  static Pointer<ggml_backend_device> getDevicePointer(int index) {
    return llama.ggml_backend_dev_get(index);
  }

  /// Returns the name of the device at the given [index].
  static String getDeviceName(int index) {
    final dev = getDevicePointer(index);
    if (dev == nullptr) return "";
    final ptr = llama.ggml_backend_dev_name(dev);
    if (ptr == nullptr) return "";
    return ptr.cast<Utf8>().toDartString();
  }

  /// Returns the description of the device at the given [index].
  static String getDeviceDescription(int index) {
    final dev = getDevicePointer(index);
    if (dev == nullptr) return "";
    final ptr = llama.ggml_backend_dev_description(dev);
    if (ptr == nullptr) return "";
    return ptr.cast<Utf8>().toDartString();
  }

  /// Returns a list of all available device names.
  static List<String> getAvailableDevices() {
    final count = getDeviceCount();
    final devices = <String>[];
    for (var i = 0; i < count; i++) {
      devices.add(getDeviceName(i));
    }
    return devices;
  }
}
