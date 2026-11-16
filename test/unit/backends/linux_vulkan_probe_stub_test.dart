import 'package:llamadart/src/backends/linux_vulkan_probe_stub.dart';
import 'package:test/test.dart';

void main() {
  test('Web imposes no Linux Vulkan requirement', () {
    expect(probeLinuxVulkanUnavailableReason(), isNull);
  });
}
