import '../../core/exceptions.dart';

/// A ggml backend device reported by the stable_diffusion runtime.
final class StableDiffusionDevice {
  /// Device name, as accepted by stable-diffusion.cpp backend assignment.
  final String name;

  /// Human-readable device description.
  final String description;

  /// Creates a device entry.
  const StableDiffusionDevice({required this.name, required this.description});
}

/// Outcome of probing the opt-in stable_diffusion native runtime.
final class StableDiffusionRuntimeStatus {
  /// stable-diffusion.cpp version string, when available.
  final String? version;

  /// stable-diffusion.cpp commit, when available.
  final String? commit;

  /// Backend devices the runtime can use, when available.
  final List<StableDiffusionDevice> devices;

  /// Why the runtime cannot be used, or `null` when it can.
  final LlamaUnsupportedException? unavailableReason;

  /// A runtime that loaded and answered the probe.
  const StableDiffusionRuntimeStatus.available({
    required String this.version,
    required String this.commit,
    required this.devices,
  }) : unavailableReason = null;

  /// A runtime that cannot be used, for [reason].
  const StableDiffusionRuntimeStatus.unavailable(
    LlamaUnsupportedException reason,
  ) : unavailableReason = reason,
      version = null,
      commit = null,
      devices = const [];

  /// Whether the runtime loaded and answered the probe.
  bool get isAvailable => unavailableReason == null;

  /// Throws [unavailableReason] when the runtime cannot be used.
  void throwIfUnavailable() {
    final reason = unavailableReason;
    if (reason != null) {
      throw reason;
    }
  }
}

/// Parses `sd_list_devices` output: one `name<TAB>description` per line.
/// Blank lines are skipped; a line without a tab is a name with no
/// description.
List<StableDiffusionDevice> parseStableDiffusionDeviceList(String text) {
  final devices = <StableDiffusionDevice>[];
  for (final line in text.split('\n')) {
    final trimmed = line.trimRight();
    if (trimmed.trim().isEmpty) {
      continue;
    }
    final separator = trimmed.indexOf('\t');
    devices.add(
      separator < 0
          ? StableDiffusionDevice(name: trimmed.trim(), description: '')
          : StableDiffusionDevice(
              name: trimmed.substring(0, separator).trim(),
              description: trimmed.substring(separator + 1).trim(),
            ),
    );
  }
  return devices;
}

/// CPU features the Android arm64 runtime is compiled for
/// (`armv8.2-a+dotprod+fp16`): dot-product plus scalar and vector fp16.
const List<String> stableDiffusionRequiredArmFeatures = [
  'asimddp',
  'fphp',
  'asimdhp',
];

/// Whether every `Features` line of an Arm Linux `/proc/cpuinfo` lists all of
/// [stableDiffusionRequiredArmFeatures]. `false` when there is no `Features`
/// line, so an unreadable or foreign format never passes. Every core must
/// report them because the process may be scheduled on any of them.
bool cpuInfoReportsRequiredArmFeatures(String cpuInfo) {
  var sawFeatures = false;
  for (final line in cpuInfo.split('\n')) {
    final separator = line.indexOf(':');
    if (separator < 0 ||
        line.substring(0, separator).trim().toLowerCase() != 'features') {
      continue;
    }
    sawFeatures = true;
    final features = line.substring(separator + 1).trim().split(RegExp(r'\s+'));
    if (!stableDiffusionRequiredArmFeatures.every(features.contains)) {
      return false;
    }
  }
  return sawFeatures;
}
