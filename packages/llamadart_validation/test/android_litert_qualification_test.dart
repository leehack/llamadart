import 'dart:convert';
import 'dart:io';

import 'package:llamadart_validation/android_litert_qualification.dart';
import 'package:llamadart_validation/android_litert_qualification_io.dart';
import 'package:test/test.dart';

Map<String, dynamic> profile(String backend) =>
    jsonDecode(
          File('assets/profiles/chat-litert-$backend.json').readAsStringSync(),
        )
        as Map<String, dynamic>;
String repeated(String value, int count) => List.filled(count, value).join();
Map<String, dynamic> binding() {
  final libraries = {
    for (final name in s24LiteRtNativeLibraries)
      name: {'bytes': 7, 'sha256': repeated('a', 64)},
  };
  return {
    'schema': 1,
    'source_dirty': false,
    'source_commit': repeated('a', 40),
    'source_tree': repeated('b', 40),
    'owner_commit': repeated('c', 40),
    for (final key in [
      'source_inventory_sha256',
      'runtime_archive_sha256',
      'runtime_manifest_sha256',
      'shared_budget_receipt_sha256',
      'template_sha256',
    ])
      key: repeated('d', 64),
    'runtime_tag': 'v0.19.0',
    'abi': 'android-arm64',
    'test_class': 'com.example.llamadart_chat_example.S24LiteRtPublicTest',
    'max_minutes': 20,
    'execution_count': 1,
    'reservation_usd': '2.50',
    'shared_cap_usd': '22.50',
    'profiles': {'cpu': profile('cpu'), 'gpu': profile('gpu')},
    'libraries': {
      ...libraries,
      'libllamadart_litert_child.so': {'bytes': 7, 'sha256': repeated('a', 64)},
    },
    'child_sha256': repeated('a', 64),
    'archive_libraries': jsonDecode(jsonEncode(libraries)),
    'owner_libraries': jsonDecode(jsonEncode(libraries)),
  };
}

Map<String, dynamic> observation({
  bool automatic = false,
  String lifetimeId = 'cpu-corrected.1',
}) => {
  'backend_name': 'LiteRT-LM cpu',
  'reported_gpu_layers': 0,
  'native_finish': 'not_exposed_by_default_service',
  'native_settlement': 'settled',
  'input_tokens': 12,
  'output_tokens': 3,
  'public_process_pid': 123,
  'process_cpu_delegate_initialization': {
    'pid': 123,
    'capture': captureS24LiteRtBytes(
      utf8.encode('Created TensorFlow Lite XNNPACK delegate for CPU.'),
    ),
  },
  'native_stderr': {
    ...captureS24LiteRtBytes(
      utf8.encode(
        'Flatbuffer model initialized directly from incoming litert model.',
      ),
    ),
    'lifetime_id': lifetimeId,
    'empty_at_load': true,
  },
  'mapped_core_verified': true,
  'warnings': [if (automatic) '$s24LiteRtFallbackWarning More details.'],
};

