import '../../core/exceptions.dart';
import '../../core/models/config/gpu_backend.dart';
import '../../core/models/inference/model_params.dart';
import 'bindings.dart';
import 'load_device_selection.dart';

final int _typeGpu = ggml_backend_dev_type.GGML_BACKEND_DEVICE_TYPE_GPU.value;
final int _typeIgpu = ggml_backend_dev_type.GGML_BACKEND_DEVICE_TYPE_IGPU.value;
final int _typeAccel =
    ggml_backend_dev_type.GGML_BACKEND_DEVICE_TYPE_ACCEL.value;

/// The devices and tensor split a model load passes to llama.cpp for
/// [ModelParams.gpuDevices] and [ModelParams.tensorSplit].
final class GpuDevicePlacement {
  /// Places the model on [devices], split by [tensorSplit] when it is set.
  const GpuDevicePlacement({required this.devices, this.tensorSplit});

  /// `llama_model_params.devices`, in order.
  final List<GgmlDeviceEntry> devices;

  /// `llama_model_params.tensor_split`, one proportion per device, or `null`
  /// for llama.cpp's split by free memory.
  final List<double>? tensorSplit;

  /// The device names, as backend names report them, such as `CUDA0, CUDA2`.
  String get deviceNames => devices.map((device) => device.name).join(', ');
}

/// The offload devices of [backend] among [registered], in registry order:
/// position `i` is the device `LlamaEngine.listGpuDevices` reports with
/// `GpuDeviceInfo.mainGpu` `i` for [backend].
///
/// [backendOf] maps a ggml registry name to its [GpuBackend], as the device
/// listing does.
List<GgmlDeviceEntry> offloadDevicesOf(
  List<GgmlDeviceEntry> registered,
  GpuBackend backend,
  GpuBackend Function(String registry) backendOf,
) => [
  for (final device in registered)
    if ((device.type == _typeGpu ||
            device.type == _typeIgpu ||
            device.type == _typeAccel) &&
        backendOf(device.registry) == backend)
      device,
];

/// Resolves the [ModelParams.gpuDevices] and [ModelParams.tensorSplit] of
/// [params] for a load on [backend] among the [registered] devices, or
/// returns `null` when neither is set.
///
/// [backend] is the load's effective backend; under [GpuBackend.auto] the
/// only GPU backend with devices is used. Throws [LlamaUnsupportedException]
/// when no backend can be chosen, for an index this host does not have, for
/// a split whose length differs from the number of devices, and for more
/// devices than llama.cpp's [maxDevices].
GpuDevicePlacement? resolveGpuDevicePlacement(
  ModelParams params, {
  required GpuBackend backend,
  required List<GgmlDeviceEntry> registered,
  required GpuBackend Function(String registry) backendOf,
  required int maxDevices,
  required String platform,
}) {
  final indices = params.gpuDevices;
  final split = params.tensorSplit;
  if (indices == null && split == null) return null;
  final field = indices != null ? 'gpuDevices' : 'tensorSplit';
  final capability =
      'ModelParams.$field, llama.cpp multi-GPU placement, is not available '
      'on $platform';

  var placed = backend;
  if (placed == GpuBackend.auto) {
    final backends = {
      for (final device in registered)
        if (device.type == _typeGpu || device.type == _typeIgpu)
          backendOf(device.registry),
    }..remove(GpuBackend.auto);
    if (backends.length != 1) {
      throw LlamaUnsupportedException(
        backends.isEmpty
            ? '$capability: llama.cpp lists no GPU device.'
            : '$capability with preferredBackend auto, because more than one '
                  'GPU backend has devices '
                  '(${backends.map((backend) => backend.name).join(', ')}). '
                  'Set preferredBackend to the backend whose listGpuDevices '
                  'indices it names.',
      );
    }
    placed = backends.single;
  }
  final available = offloadDevicesOf(registered, placed, backendOf);
  String listed() => available.isEmpty
      ? 'none'
      : available.map((device) => device.name).join(', ');
  if (available.isEmpty) {
    throw LlamaUnsupportedException(
      '$capability: llama.cpp lists no ${placed.name} device.',
    );
  }

  final List<GgmlDeviceEntry> devices;
  if (indices == null) {
    devices = available;
  } else {
    final missing = indices.where((index) => index >= available.length);
    if (missing.isNotEmpty) {
      throw LlamaUnsupportedException(
        '$capability: gpuDevices names ${placed.name} device '
        '${missing.join(', ')}, and this host has ${available.length} '
        '(${listed()}). Use the GpuDeviceInfo.mainGpu indices '
        'listGpuDevices reports.',
      );
    }
    devices = [for (final index in indices) available[index]];
  }
  if (devices.length > maxDevices) {
    throw LlamaUnsupportedException(
      '$capability: the load would use ${devices.length} devices, and '
      'llama.cpp supports at most $maxDevices.',
    );
  }
  if (split != null && split.length != devices.length) {
    throw LlamaUnsupportedException(
      '$capability: tensorSplit holds ${split.length} proportions, and the '
      'load uses ${devices.length} ${placed.name} '
      '${devices.length == 1 ? 'device' : 'devices'} '
      '(${devices.map((device) => device.name).join(', ')}). Give one '
      'proportion per device.',
    );
  }
  return GpuDevicePlacement(devices: devices, tensorSplit: split);
}
