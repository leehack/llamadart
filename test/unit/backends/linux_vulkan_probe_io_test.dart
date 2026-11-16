@TestOn('vm')
library;

import 'dart:io';

import 'package:llamadart/backend.dart';
import 'package:llamadart/src/backends/linux_vulkan_probe_io.dart' as native;
import 'package:llamadart/src/backends/litert_lm/litert_lm_gpu_adapter.dart';
import 'package:test/test.dart';

void main() {
  test('other hosts do not query Linux Vulkan', () {
    expect(
      native.linuxVulkanUnavailableReason(
        isLinux: false,
        probe: () => throw StateError('must not probe'),
      ),
      isNull,
    );
    if (!Platform.isLinux) {
      expect(probeLinuxVulkanUnavailableReason(), isNull);
    }
  });

  test('missing loader or incompatible ICD reports an actionable refusal', () {
    for (final reason in ['no loader', 'vkCreateInstance returned -9']) {
      final actual = native.linuxVulkanUnavailableReason(
        isLinux: true,
        probe: () => LiteRtLmVulkanAdapters.unavailable(reason),
      );
      expect(actual, contains(reason));
      expect(actual, contains('Vulkan driver and ICD'));
      expect(actual, contains('CPU-only build'));
    }
  });

  test('a loader without devices is unavailable', () {
    expect(
      native.linuxVulkanUnavailableReason(
        isLinux: true,
        probe: () => const LiteRtLmVulkanAdapters.devices([]),
      ),
      contains('no devices'),
    );
  });

  test('enumerated hardware and software devices pass the preflight', () {
    for (final type in [2, 4]) {
      expect(
        native.linuxVulkanUnavailableReason(
          isLinux: true,
          probe: () => LiteRtLmVulkanAdapters.devices([
            LiteRtLmVulkanAdapter(name: 'device', deviceType: type),
          ]),
        ),
        isNull,
      );
    }
  });
}