void main() {
  test(
    'maintained profiles keep distinct byte identities and fixed C04 oracles',
    () {
      for (final backend in ['cpu', 'gpu']) {
        requireS24LiteRtProfile(profile(backend), backend);
      }
      final changed = profile('gpu');
      (changed['model'] as Map)['sha256'] = s24LiteRtCpuHash;
      expect(
        () => requireS24LiteRtProfile(changed, 'gpu'),
        throwsFormatException,
      );
      final prompt = profile('cpu');
      (prompt['fixtures'] as Map)['arithmetic']['prompt'] = 'What is 2 + 2?';
      expect(
        () => requireS24LiteRtProfile(prompt, 'cpu'),
        throwsFormatException,
      );
    },
  );
  test(
    'binding needs final owner, complete payloads and original shared cap',
    () {
      requireS24LiteRtBinding(binding());
      for (final mutation in <void Function(Map<String, dynamic>)>[
        (value) =>
            value['owner_commit'] = '7ea10d0cce10dfddbae273bb69e253d9ea97e1d2',
        (value) => value['source_dirty'] = true,
        (value) => value.remove('shared_budget_receipt_sha256'),
        (value) => value['shared_cap_usd'] = '25.00',
        (value) => value['execution_count'] = 2,
        (value) => (value['libraries'] as Map).remove('libwebgpu_dawn.so'),
        (value) => value['owner_libraries']['libLiteRtLm.so']['sha256'] =
            repeated('f', 64),
      ]) {
        final value = binding();
        mutation(value);
        expect(() => requireS24LiteRtBinding(value), throwsFormatException);
      }
    },
  );
  test('raw capture preserves invalid UTF8 and NUL without interpretation', () {
    final raw = [0, 0xc3, 0x8a, 0xff];
    final captured = captureS24LiteRtBytes(raw);
    expect(readS24LiteRtBytes(captured), raw);
    captured['base64'] = base64Encode([0, 0xc3]);
    expect(() => readS24LiteRtBytes(captured), throwsFormatException);
  });
  test('C04 semantic oracles do not become transport-only passes', () {
    requireS24LiteRtAnswer('hello', utf8.encode('Hello!'));
    requireS24LiteRtAnswer('arithmetic', utf8.encode('7'));
    requireS24LiteRtAnswer('arithmetic', utf8.encode('3 + 4 = 7.'));
    for (final wrong in ['2', '4', 'Osaka', '7 extra', '<think>7</think>']) {
      expect(
        () => requireS24LiteRtAnswer('arithmetic', utf8.encode(wrong)),
        throwsFormatException,
      );
    }
  });
  test(
    'auto requires correlated failure and CPU evidence, not selector hints',
    () {
      requireS24LiteRtCpuObservation(
        observation(),
        automatic: false,
        lifetimeId: 'cpu-corrected.1',
      );
      requireS24LiteRtCpuObservation(
        observation(automatic: true, lifetimeId: 'cpu-corrected.1'),
        automatic: true,
        lifetimeId: 'cpu-corrected.1',
      );
      expect(
        () => requireS24LiteRtCpuObservation(
          observation(),
          automatic: true,
          lifetimeId: 'cpu-corrected.1',
        ),
        throwsFormatException,
      );
      for (final key in ['mapped_core_verified']) {
        final value = observation(
          automatic: true,
          lifetimeId: 'cpu-corrected.1',
        )..[key] = false;
        expect(
          () => requireS24LiteRtCpuObservation(
            value,
            automatic: true,
            lifetimeId: 'cpu-corrected.1',
          ),
          throwsFormatException,
        );
      }
      final stale = observation();
      (stale['native_stderr'] as Map)['lifetime_id'] = 'cpu-corrected.0';
      expect(
        () => requireS24LiteRtCpuObservation(
          stale,
          automatic: false,
          lifetimeId: 'cpu-corrected.1',
        ),
        throwsFormatException,
      );
      final inventedFinish = observation()..['native_finish'] = 'stop';
      expect(
        () => requireS24LiteRtCpuObservation(
          inventedFinish,
          automatic: false,
          lifetimeId: 'cpu-corrected.1',
        ),
        throwsFormatException,
      );
    },
  );
  test(
    'S24 child ignores GGUF grading but requires every raw transport receipt',
    () {
      final lock = repeated('a', 64);
      final rows = [
        {
          'schema': 1,
          'binding': lock,
          'case_id': 's24.native.launch',
          'pid': 123,
          'sequence': 0,
          'event': 'started',
        },
        {
          'schema': 1,
          'binding': lock,
          'case_id': 's24.native.launch',
          'pid': 123,
          'sequence': 1,
          'event': 'finished',
        },
      ];
      final out = utf8.encode("${rows.map(jsonEncode).join('\n')}\n");
      final err = utf8.encode('actual stderr bytes');
      final receipt = <String, dynamic>{
        'binding': lock,
        'case_id': 's24.native.launch',
        'pid': 123,
        'exit_code': 0,
        'timed_out': false,
        'capture_limit_exceeded': false,
        'capture_failed': false,
        'elapsed_ms': 100,
        'protocol_complete': false,
        'files': {
          'stdout.jsonl': captureS24LiteRtBytes(out),
          'stderr.log': captureS24LiteRtBytes(err),
        },
      };
      List<Map<String, dynamic>> parse(Map value, [List<int>? output]) =>
          readS24LiteRtChildRecords(
            value,
            output ?? out,
            err,
            binding: lock,
            caseId: 's24.native.launch',
          );
      expect(parse(receipt), hasLength(2));
      for (final key in [
        'timed_out',
        'capture_limit_exceeded',
        'capture_failed',
      ]) {
        expect(() => parse({...receipt, key: true}), throwsFormatException);
      }
      expect(() => parse({...receipt, 'exit_code': -6}), throwsFormatException);
      expect(() => parse({...receipt, 'pid': 456}), throwsFormatException);
      expect(
        () => parse(receipt, out.sublist(0, out.length - 1)),
        throwsFormatException,
      );
    },
  );
  test(
    'raw native response keeps fixed positive oracle separate from transport',
    () {
      final wrong = utf8.encode(
        jsonEncode({
          'content': [
            {'type': 'text', 'text': '2'},
          ],
        }),
      );
      final answer = readS24LiteRtNativeAnswer(wrong);
      expect(answer, '2');
      expect(
        () => requireS24LiteRtAnswer('arithmetic', utf8.encode(answer)),
        throwsFormatException,
      );
      expect(
        () => readS24LiteRtNativeAnswer(utf8.encode('{}')),
        throwsFormatException,
      );
      expect(() => readS24LiteRtHex('8a2'), throwsFormatException);
    },
  );
  test('GPU initialization needs hardware records and rejects failure markers', () {
    const log =
        'Selected adapter: Adreno (TM) 750, arch=adreno, vendor=Qualcomm, backend=Vulkan, adapterType=Integrated GPU\n'
        'Created a WebGPU environment.\nTotal 2 external tensors are used for delegate inputs and outputs';
    expect(s24LiteRtGpuInitialized(log), isTrue);
    expect(s24LiteRtGpuInitialized('GPU registered'), isFalse);
    expect(
      s24LiteRtGpuInitialized(log.replaceAll('Vulkan', 'OpenGL')),
      isFalse,
    );
    expect(s24LiteRtGpuInitialized('$log\nVK_ERROR_DEVICE_LOST'), isFalse);
    expect(s24LiteRtStageSeconds.values.fold<int>(0, (a, b) => a + b), 1050);
    expect(s24LiteRtStageSeconds.values.every((value) => value <= 150), isTrue);
  });
}
