import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_validation/android_qualification.dart';
import 'package:llamadart_validation/android_qualification_io.dart';
import 'package:test/test.dart';

void main() {
  const pixel = AndroidQualificationPlan(AndroidQualificationScenario.pixel8a);
  const a35 = AndroidQualificationPlan(AndroidQualificationScenario.a35);
  test(
    'nonfinite returned vector bytes survive before a JSON oracle can run',
    () {
      final encoded = androidQualificationVectorBytes([
        1.0,
        double.infinity,
        double.nan,
      ]);
      final bytes = ByteData.sublistView(base64Decode(encoded));
      expect(bytes.getFloat64(0, Endian.little), 1.0);
      expect(bytes.getFloat64(8, Endian.little), double.infinity);
      expect(bytes.getFloat64(16, Endian.little).isNaN, isTrue);
    },
  );
  test('original models and geometry cannot become the stock BF16 pack', () {
    expect(
      pixel.model['sha256'],
      '2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135',
    );
    expect(pixel.model['bytes'], 309855456);
    expect(
      pixel.modelUrl,
      contains('/6ea3e3a309d12a4779cfda98b8c19800d2d5da71/'),
    );
    expect(pixel.params('vulkan').microBatchSize, 1024);
    expect(pixel.params('vulkan').device, ComputeDevice.gpu);
    expect(pixel.params('cpu').gpuLayers, 0);
    expect(a35.params('vulkan').microBatchSize, 512);
    expect(a35.params('vulkan').flashAttention, FlashAttention.disabled);
    expect(a35.nativeBackends, ['cpu', 'vulkan-defaults', 'vulkan']);
    expect(pixel.caseIds, contains('pixel8a.native.vulkan-probe'));
    expect(
      pixel.configuration['public_process_scope'],
      'serialized_complete_engine_lifetimes',
    );
    expect(pixel.hash, isNot(a35.hash));
    expect(() => pixel.params('auto'), throwsArgumentError);
  });

  test(
    'actual context geometry must be complete and agree across native records',
    () {
      expect(
        matchesAndroidQualificationGeometry(
          'llama_context: n_ctx = 1024\n'
          'llama_context: n_batch = 1024\nllama_context: n_ubatch = 1024',
          pixel,
        ),
        isTrue,
      );
      expect(
        matchesAndroidQualificationGeometry(
          'n_ctx=1024 n_batch=512 n_ubatch=512',
          pixel,
        ),
        isFalse,
      );
      expect(
        matchesAndroidQualificationGeometry('n_ctx=1024 n_batch=1024', pixel),
        isFalse,
      );
      expect(
        matchesAndroidQualificationGeometry(
          'n_ctx=1024 n_batch=1024 n_ubatch=1024\nn_ubatch=8',
          pixel,
        ),
        isFalse,
      );
    },
  );

  test(
    'embedding oracle rejects zero, malformed, unnormalized and wrong inputs',
    () {
      final unit = [1.0, ...List.filled(767, 0.0)];
      final other = [0.0, 1.0, ...List.filled(766, 0.0)];
      expect(assessAndroidEmbedding(unit, unit)['passed'], isTrue);
      for (final vector in [
        List.filled(768, 0.0),
        List.filled(767, 0.0),
        [double.nan, ...unit.skip(1)],
        [double.infinity, ...unit.skip(1)],
        [2.0, ...unit.skip(1)],
        other,
      ]) {
        expect(assessAndroidEmbedding(vector, unit)['passed'], isFalse);
      }
    },
  );

  test('missing, duplicated or incorrect input/phase cells block timing', () {
    final unit = [1.0, ...List.filled(767, 0.0)];
    final reference = [
      for (var input = 0; input < 2; input++)
        <String, dynamic>{
          'event': 'embedding',
          'input': input,
          'phase': 'probe',
          'tokens': input == 0 ? 9 : 46,
          'vector': unit,
          'operation_ms': 1.0,
        },
    ];
    expect(
      assessAndroidEmbeddingRecords(reference, reference, probeOnly: true),
      isTrue,
    );
    for (final broken in [
      reference.take(1).toList(),
      [...reference, reference.first],
      [
        reference.first,
        {...reference.last, 'tokens': 9},
      ],
      [
        reference.first,
        {...reference.last, 'phase': 'measured-1'},
      ],
      [
        reference.first,
        {...reference.last, 'operation_ms': double.infinity},
      ],
      [
        reference.first,
        {...reference.last, 'vector': List.filled(768, 0.0)},
      ],
    ]) {
      expect(
        assessAndroidEmbeddingRecords(broken, reference, probeOnly: true),
        isFalse,
      );
    }
    expect(
      assessAndroidEmbeddingRecords(reference, reference, probeOnly: false),
      isFalse,
    );
  });

  test('generation control cannot pass with empty or malformed transport', () {
    final good = <String, dynamic>{
      'event': 'generation',
      'prompt_tokens': 7,
      'token_ids': [8, 9],
      'eog': true,
      'output_hex': '2050617269732e',
    };
    expect(assessAndroidGenerationRecords([good]), isTrue);
    for (final bad in [
      <String, dynamic>{},
      {...good, 'token_ids': []},
      {...good, 'output_hex': 'ff'},
      {...good, 'output_hex': '20'},
      {...good, 'prompt_tokens': 0},
    ]) {
      expect(assessAndroidGenerationRecords([bad]), isFalse);
    }
  });

  test(
    'build binding rejects dirty, wrong-source and conflicting runtime inputs',
    () {
      final hash = 'a' * 64;
      final good = <String, dynamic>{
        'schema': 1,
        'plan_sha256': a35.hash,
        'source_dirty': false,
        'source_commit': 'b' * 40,
        'source_tree': 'c' * 40,
        'source_inventory_sha256': hash,
        'hook_sha256': hash,
        'probe_sha256': hash,
        'native_tag': 'v0.8.0-2',
        'native_archive_sha256':
            'a40669ffb3ab20a62028fbe65c0d217e5a36f71e4beef36447a6a630d5953a76',
        'libraries': {
          for (final name in [
            'libllama.so',
            'libggml-vulkan.so',
            'libllamadart_android_qualification.so',
          ])
            name: {'bytes': 12, 'sha256': hash},
        },
      };
      expect(
        readAndroidQualificationBinding(jsonEncode(good), a35)['source_dirty'],
        isFalse,
      );
      for (final bad in [
        {...good, 'source_dirty': true},
        {...good, 'source_commit': 'b'},
        {...good, 'native_tag': 'v0.7.0-1'},
        {...good, 'libraries': {}},
        {...good, 'probe_sha256': 'd' * 64},
        {...good, 'plan_sha256': pixel.hash},
      ]) {
        expect(
          () => readAndroidQualificationBinding(jsonEncode(bad), a35),
          throwsFormatException,
        );
      }
      expect(
        androidQualificationExecutionHash(good),
        isNot(
          androidQualificationExecutionHash({...good, 'source_tree': 'e' * 40}),
        ),
      );
    },
  );

  group('owned child capture', () {
    late Directory temporary;
    setUp(() {
      temporary = Directory.systemTemp.createTempSync('android-qualification-');
    });
    tearDown(() {
      temporary.deleteSync(recursive: true);
    });
    test(
      'mapped paths cannot substitute same-name or modified runtime files',
      () async {
        final inventory = <String, dynamic>{};
        for (final name in [
          'libllama.so',
          'libggml-base.so',
          'libggml-vulkan.so',
        ]) {
          final file = File('${temporary.path}/$name')..writeAsStringSync(name);
          inventory[name] = {
            'bytes': file.lengthSync(),
            'sha256': sha256.convert(file.readAsBytesSync()).toString(),
          };
        }
        String maps(String directory) => inventory.keys
            .map((name) => '1000-2000 r-xp 00000000 00:00 1 $directory/$name')
            .join('\n');
        await verifyAndroidQualificationMaps(maps(temporary.path), temporary, {
          'libraries': inventory,
        }, vulkan: true);
        await expectLater(
          verifyAndroidQualificationMaps(maps('/wrong'), temporary, {
            'libraries': inventory,
          }, vulkan: true),
          throwsFormatException,
        );
        await expectLater(
          verifyAndroidQualificationMaps(
            '${maps(temporary.path)}\n'
            '1000-2000 r-xp 00000000 00:00 1 ${temporary.path}/libllama.so (deleted)',
            temporary,
            {'libraries': inventory},
            vulkan: true,
          ),
          throwsFormatException,
        );
        File('${temporary.path}/libllama.so').writeAsStringSync('bad');
        await expectLater(
          verifyAndroidQualificationMaps(maps(temporary.path), temporary, {
            'libraries': inventory,
          }, vulkan: true),
          throwsFormatException,
        );
      },
    );
    Future<Map<String, dynamic>> run(
      String mode, {
      int limit = 2 * 1024 * 1024,
    }) => captureAndroidNativeChild(
      executable: (Process.runSync('which', ['python3']).stdout as String)
          .trim(),
      arguments: [
        'test/fixtures/android_qualification/child.py',
        mode,
        a35.hash,
        'a35.native.cpu',
      ],
      output: Directory('${temporary.path}/$mode'),
      binding: a35.hash,
      caseId: 'a35.native.cpu',
      timeout: Duration(milliseconds: mode == 'hang' ? 300 : 3000),
      stdoutLimit: limit,
    );
    test('keeps exact stderr bytes before protocol validation', () async {
      final value = await run('success');
      expect(value['protocol_complete'], isTrue);
      expect(value['qualified'], isFalse);
      expect(File('${temporary.path}/success/stderr.log').readAsBytesSync(), [
        ...utf8.encode('raw-native-stderr'),
        0,
        255,
        10,
      ]);
      expect((value['records'] as List).last['event'], 'finished');
      expect(value['capture_complete'], isTrue);
    });
    test('kills a hung child and retains partial raw output', () async {
      final value = await run('hang');
      expect(value['timed_out'], isTrue);
      expect(value['exit_code'], isNot(0));
      expect(value['qualified'], isFalse);
      expect(value, isNot(contains('records')));
      expect(
        Process.killPid(value['pid'] as int, ProcessSignal.sigkill),
        isFalse,
      );
      expect(
        File('${temporary.path}/hang/stdout.jsonl').lengthSync(),
        greaterThan(0),
      );
    });
    test(
      'bounds streamed output and retains a failed capture receipt',
      () async {
        final value = await run('overflow', limit: 1024);
        expect(value['capture_limit_exceeded'], isTrue);
        expect(value['capture_complete'], isFalse);
        expect(
          File('${temporary.path}/overflow/stdout.jsonl').lengthSync(),
          1024,
        );
      },
    );
    for (final mode in ['truncated', 'wrong-binding', 'failure']) {
      test('$mode never gains protocol success', () async {
        final value = await run(mode);
        expect(value['protocol_complete'], isNot(true));
        expect(value['qualified'], isFalse);
        expect(
          File('${temporary.path}/$mode/capture.json').existsSync(),
          isTrue,
        );
      });
    }
  });

  test('protocol binds PID, case, sequence and complete lifetime', () {
    List<int> encoded(List<Map<String, Object>> records) =>
        utf8.encode('${records.map(jsonEncode).join('\n')}\n');
    Map<String, Object> record(String event, int sequence) => {
      'schema': 1,
      'binding': a35.hash,
      'case_id': 'a35.native.cpu',
      'pid': 123,
      'sequence': sequence,
      'event': event,
    };
    final good = [record('started', 0), record('finished', 1)];
    List<Map<String, dynamic>> parse(List<int> bytes) =>
        parseAndroidNativeRecords(
          bytes,
          binding: a35.hash,
          caseId: 'a35.native.cpu',
          processId: 123,
        );
    expect(parse(encoded(good)), hasLength(2));
    for (final bad in [
      [good.first],
      [good.last, good.first],
      [
        good.first,
        {...good.last, 'pid': 124},
      ],
      [
        good.first,
        {...good.last, 'sequence': 9},
      ],
      [
        good.first,
        {...good.last, 'case_id': 'pixel8a.native.cpu'},
      ],
    ]) {
      expect(() => parse(encoded(bad)), throwsFormatException);
    }
    expect(() => parse([255]), throwsFormatException);
  });
}
