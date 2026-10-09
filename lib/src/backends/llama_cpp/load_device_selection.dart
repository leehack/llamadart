import 'bindings.dart';
import 'vulkan_device_probe.dart';

/// One registered ggml device, as llama.cpp reads it when it picks the
/// devices of a model.
final class GgmlDeviceEntry {
  /// Describes the registered [device].
  const GgmlDeviceEntry({
    required this.name,
    required this.type,
    required this.registry,
    this.deviceId,
    this.device,
  });

  /// `ggml_backend_dev_name`, such as `Vulkan0` or `CUDA1`.
  final String name;

  /// The raw `ggml_backend_dev_type` value.
  final int type;

  /// `ggml_backend_reg_name` of the device's backend, such as `Vulkan`.
  final String registry;

  /// `ggml_backend_dev_props.device_id`, which names one physical GPU across
  /// backends, or `null` when the backend reports none.
  final String? deviceId;

  /// The device itself; `null` for a description that stands in for one.
  final ggml_backend_dev_t? device;

  /// Whether the device belongs to ggml-vulkan.
  bool get isVulkan => registry.toLowerCase() == 'vulkan';

  @override
  String toString() => name;
}

final int _typeCpu = ggml_backend_dev_type.GGML_BACKEND_DEVICE_TYPE_CPU.value;
final int _typeAccel =
    ggml_backend_dev_type.GGML_BACKEND_DEVICE_TYPE_ACCEL.value;
final int _typeGpu = ggml_backend_dev_type.GGML_BACKEND_DEVICE_TYPE_GPU.value;
final int _typeIgpu = ggml_backend_dev_type.GGML_BACKEND_DEVICE_TYPE_IGPU.value;
final int _splitNone = llama_split_mode.LLAMA_SPLIT_MODE_NONE.value;
final int _splitTensor = llama_split_mode.LLAMA_SPLIT_MODE_TENSOR.value;

/// The devices llama.cpp `v0.6.0` uses for a model, in its order.
///
/// Mirrors `llama_prepare_model_devices` (`src/llama.cpp`). With [listed]
/// (`llama_model_params.devices`) those devices are used. Without it the
/// [registered] devices are searched: in tensor split mode every device that
/// is not a CPU or an accelerator; otherwise RPC servers, then the discrete
/// GPUs, skipping one whose device id an earlier GPU has, and the integrated
/// GPUs of one backend only when there is no discrete GPU. In
/// `LLAMA_SPLIT_MODE_NONE` only the device [mainGpu] indexes is left, and
/// none for a negative or out-of-range [mainGpu].
List<GgmlDeviceEntry> selectModelDevices({
  required List<GgmlDeviceEntry> registered,
  required List<GgmlDeviceEntry>? listed,
  required int splitMode,
  required int mainGpu,
}) {
  final List<GgmlDeviceEntry> devices;
  if (listed != null) {
    devices = listed;
  } else if (splitMode == _splitTensor) {
    devices = [
      for (final device in registered)
        if (device.type != _typeCpu && device.type != _typeAccel) device,
    ];
  } else {
    final rpcServers = <GgmlDeviceEntry>[];
    final gpus = <GgmlDeviceEntry>[];
    final igpus = <GgmlDeviceEntry>[];
    for (final device in registered) {
      if (device.type == _typeGpu) {
        if (device.registry == 'RPC') {
          rpcServers.add(device);
        } else if (!gpus.any(
          (gpu) =>
              gpu.deviceId != null &&
              device.deviceId != null &&
              gpu.deviceId == device.deviceId,
        )) {
          gpus.add(device);
        }
      } else if (device.type == _typeIgpu &&
          (igpus.isEmpty || igpus.last.registry == device.registry)) {
        igpus.add(device);
      }
    }
    devices = [...rpcServers, ...gpus, if (gpus.isEmpty) ...igpus];
  }
  if (splitMode != _splitNone || devices.isEmpty) return devices;
  return mainGpu >= 0 && mainGpu < devices.length
      ? [devices[mainGpu]]
      : const <GgmlDeviceEntry>[];
}

/// What a model load does about selected Vulkan devices ggml-vulkan cannot
/// drive.
final class VulkanLoadDecision {
  const VulkanLoadDecision._({this.unsupported, this.devices});

  /// Every selected device is usable or unknown: the load goes ahead as it
  /// is.
  static const VulkanLoadDecision unchanged = VulkanLoadDecision._();

  /// Why the load must not start a device, or `null`. Names the first
  /// unusable device and its versions.
  final String? unsupported;

  /// The usable devices to list for the load in place of the selected ones;
  /// `null` when no listed load can avoid the unusable devices, which is when
  /// every selected device is one, and when nothing changes.
  final List<GgmlDeviceEntry>? devices;

  /// Whether no usable device is left, so the load cannot run on the GPU.
  bool get refused => unsupported != null && devices == null;
}

final RegExp _vulkanDeviceName = RegExp(r'^Vulkan(\d+)$');

/// Decides what a model load does about Vulkan devices below Vulkan 1.2.
///
/// [usesGpu] is false for a load that offloads nothing, which never starts a
/// device. [backendRegistry] is the ggml registry of an explicit GPU backend,
/// whose devices the load lists (`llama_model_params.devices`) when it has
/// any, or `null` when llama.cpp selects among every registered device.
///
/// Only the devices the load would use count: a registered device that is
/// not selected is never initialized (`ggml_backend_vk_reg_get_device` only
/// describes it). [registered] is read only for a load that [usesGpu], and
/// [probe] only when a Vulkan device is selected. A device the facts do not
/// cover is taken as usable.
VulkanLoadDecision resolveVulkanLoadDecision({
  required bool usesGpu,
  required String? backendRegistry,
  required int splitMode,
  required int mainGpu,
  required List<GgmlDeviceEntry> Function() registered,
  required VulkanDeviceProbe Function() probe,
}) {
  if (!usesGpu) return VulkanLoadDecision.unchanged;
  final devices = registered();
  final registry = backendRegistry?.toLowerCase();
  final ofBackend = [
    for (final device in devices)
      if (device.registry.toLowerCase() == registry) device,
  ];
  final selected = selectModelDevices(
    registered: devices,
    listed: ofBackend.isEmpty ? null : ofBackend,
    splitMode: splitMode,
    mainGpu: mainGpu,
  );

  final vulkanIndices = <GgmlDeviceEntry, int>{
    for (final device in selected)
      if (device.isVulkan)
        if (_vulkanDeviceName.firstMatch(device.name) case final match?)
          device: int.parse(match.group(1)!),
  };
  if (vulkanIndices.isEmpty) return VulkanLoadDecision.unchanged;
  final facts = probe().devices;
  if (facts == null) return VulkanLoadDecision.unchanged;

  String? unsupported;
  final usable = <GgmlDeviceEntry>[];
  for (final device in selected) {
    final index = vulkanIndices[device];
    final fact = index != null && index < facts.length ? facts[index] : null;
    if (fact == null || fact.meetsVulkan12) {
      usable.add(device);
      continue;
    }
    String version(int value) => VulkanDeviceFacts.formatApiVersion(value);
    unsupported ??=
        "llama.cpp's Vulkan backend needs Vulkan 1.2 or later from both "
        'the Vulkan loader and the GPU driver, and "${fact.name}" '
        '(${device.name}) reports driver API ${version(fact.apiVersion)} '
        'with loader API ${version(fact.instanceApiVersion)}';
  }
  if (unsupported == null) return VulkanLoadDecision.unchanged;
  return VulkanLoadDecision._(
    unsupported: unsupported,
    devices: usable.isEmpty ? null : usable,
  );
}
