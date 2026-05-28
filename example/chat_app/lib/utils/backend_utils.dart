import 'package:llamadart/llamadart.dart';

/// Shared backend parsing helpers used by provider and settings UI.
class BackendUtils {
  const BackendUtils._();

  /// Parses backend info text into a distinct device list.
  static List<String> parseBackendDevices(String backendInfo) {
    final normalized = backendInfo.trim();
    if (normalized.isEmpty) {
      return const <String>[];
    }

    final parts = backendInfo
        .split(',')
        .map((entry) => entry.trim())
        .where((entry) => entry.isNotEmpty)
        .toSet()
        .toList(growable: false);

    if (parts.isEmpty) {
      return const <String>[];
    }
    return parts;
  }

  /// Builds a concise backend label for the runtime status UI.
  static String deriveActiveBackendLabel(
    String backendInfo, {
    required GpuBackend preferredBackend,
    required int gpuLayers,
  }) {
    final lower = backendInfo.toLowerCase();

    final isLiteRtLm = lower.contains('litert-lm');
    final isLiteRtGpu = isLiteRtLm && lower.contains('gpu');
    if (isLiteRtGpu) {
      return lower.contains('web') ? 'WEBGPU' : 'GPU';
    }
    if (isLiteRtLm && lower.contains('cpu')) {
      return 'CPU';
    }

    if (preferredBackend == GpuBackend.cpu || gpuLayers == 0) {
      return 'CPU';
    }

    if (preferredBackend != GpuBackend.auto &&
        _containsBackendMarker(backendInfo, preferredBackend)) {
      return preferredBackend.name.toUpperCase();
    }

    if (preferredBackend != GpuBackend.auto) {
      return 'CPU';
    }

    if (lower.contains('webgpu') ||
        lower.contains('wgpu') ||
        (lower.contains('litert-lm') &&
            lower.contains('web') &&
            lower.contains('gpu'))) {
      return 'WEBGPU';
    }

    if (_containsBackendMarker(backendInfo, GpuBackend.metal)) {
      return 'METAL';
    }
    if (_containsBackendMarker(backendInfo, GpuBackend.vulkan)) {
      return 'VULKAN';
    }
    if (_containsBackendMarker(backendInfo, GpuBackend.opencl)) {
      return 'OPENCL';
    }
    if (_containsBackendMarker(backendInfo, GpuBackend.hip)) {
      return 'HIP';
    }
    if (_containsBackendMarker(backendInfo, GpuBackend.cuda)) {
      return 'CUDA';
    }
    if (_containsBackendMarker(backendInfo, GpuBackend.blas)) {
      return 'BLAS';
    }
    if (_containsBackendMarker(backendInfo, GpuBackend.cpu)) {
      return 'CPU';
    }

    return backendInfo;
  }

  /// Selects the best native backend from runtime capability text.
  static GpuBackend selectBestBackendFromInfo(String backendInfo) {
    if (_containsBackendMarker(backendInfo, GpuBackend.metal)) {
      return GpuBackend.metal;
    }
    if (_containsBackendMarker(backendInfo, GpuBackend.cuda)) {
      return GpuBackend.cuda;
    }
    if (_containsBackendMarker(backendInfo, GpuBackend.hip)) {
      return GpuBackend.hip;
    }
    if (_containsBackendMarker(backendInfo, GpuBackend.vulkan)) {
      return GpuBackend.vulkan;
    }
    if (_containsBackendMarker(backendInfo, GpuBackend.opencl)) {
      return GpuBackend.opencl;
    }
    if (_containsBackendMarker(backendInfo, GpuBackend.blas)) {
      return GpuBackend.blas;
    }
    return GpuBackend.cpu;
  }

  /// Checks whether runtime text mentions a given backend marker.
  static bool _containsBackendMarker(String value, GpuBackend backend) {
    final lower = value.toLowerCase();
    switch (backend) {
      case GpuBackend.metal:
        return lower.contains('metal') || lower.contains('mtl');
      case GpuBackend.vulkan:
        return lower.contains('vulkan');
      case GpuBackend.opencl:
        return lower.contains('opencl');
      case GpuBackend.hip:
        return lower.contains('hip');
      case GpuBackend.cuda:
        return lower.contains('cuda');
      case GpuBackend.blas:
        return lower.contains('blas');
      case GpuBackend.cpu:
        return lower.contains('cpu') || lower.contains('llvm');
      case GpuBackend.auto:
        return false;
    }
  }

  /// Derives the backend options shown in UI selectors.
  static List<GpuBackend> availableBackends({
    required Iterable<String> devices,
    String? activeBackend,
    bool includeAutoOnWeb = false,
  }) {
    final backends = <GpuBackend>{GpuBackend.cpu};
    if (includeAutoOnWeb) {
      backends.add(GpuBackend.auto);
    }

    for (final device in devices) {
      _addDetectedBackends(device, backends);
    }

    if (activeBackend != null && activeBackend.trim().isNotEmpty) {
      _addDetectedBackends(activeBackend, backends);
    }

    final ordered = backends.toList(growable: false)
      ..sort((a, b) => a.index.compareTo(b.index));
    return ordered;
  }

  static void _addDetectedBackends(String text, Set<GpuBackend> backends) {
    if (_containsBackendMarker(text, GpuBackend.metal)) {
      backends.add(GpuBackend.metal);
    }
    if (_containsBackendMarker(text, GpuBackend.vulkan)) {
      backends.add(GpuBackend.vulkan);
    }
    if (_containsBackendMarker(text, GpuBackend.opencl)) {
      backends.add(GpuBackend.opencl);
    }
    if (_containsBackendMarker(text, GpuBackend.hip)) {
      backends.add(GpuBackend.hip);
    }
    if (_containsBackendMarker(text, GpuBackend.cuda)) {
      backends.add(GpuBackend.cuda);
    }
    if (_containsBackendMarker(text, GpuBackend.blas)) {
      backends.add(GpuBackend.blas);
    }
    if (_containsBackendMarker(text, GpuBackend.cpu)) {
      backends.add(GpuBackend.cpu);
    }
  }
}
