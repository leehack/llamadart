import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_validation/llamadart_validation.dart';

import '../integration_test/support/pixel_qwen35_guard_support.dart';

void main() {
  test('C04 uses unchanged maintained fixture and canonical profile sampler', () {
    final configs = <Map<String, Object?>>[];
    for (final backend in ['cpu', 'vulkan']) {
      final profile = ValidationProfile.fromJson(
        jsonDecode(
              File(
                '../../packages/llamadart_validation/assets/profiles/chat-gguf-$backend.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>,
      );
      expect(
        profile.fixtureText('arithmetic', 'prompt'),
        'What is 2 + 2? Reply with only the number.',
      );
      expect(profile.fixtureText('arithmetic', 'regex'), r'^4[.!]?$');
      expect(profile.model['sha256'], pixelQwen35ModelSha256);
      expect(profile.model['bytes'], pixelQwen35ModelBytes);
      final config = Map<String, Object?>.from(profile.effectiveConfig)
        ..remove('backend')
        ..remove('gpu_layers_hint');
      configs.add(config);
      expect(config, containsPair('max_tokens', 32));
      expect(config, containsPair('context_size', 1024));
      expect(config, containsPair('threads', 4));
      expect(config, containsPair('batch_threads', 4));
      expect(config, containsPair('temperature', 0));
      expect(config, containsPair('seed', 1));
      expect(config, containsPair('top_k', 40));
      expect(config, containsPair('top_p', 0.9));
      expect(config, containsPair('min_p', 0));
      expect(config, containsPair('repeat_penalty', 1.1));
      expect(config, containsPair('presence_penalty', 0));
      expect(config, containsPair('enable_thinking', false));
      expect(config, containsPair('reuse_prompt_prefix', false));
    }
    expect(configs[0], configs[1]);
  });
  test(
    'zero-layer control reaches production validation with automatic device',
    () {
      final profile = ValidationProfile.fromJson(
        jsonDecode(
              File(
                '../../packages/llamadart_validation/assets/profiles/chat-gguf-vulkan.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>,
      ).loadParams;
      expect(
        () => profile
            .copyWith(
              device: ComputeDevice.gpu,
              gpuLayers: 0,
              microBatchSize: 32,
            )
            .validate(),
        throwsA(isA<LlamaArgumentException>()),
      );
      final zero = pixelQwen35LoadParams(
        profile,
        backend: 'vulkan',
        microBatchSize: 32,
        zeroLayers: true,
      );
      zero.validate();
      expect(zero.device, ComputeDevice.auto);
      expect(zero.preferredBackend, GpuBackend.vulkan);
      expect(zero.gpuLayers, 0);
      expect(zero.microBatchSize, 32);
      final gpu = pixelQwen35LoadParams(
        profile,
        backend: 'vulkan',
        microBatchSize: 0,
      );
      expect(gpu.device, ComputeDevice.gpu);
      expect(gpu.gpuLayers, profile.gpuLayers);
      expect(gpu.preferredBackend, profile.preferredBackend);
      final cpuProfile = profile.copyWith(
        preferredBackend: GpuBackend.cpu,
        gpuLayers: 0,
      );
      final cpu = pixelQwen35LoadParams(
        cpuProfile,
        backend: 'cpu',
        microBatchSize: 32,
      );
      expect(cpu.device, ComputeDevice.cpu);
      expect(cpu.preferredBackend, GpuBackend.cpu);
      expect(cpu.gpuLayers, 0);
    },
  );
  Map<String, dynamic> passing() => {
    'content': '4',
    'visible_output_utf8': [52],
    'visible_output_retokenization_ids': [19],
    'thinking': '',
    'stream_completed': true,
    'ordered_terminal': true,
    'finish_reason': 'stop',
    'native_usage_counts': {
      'prompt_tokens': 29,
      'completion_tokens': 2,
      'total_tokens': 31,
    },
    'rendered_prompt': 'public template',
    'rendered_input_ids': List.generate(29, (i) => i),
    'messages': [
      {'role': 'user', 'content': 'What is 2 + 2? Reply with only the number.'},
    ],
    'request_settings': {
      'temperature': 0,
      'seed': 1,
      'reuse_prompt_prefix': false,
    },
  };
  test(
    'CPU semantics gate all dependent comparisons without changing oracle',
    () {
      expect(pixelQwen35ArithmeticFailures(passing()), isEmpty);
      for (final wrong in ['', '8', 'four', '4 is the answer', 'Cedar17']) {
        expect(
          pixelQwen35ArithmeticFailures({...passing(), 'content': wrong}),
          contains('semantic'),
        );
      }
      expect(pixelQwen35ArithmeticFailures(passing(), requireReference: true), [
        'cpu_reference_not_passed',
      ]);
    },
  );
  test('semantic equivalence cannot replace raw public evidence parity', () {
    for (final field in [
      'content',
      'visible_output_utf8',
      'visible_output_retokenization_ids',
      'messages',
      'request_settings',
      'rendered_prompt',
      'rendered_input_ids',
      'native_usage_counts',
      'finish_reason',
    ]) {
      final changed = jsonDecode(jsonEncode(passing())) as Map<String, dynamic>;
      changed[field] = switch (field) {
        'content' => '4.',
        'finish_reason' => 'length',
        'rendered_prompt' => 'changed template',
        'native_usage_counts' => {
          'prompt_tokens': 29,
          'completion_tokens': 3,
          'total_tokens': 32,
        },
        'request_settings' => {'temperature': 0.1},
        _ => [99],
      };
      expect(
        pixelQwen35ArithmeticFailures(changed, reference: passing()),
        contains('parity.$field'),
        reason: field,
      );
    }
  });
  test('missing geometry, usage, stream and thinking evidence fail closed', () {
    for (final (field, value, reason) in <(String, Object?, String)>[
      ('rendered_input_ids', [1, 2, 3, 4, 5, 6, 7, 8], 'geometry'),
      ('visible_output_retokenization_ids', [], 'visible_output_ids'),
      ('native_usage_counts', null, 'usage'),
      ('stream_completed', false, 'stream'),
      ('ordered_terminal', false, 'stream'),
      ('thinking', 'hidden answer', 'thinking'),
      ('finish_reason', null, 'finish'),
    ]) {
      expect(
        pixelQwen35ArithmeticFailures({...passing(), field: value}),
        contains(reason),
      );
    }
  });
  test(
    'recovery and missing required range/control rows cannot be omitted',
    () {
      final requiredCases = pixelQwen35RequiredCases();
      expect(requiredCases.toSet().length, requiredCases.length);
      for (final size in [1, 2, 3, 4, 5, 6, 7, 8]) {
        expect(requiredCases, contains('gpu-size-$size'));
      }
      for (final size in [9, 32, 33, 64, 512]) {
        expect(requiredCases, contains('gpu-refuse-$size'));
      }
      expect(
        requiredCases,
        containsAll([
          'cpu-original',
          'cpu-original.C06.history',
          'gpu-default',
          'gpu-default.C06.history',
          'gpu-default.C04.post-refusal',
          'cpu-size-32',
          'vulkan-zero-layers-size-32',
          'media.image',
          'media.audio',
          'media.video',
          'embedding.single',
          'embedding.batch',
          'embedding.content',
          'embedding.content-batch',
          'speculation.legacy',
          'speculation.mixed',
          'speculation.external-pre-io',
          for (final strategy in SpeculativeDecodingStrategy.values)
            'speculation.${strategy.name}',
        ]),
      );
      for (final missing in requiredCases) {
        expect(
          pixelQwen35MissingCases(
            requiredCases,
            requiredCases.where((id) => id != missing),
          ),
          [missing],
        );
      }
      expect(pixelQwen35MissingCases(requiredCases, requiredCases), isEmpty);
    },
  );
  test('C06 preserves capitalization and repeated-token failures', () {
    expect(pixelQwen35HistoryPass('cedar17\n'), isTrue);
    for (final text in [
      'Cedar17',
      'CEDAR17',
      'cedar17.',
      '88888888888888888888888888888888',
    ]) {
      expect(pixelQwen35HistoryPass(text), isFalse);
    }
  });
  test('generic refusal cannot establish the architecture restriction', () {
    expect(
      pixelQwen35TypedRefusal(LlamaUnsupportedException('missing media')),
      isFalse,
    );
    expect(
      pixelQwen35TypedRefusal(LlamaUnsupportedException('Android/Vulkan #948')),
      isTrue,
    );
    expect(pixelQwen35TypedRefusal(StateError('Android/Vulkan #948')), isFalse);
  });
  const positive =
      'llama_prepare_model_devices: using device Vulkan0 (Mali-G715) - 100 MiB free\n'
      'load_tensors: offloaded 25/25 layers to GPU\n'
      'sched_reserve: Vulkan0 compute buffer size = 12.34 MiB\n';
  test('CPU, software, missing, zero and mismatched placement cannot pass', () {
    expect(pixelQwen35VulkanPlacement(positive), isTrue);
    for (final negative in [
      positive.replaceAll('Vulkan0 compute', 'CPU compute'),
      positive.replaceAll('Mali-G715', 'SwiftShader'),
      positive.replaceAll('25/25', '0/25'),
      positive.replaceAll('12.34', '0.00'),
      positive.replaceAll('using device Vulkan0', 'using device Vulkan1'),
      '$positive$positive',
      'Vulkan requested; Mali-G715 is available',
    ]) {
      expect(pixelQwen35VulkanPlacement(negative), isFalse);
    }
  });
  test('safe facts or absent cap evidence cannot enable restricted probes', () {
    const prefix =
        'Android Vulkan text prompt decode is capped at 8 tokens per call ';
    const device = '"Mali-G715" (API 1.3, loader 1.3, subgroup size 16)';
    expect(pixelQwen35RestrictedFacts(['$prefix($device)']), isTrue);
    expect(pixelQwen35RestrictedFacts(['$prefix(probe unavailable)']), isTrue);
    expect(pixelQwen35RestrictedFacts([]), isFalse);
    expect(
      pixelQwen35RestrictedFacts(['$prefix(${device.replaceAll('16', '32')})']),
      isFalse,
    );
    expect(
      pixelQwen35RestrictedFacts([
        '${prefix.replaceAll('capped at 8 tokens per call', 'not capped')}($device)',
      ]),
      isFalse,
    );
  });
}
