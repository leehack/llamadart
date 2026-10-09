import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'bindings.dart';

const _wrapperAsset = 'package:llamadart/llamadart_wrapper';

typedef _DeviceCountNative = Int32 Function();
typedef _DeviceInfoNative =
    Int32 Function(Int32, Pointer<llama_dart_vulkan_device_info>);

/// One Vulkan device as libllamadart reads it from the Vulkan loader.
final class VulkanDeviceFacts {
  /// Creates the facts of the device called [name].
  const VulkanDeviceFacts({
    required this.name,
    required this.deviceType,
    required this.instanceApiVersion,
    required this.apiVersion,
    required this.subgroupSize,
  });

  /// Vulkan 1.2 as `VK_MAKE_API_VERSION` encodes it.
  static const int vulkan12 = 1 << 22 | 2 << 12;

  /// `VkPhysicalDeviceProperties.deviceName`, which ggml-vulkan gives its
  /// device as `ggml_backend_dev_description`.
  final String name;

  /// `VkPhysicalDeviceProperties.deviceType`, a `VkPhysicalDeviceType`.
  final int deviceType;

  /// Whether the device is `VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU`, which
  /// ggml-vulkan registers as an integrated GPU.
  bool get isIntegratedGpu => deviceType == 1;

  /// `vkEnumerateInstanceVersion`: the Vulkan loader's version.
  final int instanceApiVersion;

  /// `VkPhysicalDeviceProperties.apiVersion`: the driver's version.
  final int apiVersion;

  /// `VkPhysicalDeviceSubgroupProperties.subgroupSize`, or 0 when the loader
  /// or the driver is older than Vulkan 1.1 and cannot report it.
  final int subgroupSize;

  /// Whether ggml-vulkan can drive the device.
  ///
  /// ggml-vulkan registers no device when the loader is below Vulkan 1.2
  /// (`ggml_vk_instance_init`). It does register a device whose driver is
  /// below 1.2, then reads `VkPhysicalDeviceVulkan12Features` the driver
  /// never filled in and calls Vulkan 1.2 functions it does not have.
  bool get meetsVulkan12 =>
      instanceApiVersion >= vulkan12 && apiVersion >= vulkan12;

  /// Whether ggml-vulkan's small matmul tile gives wrong results on the
  /// device (https://github.com/ggml-org/llama.cpp/issues/28637).
  ///
  /// The small tiles split a 32-row block between `max(size, 32) /
  /// max(size, 8)` warps, but llama.cpp v0.6.0 gives each warp 8 rows only
  /// for a subgroup size of exactly 8 and all 32 rows otherwise
  /// (`s_warptile_wm` in `ggml_vk_load_shaders`). That is one warp too many
  /// at 16, where it was found, and at every size below 8. An unknown size
  /// counts as affected.
  bool get hasSmallMatmulTileDefect => subgroupSize != 8 && subgroupSize < 32;

  /// `major.minor` of an encoded Vulkan [version].
  static String formatApiVersion(int version) =>
      '${(version >> 22) & 0x7f}.${(version >> 12) & 0x3ff}';

  @override
  String toString() =>
      '"$name" (API ${formatApiVersion(apiVersion)}, loader '
      '${formatApiVersion(instanceApiVersion)}, subgroup size $subgroupSize)';
}

/// What libllamadart reports about the Vulkan devices ggml-vulkan registers.
final class VulkanDeviceProbe {
  /// The probe listed [devices].
  const VulkanDeviceProbe.devices(List<VulkanDeviceFacts> this.devices)
    : unavailableReason = null;

  /// The probe could not list the devices, for [unavailableReason].
  const VulkanDeviceProbe.unavailable(String this.unavailableReason)
    : devices = null;

  /// The devices in ggml-vulkan's order, or `null` when they are unknown.
  final List<VulkanDeviceFacts>? devices;

  /// Why [devices] is `null`.
  final String? unavailableReason;
}

/// libllamadart's Vulkan device facts, resolved from one library.
///
/// Reading them makes the Vulkan loader load the system's GPU drivers into
/// the process, and a driver that crashes there cannot be caught. Probe only
/// while the Vulkan backend is in use or about to be.
///
/// Windows bundles export the functions from `llamadart.dll` rather than the
/// default `llama.dll` asset, so [tryResolve] resolves `@Native` declarations
/// bound to that asset on Windows. Elsewhere it resolves the generated
/// bindings.
final class VulkanDeviceInfoApi {
  /// Creates an API from resolved functions.
  const VulkanDeviceInfoApi({
    required this.getDeviceCount,
    required this.getDeviceInfo,
  });

  /// The oldest `llamadart-native` release that exports these functions.
  static const String minimumNativeRelease = 'v0.6.0-1';

