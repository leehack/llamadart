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

    test('reads a device whose name holds a quote', () {
      const devices = [
        VulkanDeviceFacts(
          name: 'Weird "GPU" 9000',
          deviceType: 2,
          instanceApiVersion: 1 << 22 | 3 << 12,
          apiVersion: 1 << 22 | 1 << 12,
          subgroupSize: 4,
        ),
        VulkanDeviceFacts(
          name: 'Mali-G715',
          deviceType: 1,
          instanceApiVersion: 1 << 22 | 3 << 12,
          apiVersion: 1 << 22 | 3 << 12,
          subgroupSize: 16,
        ),
      ];
      final decision = parsePromptCapDecision(
        'llama_cpp_service: Android Vulkan text prompt decode is capped at 8 '
        'tokens per call (${devices.join(', ')})',
      )!;

      expect(
        [for (final device in decision.devices) device.name],
        ['Weird "GPU" 9000', 'Mali-G715'],
      );
      expect(decision.devices.first.apiVersion, '1.1');
      expect(decision.devices.first.subgroupSize, 4);
      expect(decision.devices.last.subgroupSize, 16);
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

  group('promptCapState', () {
    const capped = (
      capTokens: 8,
      devices: <PromptCapDevice>[],
      detail: 'probe unavailable',
    );
    const lifted = (
      capTokens: null,
      devices: <PromptCapDevice>[],
      detail: '"Adreno" (API 1.3, loader 1.3, subgroup size 64)',
    );
    PromptCapState state({
      PromptCapDecision? logged,
      int microBatchSize = 0,
      bool isAndroid = true,
      bool vulkanRequested = true,
      int? registeredVulkanDevices = 1,
    }) => promptCapState(
      logged: logged,
      microBatchSize: microBatchSize,
      isAndroid: isAndroid,
      vulkanRequested: vulkanRequested,
      registeredVulkanDevices: registeredVulkanDevices,
    );

    test('takes a logged decision over everything else', () {
      expect(state(logged: capped), PromptCapState.capped);
      expect(state(logged: lifted), PromptCapState.notCapped);
      expect(
        state(logged: capped, registeredVulkanDevices: 0),
        PromptCapState.capped,
      );
    });

    test('names why the library logged nothing', () {
      expect(state(microBatchSize: 512), PromptCapState.explicitSize);
      expect(state(isAndroid: false), PromptCapState.notAndroid);
      expect(state(vulkanRequested: false), PromptCapState.vulkanNotRequested);
    });

    test('tells a silent cap without a Vulkan device from a missing '
        'record', () {
      expect(state(registeredVulkanDevices: 0), PromptCapState.noVulkanDevice);
      expect(state(registeredVulkanDevices: 1), PromptCapState.notLogged);
      expect(state(registeredVulkanDevices: null), PromptCapState.notLogged);
    });

    test('an explicit size is not a silent cap even without a device', () {
      expect(
        state(microBatchSize: 512, registeredVulkanDevices: 0),
        PromptCapState.explicitSize,
      );
    });
  });

  group('answerIsCode', () {
    test('accepts the code alone, whatever its case and closing mark', () {
      expect(answerIsCode('Cedar17', ['cedar17']), isTrue);
      expect(answerIsCode('  cedar17.\n', ['cedar17']), isTrue);
      expect(answerIsCode('42', ['42', 'maple42']), isTrue);
      expect(answerIsCode('maple42!', ['42', 'maple42']), isTrue);
    });

    test('rejects an answer that only holds the code', () {
      expect(answerIsCode('8888888842888', ['42', 'maple42']), isFalse);
      expect(answerIsCode('1 2 3 42 5', ['42', 'maple42']), isFalse);
      expect(answerIsCode('The code is cedar17', ['cedar17']), isFalse);
      expect(answerIsCode('', ['cedar17']), isFalse);
    });
  });

  group('toolCallMatches', () {
    const call = (
      name: 'get_weather',
      arguments: {'city': 'Montréal'},
      wellFormed: true,
    );
    bool matches({
      Object? finishReasons = const ['tool_calls'],
      ({String name, Object? arguments, bool wellFormed}) call = call,
    }) => toolCallMatches(
      finishReasons: finishReasons,
      call: call,
      name: 'get_weather',
      arguments: const {'city': 'Montréal'},
    );

    test('accepts the one expected call', () {
      expect(matches(), isTrue);
    });

    test('rejects another finish, name, argument or a malformed call', () {
      expect(matches(finishReasons: const ['stop']), isFalse);
      expect(matches(finishReasons: const ['length']), isFalse);
      expect(
        matches(
          call: (name: 'get_time', arguments: call.arguments, wellFormed: true),
        ),
        isFalse,
      );
      expect(
        matches(
          call: (
            name: 'get_weather',
            arguments: const {'city': 'Toronto'},
            wellFormed: true,
          ),
        ),
        isFalse,
      );
      expect(
        matches(
          call: (
            name: 'get_weather',
            arguments: call.arguments,
            wellFormed: false,
          ),
        ),
        isFalse,
      );
    });
  });

  group('judgeAttempt', () {
    const cases = ['C06.history', 'X01.long_history', 'C07.tools.auto'];
    const pass = (passed: true, description: 'ok');

    test('passes when every judged case passed', () {
      final verdict = judgeAttempt(cases, {
        for (final id in cases) id: pass,
        'C04.hello': (passed: false, description: 'not judged'),
      });

      expect(verdict.passed, isTrue);
      expect(verdict.failures, isEmpty);
      expect(verdict.cases, {for (final id in cases) id: true});
    });

    test('fails on a wrong answer and says what it was', () {
      final verdict = judgeAttempt(cases, {
        'C06.history': pass,
        'X01.long_history': (passed: false, description: 'answered "8888"'),
        'C07.tools.auto': pass,
      });

      expect(verdict.passed, isFalse);
      expect(verdict.failures, ['X01.long_history answered "8888"']);
      expect(verdict.cases['X01.long_history'], isFalse);
      expect(verdict.cases['C06.history'], isTrue);
    });

    test('fails on a judged case that never ran', () {
      final verdict = judgeAttempt(cases, {
        'C06.history': pass,
        'X01.long_history': pass,
      });

      expect(verdict.passed, isFalse);
      expect(verdict.failures, ['C07.tools.auto did not run']);
      expect(verdict.cases['C07.tools.auto'], isFalse);
    });

    test('fails on a load error without listing the cases', () {
      final verdict = judgeAttempt(
        cases,
        const {},
        loadError: 'LlamaModelException: no',
      );

      expect(verdict.passed, isFalse);
      expect(verdict.failures, ['did not load: LlamaModelException: no']);
      expect(verdict.cases.values, everyElement(isFalse));
    });
  });

  group('sweepOrder', () {
    test('runs every judged repeat before any control', () {
      expect(sweepOrder([0, 512], 3, judgedArm: 0), [
        (repeat: 1, arm: 0),
        (repeat: 2, arm: 0),
        (repeat: 3, arm: 0),
        (repeat: 1, arm: 512),
        (repeat: 2, arm: 512),
        (repeat: 3, arm: 512),
      ]);
    });

    test('keeps the controls repeat by repeat, wherever the judged size is '
        'listed', () {
      expect(sweepOrder([512, 0, 1], 2, judgedArm: 0), [
        (repeat: 1, arm: 0),
        (repeat: 2, arm: 0),
        (repeat: 1, arm: 512),
        (repeat: 1, arm: 1),
        (repeat: 2, arm: 512),
        (repeat: 2, arm: 1),
      ]);
    });
  });
}
