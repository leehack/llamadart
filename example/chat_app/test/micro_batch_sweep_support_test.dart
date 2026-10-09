import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/src/backends/llama_cpp/vulkan_device_probe.dart';

import '../integration_test/support/micro_batch_sweep_support.dart';

void main() {
  group('parsePromptCapDecision', () {
    test('reads a capped decision and the device as llamadart formats it', () {
      const device = VulkanDeviceFacts(
        name: 'Mali-G715',
        deviceType: 1,
        instanceApiVersion: 1 << 22 | 3 << 12,
        apiVersion: 1 << 22 | 3 << 12 | 283,
        subgroupSize: 16,
      );
      final decision = parsePromptCapDecision(
        'llama_cpp_service: Android Vulkan text prompt decode is capped at 8 '
        'tokens per call ($device)',
      )!;

      expect(decision.capTokens, 8);
      expect(decision.devices, [
        (
          name: 'Mali-G715',
          apiVersion: '1.3',
          loaderApiVersion: '1.3',
          subgroupSize: 16,
        ),
      ]);
    });

    test('reads a lifted cap and every device', () {
      final decision = parsePromptCapDecision(
        'llama_cpp_service: Android Vulkan text prompt decode is not capped '
        '("Adreno (TM) 750" (API 1.3, loader 1.4, subgroup size 64), '
        '"llvmpipe (LLVM 19.1, 256 bits)" (API 1.4, loader 1.4, subgroup '
        'size 8))',
      )!;

      expect(decision.capTokens, isNull);
      expect(
        [for (final device in decision.devices) device.name],
        ['Adreno (TM) 750', 'llvmpipe (LLVM 19.1, 256 bits)'],
      );
      expect(
        [for (final device in decision.devices) device.subgroupSize],
        [64, 8],
      );
      expect(decision.devices.first.loaderApiVersion, '1.4');
    });

    test('keeps the reason of a probe that listed no device', () {
      final decision = parsePromptCapDecision(
        'llama_cpp_service: Android Vulkan text prompt decode is capped at 8 '
        'tokens per call (llama_dart_vulkan_get_device_count returned '
        'LLAMA_DART_VULKAN_STATUS_NO_LOADER)',
      )!;

      expect(decision.capTokens, 8);
      expect(decision.devices, isEmpty);
      expect(
        decision.detail,
        'llama_dart_vulkan_get_device_count returned '
        'LLAMA_DART_VULKAN_STATUS_NO_LOADER',
      );
    });

    test('ignores other records', () {
      expect(
        parsePromptCapDecision(
          'llama_cpp_service: promoting flash_attn=enabled for non-F16 KV',
        ),
        isNull,
      );
    });
  });

  group('reconstructToolCall', () {
    test('joins the name and the argument pieces of one call', () {
      final call = reconstructToolCall([
        {
          'index': 0,
          'id': 'call_1',
          'function': {'name': 'get_weather', 'arguments': '{"city":'},
        },
        {
          'index': 0,
          'function': {'arguments': '"Montréal"}'},
        },
      ]);

      expect(call.name, 'get_weather');
      expect(call.arguments, {'city': 'Montréal'});
      expect(call.wellFormed, isTrue);
    });

    test('is not well formed without deltas', () {
      expect(reconstructToolCall(const []).wellFormed, isFalse);
    });

    test('is not well formed when the arguments are not JSON', () {
      final call = reconstructToolCall([
        {
          'index': 0,
          'function': {'name': 'get_weather', 'arguments': '8888'},
        },
        {
          'index': 0,
          'function': {'arguments': '{'},
        },
      ]);

      expect(call.name, 'get_weather');
      expect(call.arguments, isNull);
      expect(call.wellFormed, isFalse);
    });

    test('is not well formed when the deltas name two calls', () {
      final call = reconstructToolCall([
        {
          'index': 0,
          'id': 'call_1',
          'function': {'name': 'get_weather', 'arguments': '{}'},
        },
        {
          'index': 1,
          'id': 'call_2',
          'function': {'name': 'get_weather', 'arguments': ''},
        },
      ]);

      expect(call.wellFormed, isFalse);
    });
  });
}