  /// Resolves both functions from the loaded runtime, or returns `null` when
  /// it does not export them.
  ///
  /// [isWindows] selects the asset the functions are bound to. [symbol]
  /// replaces that lookup: it returns the address of the function exported
  /// under a name, and throws [ArgumentError] when there is none.
  static VulkanDeviceInfoApi? tryResolve({
    required bool isWindows,
    Pointer<NativeType> Function(String name)? symbol,
  }) {
    final lookup =
        symbol ?? (name) => symbolAddress(name, isWindows: isWindows);
    try {
      return VulkanDeviceInfoApi(
        getDeviceCount: lookup(
          'llama_dart_vulkan_get_device_count',
        ).cast<NativeFunction<_DeviceCountNative>>().asFunction(),
        getDeviceInfo: lookup(
          'llama_dart_vulkan_get_device_info',
        ).cast<NativeFunction<_DeviceInfoNative>>().asFunction(),
      );
    } on ArgumentError {
      return null;
    }
  }

  /// The address of the function the loaded runtime exports as [name], from
  /// the asset [isWindows] selects; throws [ArgumentError] when it exports
  /// none.
  static Pointer<NativeType> symbolAddress(
    String name, {
    required bool isWindows,
  }) => (isWindows ? _wrapperAssetSymbol : _bindingsSymbol)(name);

  /// Reads the devices from the loaded runtime; unavailable, with the
  /// release that is needed, when it does not export the functions.
  static VulkanDeviceProbe probeRuntime({required bool isWindows}) {
    final api = tryResolve(isWindows: isWindows);
    return api == null
        ? const VulkanDeviceProbe.unavailable(
            'the loaded llama.cpp runtime does not export '
            'llama_dart_vulkan_get_device_count (llamadart-native '
            '$minimumNativeRelease or later is needed)',
          )
        : api.probe();
  }

  /// `llama_dart_vulkan_get_device_count`: the number of devices, or a
  /// negative `llama_dart_vulkan_status`.
  final int Function() getDeviceCount;

  /// `llama_dart_vulkan_get_device_info`: a `llama_dart_vulkan_status`.
  final int Function(int index, Pointer<llama_dart_vulkan_device_info> info)
  getDeviceInfo;

  /// Lists the devices; unavailable when the loader cannot be queried or a
  /// device cannot be described.
  VulkanDeviceProbe probe() {
    final count = getDeviceCount();
    if (count < 0) {
      return VulkanDeviceProbe.unavailable(
        'llama_dart_vulkan_get_device_count returned ${_statusName(count)}',
      );
    }
    final info = calloc<llama_dart_vulkan_device_info>();
    try {
      final devices = <VulkanDeviceFacts>[];
      for (var index = 0; index < count; index++) {
        info.ref.struct_size = sizeOf<llama_dart_vulkan_device_info>();
        final status = getDeviceInfo(index, info);
        if (status != 0) {
          return VulkanDeviceProbe.unavailable(
            'llama_dart_vulkan_get_device_info($index) returned '
            '${_statusName(status)}',
          );
        }
        devices.add(
          VulkanDeviceFacts(
            name: _deviceName(info.ref),
            deviceType: info.ref.device_type,
            instanceApiVersion: info.ref.instance_api_version,
            apiVersion: info.ref.api_version,
            subgroupSize: info.ref.subgroup_size,
          ),
        );
      }
      return VulkanDeviceProbe.devices(List.unmodifiable(devices));
    } finally {
      calloc.free(info);
    }
  }
}

String _deviceName(llama_dart_vulkan_device_info info) {
  const capacity = 256;
  final bytes = <int>[];
  for (var i = 0; i < capacity; i++) {
    final byte = info.device_name[i] & 0xff;
    if (byte == 0) break;
    bytes.add(byte);
  }
  return utf8.decode(bytes, allowMalformed: true);
}

String _statusName(int status) {
  for (final known in llama_dart_vulkan_status.values) {
    if (known.value == status) return known.name;
  }
  return 'status $status';
}

Pointer<NativeType> _bindingsSymbol(String symbol) => switch (symbol) {
  'llama_dart_vulkan_get_device_count' =>
    Native.addressOf<NativeFunction<_DeviceCountNative>>(
      llama_dart_vulkan_get_device_count,
    ),
  'llama_dart_vulkan_get_device_info' =>
    Native.addressOf<NativeFunction<_DeviceInfoNative>>(
      llama_dart_vulkan_get_device_info,
    ),
  _ => throw ArgumentError.value(symbol, 'symbol', 'not bound'),
};

Pointer<NativeType> _wrapperAssetSymbol(String symbol) => switch (symbol) {
  'llama_dart_vulkan_get_device_count' =>
    Native.addressOf<NativeFunction<_DeviceCountNative>>(_wrapperDeviceCount),
  'llama_dart_vulkan_get_device_info' =>
    Native.addressOf<NativeFunction<_DeviceInfoNative>>(_wrapperDeviceInfo),
  _ => throw ArgumentError.value(symbol, 'symbol', 'not bound'),
};

@Native<_DeviceCountNative>(
  assetId: _wrapperAsset,
  symbol: 'llama_dart_vulkan_get_device_count',
)
external int _wrapperDeviceCount();

@Native<_DeviceInfoNative>(
  assetId: _wrapperAsset,
  symbol: 'llama_dart_vulkan_get_device_info',
)
external int _wrapperDeviceInfo(
  int index,
  Pointer<llama_dart_vulkan_device_info> info,
);
