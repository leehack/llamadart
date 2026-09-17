import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart_validation/io.dart';
import 'package:llamadart_validation/llamadart_validation.dart';
import 'package:llamadart_validation/src/placement.dart';
import 'package:test/test.dart';

ValidationProfile profile({String backend = 'cpu', bool release = false}) {
  final json =
      jsonDecode(
            File('assets/profiles/chat-litert-cpu.json').readAsStringSync(),
          )
          as Map<String, dynamic>;
  json['backend'] = backend;
  json['selection'] = release ? 'release' : 'quick';
  return ValidationProfile.fromJson(json);
}

class FakeEngine implements ValidationEngine {
  @override
  bool isWeb = false;
  bool rejectBatching = false;
  String? batchingFault;
  bool _batchingSeen = false;
  var disposed = false;
  var cancelled = false;
  var loads = 0;
  int? failOnLoad;
  var disposeCalls = 0;
  var generated = 0;
  var wrongArithmetic = false;
  var wrongHistory = false;
  final requests = <Map<String, dynamic>>[];
  var ignoresCancellation = false;
  String backendName = 'LiteRT-LM CPU';
  Map<String, dynamic> metadata = {};
  int? switchAfterLoad;
  Completer<void>? pauseReload;
  var timeout = false;
  var cleanupFails = false;
  @override
  Future<void> load(String location, ValidationProfile profile) async {
    if (location.endsWith('.missing')) {
      throw LlamaModelException('missing model');
    }
    loads++;
    if (loads == failOnLoad) throw LlamaModelException('reload failed');
    if (loads == 2) await pauseReload?.future;
  }

  @override
  Future<void> unload() async {}
  @override
  Future<void> dispose() async {
    disposeCalls++;
    disposed = true;
    if (cleanupFails) throw StateError('cleanup failure');
  }

  @override
  void cancel() {
    cancelled = true;
  }

  @override
  Future<Map<String, dynamic>> diagnostics() async => {
    'model_metadata': metadata,
    'backend_name': switchAfterLoad != null && loads >= switchAfterLoad!
        ? 'Metal'
        : backendName,
  };
  @override
  Future<List<int>> tokenize(String text) async => utf8.encode(text);
  @override
  Future<String> detokenize(List<int> tokens) async => utf8.decode(tokens);
  @override
  Future<Map<String, dynamic>> generate(
    String prompt,
    ValidationProfile profile, {
    bool raw = false,
    int? maxTokens,
    int? streamBatchTokens,
    int? streamBatchBytes,
    bool cancelAfterFirst = false,
    List<LlamaChatMessage>? history,
  }) async {
    generated++;
    final adjusted = streamBatchTokens != null || streamBatchBytes != null;
    requests.add({
      'prompt': prompt,
      'history': history,
      'batch_tokens': streamBatchTokens,
      'batch_bytes': streamBatchBytes,
    });
    if (adjusted && rejectBatching) {
      _batchingSeen = true;
      if (batchingFault == 'wrong_error') throw StateError('failed');
      throw LlamaUnsupportedException(
        batchingFault == 'wrong_option'
            ? 'unrelated option'
            : 'streamBatchTokenThreshold streamBatchByteThreshold',
      );
    }
    final recovering = _batchingSeen && !adjusted;
    if (adjusted) _batchingSeen = true;
    if (timeout) return Completer<Map<String, dynamic>>().future;
    return {
      'content':
          (adjusted && batchingFault == 'content') ||
              (recovering && batchingFault == 'recovery')
          ? 'corrupted'
          : history != null || prompt.contains('The secret code is cedar17.')
          ? wrongHistory
                ? '77777777777777777777777777777777'
                : 'cedar17'
          : prompt.contains('2 + 2')
          ? wrongArithmetic
                ? '2'
                : '4'
          : 'hello',
      'thinking': adjusted && batchingFault == 'thinking' ? 'changed' : '',
      'chunks': adjusted ? 32 : 5,
      'stream_batch_tokens': batchingFault == 'config'
          ? 8
          : streamBatchTokens ?? 8,
      'stream_batch_bytes': streamBatchBytes ?? 512,
      'stream_completed':
          !(adjusted && batchingFault == 'incomplete') &&
          !(recovering && batchingFault == 'recovery'),
      'completion_order_valid': !(adjusted && batchingFault == 'order'),
      'tool_call_deltas': adjusted && batchingFault == 'tools'
          ? [
              {'index': 0},
            ]
          : [],
      'finish_reasons': raw
          ? []
          : [adjusted && batchingFault == 'finish' ? 'length' : 'stop'],
      'prompt': prompt,
      'cancel_requested': cancelAfterFirst,
      'cancel_to_done_ms': cancelAfterFirst ? 1 : null,
      'metrics': {
        'native_decode_tokens':
            maxTokens == 1 || (cancelAfterFirst && !ignoresCancellation)
            ? 1
            : 8,
        'native_decode_tps': 12,
        'estimated_wall_tps': 10,
        'ttfa_ms': 5,
      },
    };
  }
}

Future<({ValidationReport report, List<Map<String, dynamic>> events})> run(
  FakeEngine engine, {
  ValidationProfile? selected,
}) async {
  final events = <Map<String, dynamic>>[];
  await ValidationRunner(
    profile: selected ?? profile(),
    engine: engine,
    emit: (event) async {
      events.add(event);
    },
    caseTimeout: const Duration(milliseconds: 30),
  ).run(
    'model.litertlm',
    runId: 'test-run',
    preparation: {
      'verified': true,
      'sha256': (selected ?? profile()).modelHash,
      'bytes': (selected ?? profile()).model['bytes'],
    },
    environment: {
      'source_commit': List.filled(40, 'a').join(),
      'source_dirty': false,
      'hook_sha256': List.filled(64, 'b').join(),
      'native_tag': 'v0.4.0',
      'litert_tag': '0.17.0-3',
    },
  );
  return (
    report: ValidationReport.parse(events.map(jsonEncode).join('\n')),
    events: events,
  );
}

void main() {
  ValidationProfile focused(List<String> features) =>
      ValidationProfile.fromJson(
        profile().toJson()
          ..['selection'] = 'focused'
          ..['focus_features'] = features,
      );

  test(
    'focused lifecycle runs a second dispose/load/generation cycle',
    () async {
      final engine = FakeEngine();
      final result = await run(engine, selected: focused(['lifecycle']));
      expect(result.report.qualified, true);
      expect(
        engine.loads,
        4,
      ); // Initial, first cycle, invalid-file recovery, second.
      expect(engine.disposeCalls, 3); // Both cycles and final cleanup.
      expect(result.report.cases.last['case_id'], 'C09.reload.second');
      expect(result.report.cases.last['status'], 'PASS');
      expect(
        result.report.cases.map((c) => c['case_id']),
        isNot(contains('C07.tools')),
      );
    },
  );

  test(
    'second-cycle load failure stays visible and cleanup still runs',
    () async {
      final engine = FakeEngine()..failOnLoad = 4;
      final result = await run(engine, selected: focused(['lifecycle']));
      expect(result.report.qualified, false);
      expect(result.report.cases.last['status'], 'ERROR');
      expect(result.report.cases.last['error_type'], 'LlamaModelException');
      expect(engine.disposeCalls, 3);
      expect(result.report.cleanupPassed, true);
    },
  );

  test(
    'focused selection adds only matching obligations to the quick core',
    () async {
      final selected = focused(['streaming', 'tools']);
      expect(selected.caseIds, [
        ...profile().caseIds,
        'C07.tools',
        'C10.stop',
        'C11.batching',
      ]);
      expect(selected.focusFeatures, ['streaming', 'tools']);
      final result = await run(FakeEngine(), selected: selected);
      expect(result.report.qualified, false);
      expect(
        result.report.cases
            .where((c) => c['status'] == 'NOT_RUN')
            .map((c) => c['case_id']),
        ['C07.tools', 'C10.stop'],
      );
      expect(result.report.problems, isEmpty);
    },
  );

  test(
    'focused batching verifies reconstruction, configuration and recovery',
    () async {
      final engine = FakeEngine();
      final result = await run(engine, selected: focused(['batching']));
      final record = result.report.cases.last;
      expect(record['case_id'], 'C11.batching');
      expect(result.report.qualified, true);
      expect(record['case_version'], 2);
      expect((record['batched'] as Map)['chunks'], 32);
      expect((record['control'] as Map)['chunks'], 5);
      expect(
        engine.requests.where(
          (r) => r['batch_tokens'] == 1 && r['batch_bytes'] == 1,
        ),
        hasLength(1),
      );
      expect(record['reconstruction_equal'], true);
      expect(record['configurations_verified'], true);
    },
  );

  for (final fault in [
    'content',
    'thinking',
    'finish',
    'config',
    'incomplete',
    'order',
    'recovery',
  ]) {
    test('batching rejects $fault mismatch', () async {
      final result = await run(
        FakeEngine()..batchingFault = fault,
        selected: focused(['batching']),
      );
      expect(result.report.cases.last['status'], 'FAIL');
      expect(result.report.qualified, false);
      expect(result.report.cleanupPassed, true);
    });
  }

  test(
    'unqualified tool output and NPU defaults remain explicit gaps',
    () async {
      final tool = await run(
        FakeEngine()..batchingFault = 'tools',
        selected: focused(['batching']),
      );
      expect(tool.report.cases.last['status'], 'NOT_RUN');
      expect(tool.report.qualified, false);
      final webData =
          jsonDecode(
                File(
                  'assets/profiles/tiny-gguf-batching.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final web = await run(
        FakeEngine()
          ..isWeb = true
          ..backendName = 'CPU',
        selected: ValidationProfile.fromJson(webData),
      );
      expect(web.report.cases.last['status'], 'NOT_RUN');
      expect(web.report.cases.last['reason'], contains('browser'));
      final data = focused(['batching']).toJson()..['backend'] = 'npu';
      for (final native in [false, true]) {
        if (native) data['execution_path'] = 'native_c_api';
        final result = await run(
          FakeEngine()..backendName = 'LiteRT-LM NPU',
          selected: ValidationProfile.fromJson(data),
        );
        expect(result.report.cases.last['status'], 'NOT_RUN');
        expect(
          result.report.cases.last['reason'],
          contains(native ? 'bypasses' : 'sampling'),
        );
      }
    },
  );

  test(
    'LiteRT Web requires both named typed rejections and recovery',
    () async {
      for (final fault in [null, 'wrong_option', 'wrong_error', 'recovery']) {
        final result = await run(
          FakeEngine()
            ..isWeb = true
            ..rejectBatching = true
            ..batchingFault = fault,
          selected: focused(['batching']),
        );
        expect(
          result.report.cases.last['status'],
          fault == null
              ? 'PASS'
              : fault == 'wrong_error'
              ? 'ERROR'
              : 'FAIL',
        );
        if (fault == null) {
          expect(
            (result.report.cases.last['rejected_options'] as List),
            hasLength(2),
          );
          expect(
            result.report.cases.last['coverage'],
            'litert_web_native_option_rejection_and_recovery',
          );
        }
      }
      final ignored = await run(
        FakeEngine()..isWeb = true,
        selected: focused(['batching']),
      );
      expect(ignored.report.cases.last['status'], 'FAIL');
    },
  );

  test(
    'previous schema-2 catalog preserves its original obligations',
    () async {
      final selected = focused(['streaming']);
      final result = await run(FakeEngine(), selected: selected);
      final events = result.events;
      events.first['catalog'] = selected.catalogForVersion(1);
      events.first['catalog_hash'] = jsonHash(events.first['catalog']);
      final batching = events.singleWhere(
        (e) => e['type'] == 'case' && e['case_id'] == 'C11.batching',
      );
      batching['case_version'] = 1;
      batching['fixture_hash'] = jsonHash(
        selected.caseFixtures('C11.batching', catalogVersion: 1),
      );
      batching['status'] = 'NOT_RUN';
      final report = ValidationReport.parse(events.map(jsonEncode).join('\n'));
      expect(report.problems, isEmpty);
      expect(report.cases.last['status'], 'NOT_RUN');
      events.first['catalog'] = selected.catalogForVersion(1)
        ..['version'] = 999;
      events.first['catalog_hash'] = jsonHash(events.first['catalog']);
      expect(
        ValidationReport.parse(events.map(jsonEncode).join('\n')).qualified,
        false,
      );
    },
  );

  test('batching feature cannot downgrade to old catalog', () async {
    final selected = focused(['batching']);
    expect(() => selected.catalogForVersion(1), throwsFormatException);
  });

  test(
    'invalid feature selections and fixture overrides fail before execution',
    () {
      for (final patch in <Map<String, dynamic>>[
        {'selection': 'focused'},
        {'selection': 'focused', 'focus_features': []},
        {
          'selection': 'focused',
          'focus_features': ['tools', 'tools'],
        },
        {
          'selection': 'focused',
          'focus_features': ['unknown'],
        },
        {'focus_features': []},
        {
          'focus_features': ['tools'],
        },
        {
          'fixtures': {
            'hello': {'prompt': 3},
          },
        },
        {
          'fixtures': {
            'hello': {'unknown': 'ignored'},
          },
        },
        {
          'fixtures': {
            'unknown': {'prompt': 'ignored'},
          },
        },
      ]) {
        expect(
          () => ValidationProfile.fromJson(profile().toJson()..addAll(patch)),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'catalog records resolved prompts, versions and explicit omissions',
    () async {
      final data = profile().toJson();
      (data['fixtures'] as Map)['hello'] = {'prompt': 'Please answer hello.'};
      final selected = ValidationProfile.fromJson(data);
      final engine = FakeEngine();
      final result = await run(engine, selected: selected);
      expect(result.report.qualified, true);
      final manifest = result.events.first;
      expect(manifest['schema_version'], 2);
      expect(manifest['catalog_hash'], jsonHash(selected.catalog));
      expect((manifest['catalog'] as Map)['fixtures'], selected.fixtures);
      expect(
        engine.requests
            .where((r) => r['prompt'] == 'Please answer hello.')
            .length,
        greaterThan(1),
      );
      final omitted = ((manifest['catalog'] as Map)['cases'] as List)
          .cast<Map>()
          .singleWhere((c) => c['id'] == 'C07.tools');
      expect(omitted['selected'], false);
      expect(omitted['omission_reason'], 'outside_selected_features');
      for (final record in result.report.cases) {
        expect(record['case_version'], 1);
        expect(
          record['fixture_hash'],
          jsonHash(selected.caseFixtures(record['case_id'] as String)),
        );
      }
    },
  );

  test('rehashed catalog edits and missing metadata cannot qualify', () async {
    for (final omit in [false, true]) {
      final result = await run(FakeEngine());
      final manifest = result.events.first;
      if (omit) {
        manifest.remove('catalog');
      } else {
        final catalog = jsonDecode(jsonEncode(manifest['catalog'])) as Map;
        (catalog['fixtures'] as Map)['history']['expected'] =
            'a different code';
        manifest['catalog'] = catalog;
      }
      manifest['catalog_hash'] = jsonHash(manifest['catalog']);
      final report = ValidationReport.parse(
        result.events.map(jsonEncode).join('\n'),
      );
      expect(report.qualified, false);
      expect(
        report.problems,
        contains('Catalog does not match the executable profile'),
      );
    }
  });

  test('case version and fixture identity are independently checked', () async {
    for (final field in ['case_version', 'fixture_hash']) {
      final result = await run(FakeEngine());
      result.events.firstWhere((e) => e['type'] == 'case')[field] =
          field == 'case_version' ? 2 : '0' * 64;
      final report = ValidationReport.parse(
        result.events.map(jsonEncode).join('\n'),
      );
      expect(report.qualified, false);
      expect(
        report.problems,
        contains('Case version or fixture identity mismatch: C01.load'),
      );
    }
  });

  test(
    'legacy quick journals remain readable without invented catalog metadata',
    () async {
      final result = await run(FakeEngine());
      result.events.first
        ..['schema_version'] = 1
        ..remove('catalog')
        ..remove('catalog_hash');
      for (final event in result.events) {
        event
          ..remove('case_version')
          ..remove('fixture_hash');
      }
      final report = ValidationReport.parse(
        result.events.map(jsonEncode).join('\n'),
      );
      expect(report.qualified, true);
      expect(report.manifest.containsKey('catalog'), false);
    },
  );

  test('legacy schema cannot claim unchecked catalog provenance', () async {
    final result = await run(FakeEngine());
    result.events.first['schema_version'] = 1;
    final report = ValidationReport.parse(
      result.events.map(jsonEncode).join('\n'),
    );
    expect(report.qualified, false);
    expect(
      report.problems,
      contains('Catalog metadata requires result schema 2'),
    );
    expect(
      report.toHtml(),
      contains('catalog version: unavailable in legacy journal'),
    );
  });

  test(
    'focused journals cannot downgrade to legacy selection semantics',
    () async {
      final result = await run(FakeEngine(), selected: focused(['lifecycle']));
      result.events.first['schema_version'] = 1;
      final report = ValidationReport.parse(
        result.events.map(jsonEncode).join('\n'),
      );
      expect(report.qualified, false);
      expect(
        report.problems,
        contains('Focused selection requires result schema 2'),
      );
    },
  );

  test('Gemma CPU control locks identity and matches NPU prompt settings', () {
    final selected = ValidationProfile.fromJson(
      jsonDecode(
            File('assets/profiles/gemma3-litert-cpu.json').readAsStringSync(),
          )
          as Map<String, dynamic>,
    );
    expect(selected.backend, 'cpu');
    expect(selected.contextSize, 1280);
    expect(selected.threads, 4);
    expect(selected.maxTokens, 32);
    expect(selected.enableThinking, true);
    expect(selected.effectiveConfig['enable_thinking'], true);
    expect(
      selected.effectiveConfig['sampling_application'],
      'requested_sampler',
    );
    expect(selected.historyControls, true);
    expect(selected.nativeReference, false);
    expect(
      selected.modelHash,
      '1325ae366d31950f137c9c357b9fa89448b176d76998180c08ceaca78bba98be',
    );
    expect(profile().enableThinking, false);
    expect(profile().historyControls, false);
    expect(profile(backend: 'npu').enableThinking, true);
  });

  test('history controls and thinking overrides reject invalid contracts', () {
    for (final patch in <Map<String, dynamic>>[
      {'enable_thinking': 'true'},
      {'history_controls': 1},
      {'history_controls': true, 'backend': 'gpu'},
      {'history_controls': true, 'backend': 'npu'},
      {
        'execution_path': 'native_c_api',
        'backend': 'npu',
        'enable_thinking': false,
      },
    ]) {
      expect(
        () => ValidationProfile.fromJson(profile().toJson()..addAll(patch)),
        throwsFormatException,
      );
    }
  });

  for (final native in [false, true]) {
    test(
      'history controls preserve distinct input and strict oracle: native=$native',
      () async {
        final data = profile(backend: native ? 'npu' : 'cpu').toJson()
          ..['execution_path'] = native ? 'native_c_api' : 'public_api';
        if (!native) data['history_controls'] = true;
        final engine = FakeEngine()
          ..backendName = native
              ? 'LiteRT-LM NPU direct C API'
              : 'LiteRT-LM CPU';
        final result = await run(
          engine,
          selected: ValidationProfile.fromJson(data),
        );
        expect(result.report.cases.length, native ? 12 : 17);
        expect(result.report.assertionsPassed, true);
        final histories = engine.requests
            .where((r) => r['history'] != null)
            .toList();
        expect(histories, hasLength(3));
        final canonical = histories[0]['history'] as List<LlamaChatMessage>;
        expect(canonical.map((m) => m.role.name), [
          'system',
          'user',
          'assistant',
          'user',
        ]);
        expect(canonical.map((m) => m.content), [
          'Remember the secret code exactly.',
          'The secret code is cedar17.',
          'I will remember the code.',
          'What is the secret code? Reply with only the code.',
        ]);
        final literal = histories[1]['history'] as List<LlamaChatMessage>;
        expect(jsonDecode(literal.first.content), {
          'role': 'system',
          'content': [
            {'type': 'text', 'text': canonical.first.content},
          ],
        });
        expect(
          literal.skip(1).map((m) => m.content),
          canonical.skip(1).map((m) => m.content),
        );
        final noSystem = histories[2]['history'] as List<LlamaChatMessage>;
        expect(noSystem.map((m) => m.role.name), ['user', 'assistant', 'user']);
        final combined = engine.requests.singleWhere(
          (r) =>
              r['history'] == null &&
              (r['prompt'] as String).contains('cedar17'),
        );
        expect(combined['prompt'], canonical.map((m) => m.content).join('\n'));

        final failed = await run(
          FakeEngine()
            ..wrongHistory = true
            ..backendName = native
                ? 'LiteRT-LM NPU direct C API'
                : 'LiteRT-LM CPU',
          selected: ValidationProfile.fromJson(data),
        );
        expect(failed.report.assertionsPassed, false);
        expect(
          failed.report.cases
              .where((c) => (c['case_id'] as String).startsWith('C06.'))
              .map((c) => c['status']),
          ['FAIL', 'FAIL', 'FAIL', 'FAIL'],
        );
      },
    );
  }
  test(
    'NPU candidates are locked and reject preparation before any download',
    () async {
      for (final target in ['qualcomm-sm8650', 'tensor-g5']) {
        final selected = ValidationProfile.fromJson(
          jsonDecode(
                File('assets/profiles/npu-$target.json').readAsStringSync(),
              )
              as Map<String, dynamic>,
        );
        expect(selected.backend, 'npu');
        expect(selected.contextSize, 1280);
        expect(selected.requiresAcceleratorProof, true);
        final directory = Directory.systemTemp.createTempSync(
          'npu-no-download-',
        );
        try {
          await expectLater(
            prepareModel(selected, directory),
            throwsA(isA<LlamaUnsupportedException>()),
          );
          expect(directory.listSync(), isEmpty);
        } finally {
          directory.deleteSync();
        }
      }
    },
  );
  test(
    'WASM CPU diagnostics require a CPU-only core and zero GPU layers',
    () async {
      final selected = profile().toJson()..['runtime'] = 'gguf';
      final model = Map<String, dynamic>.from(selected['model'] as Map);
      model['filename'] = 'model.gguf';
      model['url'] = (model['url'] as String).replaceAll('.litertlm', '.gguf');
      selected['model'] = model;
      for (final layers in ['0', '1', null]) {
        final engine = FakeEngine()
          ..backendName = 'WASM (Prototype bridge)'
          ..metadata = {
            'llamadart.webgpu.n_gpu_layers': layers,
            'llamadart.webgpu.core_variant': 'wasm32',
          };
        final result = await run(
          engine,
          selected: ValidationProfile.fromJson(selected),
        );
        for (final id in ['C01.load', 'C09.reload', 'C12.recovery']) {
          expect(
            result.report.cases.firstWhere(
              (record) => record['case_id'] == id,
            )['status'],
            layers == '0' ? 'PASS' : 'FAIL',
          );
        }
      }
    },
  );
  test(
    'missing or dirty provenance preserves assertions but cannot qualify',
    () async {
      final result = await run(FakeEngine());
      expect(result.report.assertionsPassed, true);
      for (final key in [
        'source_commit',
        'source_dirty',
        'hook_sha256',
        'litert_tag',
      ]) {
        final events = (jsonDecode(jsonEncode(result.events)) as List)
            .cast<Map>();
        (events.first['environment'] as Map).remove(key);
        final report = ValidationReport.parse(
          events.map(jsonEncode).join('\n'),
        );
        expect(report.assertionsPassed, true);
        expect(report.qualified, false);
        expect(report.toJUnit(), contains('run-integrity'));
        expect(report.provenanceProblems, isNotEmpty);
      }
      (result.events.first['environment'] as Map)['source_dirty'] = true;
      expect(
        ValidationReport.parse(
          result.events.map(jsonEncode).join('\n'),
        ).qualified,
        false,
      );
    },
  );
  test('model preparation must prove the exact locked hash and size', () async {
    final result = await run(FakeEngine());
    expect(result.report.qualified, true);
    final valid = result.events.first['preparation'] as Map;
    for (final preparation in [
      null,
      {},
      {...valid, 'verified': false},
      {...valid, 'sha256': '0' * 64},
      {...valid, 'bytes': 1},
      {...valid, 'bytes': '${valid['bytes']}'},
    ]) {
      final events = (jsonDecode(jsonEncode(result.events)) as List)
          .cast<Map>();
      events.first['preparation'] = preparation;
      final report = ValidationReport.parse(events.map(jsonEncode).join('\n'));
      expect(report.assertionsPassed, true);
      expect(report.qualified, false);
      expect(report.provenanceProblems, contains(contains('model hash')));
    }
  });
  test(
    'desktop payload verification is required even for complete assertions',
    () async {
      final result = await run(FakeEngine());
      final environment = result.events.first['environment'] as Map;
      environment['os'] = 'macos';
      ValidationReport report() =>
          ValidationReport.parse(result.events.map(jsonEncode).join('\n'));
      expect(report().qualified, false);
      environment['runtime_payload_verified'] = true;
      expect(report().qualified, false);
      environment['runtime_bundle_sha256'] = 'a' * 64;
      expect(report().qualified, true);
      environment['runtime_payload_verified'] = false;
      expect(report().qualified, false);
      environment.remove('os');
      environment['platform'] = 'macOS';
      expect(
        report().provenanceProblems,
        contains(contains('Desktop runtime')),
      );
      environment['web'] = true;
      environment['platform'] = 'linux';
      environment['bridge_tag'] = 'v0.1.43';
      expect(report().provenanceProblems, isEmpty);
    },
  );
  test(
    'CPU backend changes during reload or recovery cannot qualify TPS',
    () async {
      for (final threshold in [2, 3, 4]) {
        final result = await run(
          FakeEngine()..switchAfterLoad = threshold,
          selected: focused(['lifecycle']),
        );
        expect(
          result.report.cases.singleWhere(
            (c) =>
                c['case_id'] ==
                (threshold == 2
                    ? 'C09.reload'
                    : threshold == 3
                    ? 'C12.recovery'
                    : 'C09.reload.second'),
          )['status'],
          'FAIL',
        );
        expect(result.report.qualified, false);
      }
    },
  );

  test(
    'native GPU evidence requires matching backend and all load allocations',
    () {
      final manifest = <String, dynamic>{
        'schema_version': 1,
        'profile':
            (jsonDecode(
                    File(
                      'assets/profiles/tiny-gguf-cpu.json',
                    ).readAsStringSync(),
                  )
                  as Map<String, dynamic>)
              ..['backend'] = 'metal',
        'accelerator_evidence_required': true,
      };
      final cases = <Map<String, dynamic>>[
        {
          'case_id': 'C01.load',
          'status': 'PASS',
          'diagnostics': {'backend_name': 'Metal'},
        },
        {
          'case_id': 'C09.reload',
          'status': 'PASS',
          'diagnostics': {'backend_name': 'Metal'},
        },
        {
          'case_id': 'C12.recovery',
          'status': 'PASS',
          'diagnostics': {'backend_name': 'Metal'},
        },
      ];
      const load =
          'load_tensors: offloaded 7/7 layers to GPU\nsched_reserve: MTL0 compute buffer size = 63.62 MiB\n';
      expect(inspectPlacement(manifest, cases, load * 3)['verified'], true);
      expect(inspectPlacement(manifest, cases, load * 2)['verified'], false);
      expect(
        inspectPlacement(
          manifest,
          cases,
          load.replaceAll('7/7', '0/7') * 3,
        )['verified'],
        false,
      );
      expect(
        inspectPlacement(
          manifest,
          cases,
          load.replaceAll('MTL0', 'CPU') * 3,
        )['verified'],
        false,
      );
      expect(
        inspectPlacement(manifest, cases, 'GPU found: Metal')['verified'],
        false,
      );
      cases.first['diagnostics'] = {'backend_name': 'CPU'};
      expect(inspectPlacement(manifest, cases, load * 3)['verified'], false);
    },
  );

  for (final selection in ['focused', 'release']) {
    test('$selection GPU proof includes every selected reload', () {
      final data =
          jsonDecode(
                File('assets/profiles/tiny-gguf-cpu.json').readAsStringSync(),
              )
              as Map<String, dynamic>;
      data['backend'] = 'metal';
      data['selection'] = selection;
      if (selection == 'focused') data['focus_features'] = ['lifecycle'];
      final manifest = <String, dynamic>{
        'schema_version': 2,
        'profile': data,
        // A producer cannot waive the fourth load by omitting it here.
        'case_ids': ['C01.load', 'C09.reload', 'C12.recovery'],
        'accelerator_evidence_required': false,
      };
      final cases = <Map<String, dynamic>>[
        for (final id in [
          'C01.load',
          'C09.reload',
          'C12.recovery',
          'C09.reload.second',
        ])
          {
            'case_id': id,
            'status': 'PASS',
            'diagnostics': {'backend_name': 'Metal'},
          },
      ];
      const load =
          'load_tensors: offloaded 7/7 layers to GPU\nsched_reserve: MTL0 compute buffer size = 63.62 MiB\n';
      final proof = inspectPlacement(manifest, cases, load * 4);
      expect(proof['verified'], true);
      expect(proof['expected_loads'], 4);
      expect(inspectPlacement(manifest, cases, load * 3)['verified'], false);
      expect(
        inspectPlacement(
          manifest,
          cases.take(3).toList(),
          load * 4,
        )['verified'],
        false,
      );
      expect(
        inspectPlacement(manifest, [
          ...cases.take(3),
          cases.first,
        ], load * 4)['verified'],
        false,
      );
      cases.last['diagnostics'] = {'backend_name': 'CPU'};
      expect(inspectPlacement(manifest, cases, load * 4)['verified'], false);
      cases.last['diagnostics'] = {'backend_name': 'Metal'};
      cases.last['status'] = 'FAIL';
      expect(inspectPlacement(manifest, cases, load * 4)['verified'], false);
    });
  }

  test(
    'late timed-out reload cannot start more inference after cleanup',
    () async {
      final paused = Completer<void>();
      final engine = FakeEngine()..pauseReload = paused;
      final result = await run(engine);
      final generated = engine.generated;
      expect(result.report.cleanupPassed, false);
      paused.complete();
      await Future<void>.delayed(Duration.zero);
      expect(engine.generated, generated);
      expect(engine.loads, 2);
    },
  );
  test('explicit CPU case rejects accelerator diagnostics', () async {
    final result = await run(FakeEngine()..backendName = 'Metal');
    expect(result.report.cases.first['status'], 'FAIL');
    expect(result.report.qualified, false);
  });

  test(
    'ignored cancellation cannot pass the cancellation obligation',
    () async {
      final result = await run(FakeEngine()..ignoresCancellation = true);
      expect(
        result.report.cases.singleWhere(
          (c) => c['case_id'] == 'C08.cancel',
        )['status'],
        'NOT_RUN',
      );
      expect(result.report.qualified, false);
    },
  );
  test('journal sink failure still disposes the engine', () async {
    final engine = FakeEngine();
    await expectLater(
      ValidationRunner(
        profile: profile(),
        engine: engine,
        emit: (_) async => throw StateError('disk full'),
      ).run('model', runId: 'test', environment: {}),
      throwsStateError,
    );
    expect(engine.disposed, true);
  });
  test('validated profile cannot be mutated through nested JSON', () {
    final selected = profile();
    expect(() => selected.model['sha256'] = 'changed', throwsUnsupportedError);
  });

  test('rejects floating or unchecked model inputs', () {
    for (final field in ['revision', 'sha256']) {
      final json = profile().toJson();
      (json['model'] as Map)[field] = 'main';
      expect(() => ValidationProfile.fromJson(json), throwsFormatException);
    }
  });
  test('canonical identity is independent of JSON key order', () {
    expect(jsonHash({'b': 2, 'a': 1}), jsonHash({'a': 1, 'b': 2}));
  });
  test('one warmup and three measured samples; lifecycle loads only', () async {
    final engine = FakeEngine();
    final result = await run(engine);
    expect(result.report.qualified, isTrue);
    expect(result.report.samples, hasLength(3));
    expect(engine.loads, 3);
    expect(engine.disposed, isTrue);
  });
  test('semantic failure preserves output and still measures TPS', () async {
    final result = await run(FakeEngine()..wrongArithmetic = true);
    final failure = result.report.cases.singleWhere(
      (c) => c['case_id'] == 'C04.arithmetic',
    );
    expect(failure['status'], 'FAIL');
    expect(failure['content'], '2');
    expect(result.report.samples, hasLength(3));
    expect(result.report.assertionsPassed, isFalse);
  });
  test(
    'timeout cancels and prevents overlapping subsequent inference',
    () async {
      final engine = FakeEngine()..timeout = true;
      final result = await run(engine);
      expect(engine.generated, 1);
      expect(engine.cancelled, isTrue);
      expect(engine.disposed, isTrue);
      expect(result.report.assertionsPassed, isFalse);
      expect(
        result.report.cases.where((c) => c['status'] == 'NOT_RUN'),
        isNotEmpty,
      );
    },
  );
  test('cleanup failure cannot produce a passing report', () async {
    final result = await run(FakeEngine()..cleanupFails = true);
    expect(result.report.qualified, isFalse);
    expect(result.report.toJUnit(), contains('run-integrity'));
  });
  test(
    'GPU preference and reported layers are not accelerator proof',
    () async {
      final result = await run(FakeEngine(), selected: profile(backend: 'gpu'));
      expect(result.report.assertionsPassed, isTrue);
      expect(result.report.qualified, isFalse);
      expect(result.report.toHtml(), contains('unverified'));
    },
  );
  test('release selection keeps unimplemented obligations visible', () async {
    final result = await run(FakeEngine(), selected: profile(release: true));
    expect(result.report.qualified, isFalse);
    expect(
      result.report.cases.singleWhere(
        (c) => c['case_id'] == 'C07.tools',
      )['status'],
      'NOT_RUN',
    );
  });
  test(
    'removing an obligation and its inventory entry cannot qualify',
    () async {
      final result = await run(FakeEngine());
      final events = result.events;
      (events.first['case_ids'] as List).remove('C06.history');
      events.removeWhere((event) => event['case_id'] == 'C06.history');
      for (var index = 1; index < events.length; index++) {
        events[index]['sequence'] = index - 1;
      }
      final report = ValidationReport.parse(events.map(jsonEncode).join('\n'));
      expect(report.qualified, false);
      expect(
        report.problems,
        contains('Case inventory does not match the profile'),
      );
      expect(
        report.cases.singleWhere(
          (c) => c['case_id'] == 'C06.history',
        )['status'],
        'NOT_RUN',
      );
    },
  );
  test('rehashed configuration must match the executable profile', () async {
    final result = await run(FakeEngine());
    final manifest = result.events.first;
    (manifest['effective_config'] as Map)['temperature'] = 0.8;
    manifest['config_hash'] = jsonHash(manifest['effective_config']);
    final report = ValidationReport.parse(
      result.events.map(jsonEncode).join('\n'),
    );
    expect(report.qualified, false);
    expect(
      report.problems,
      contains('Effective configuration does not match the profile'),
    );
  });
  test('report rejects a self-hashed invalid profile', () async {
    final result = await run(FakeEngine());
    final manifest = result.events.first;
    (manifest['profile'] as Map)['runtime'] = 'invalid';
    manifest['profile_hash'] = jsonHash(manifest['profile']);
    final report = ValidationReport.parse(
      result.events.map(jsonEncode).join('\n'),
    );
    expect(report.qualified, false);
    expect(report.problems, contains('Invalid validation profile'));
  });
  test('manifest flag cannot waive accelerator evidence', () async {
    for (final flag in [false, null]) {
      final result = await run(FakeEngine(), selected: profile(backend: 'gpu'));
      result.events.first['accelerator_evidence_required'] = flag;
      final report = ValidationReport.parse(
        result.events.map(jsonEncode).join('\n'),
      );
      expect(report.qualified, false);
      expect(report.acceleratorVerified, false);
      expect(
        report.problems,
        contains('Accelerator evidence requirement does not match the profile'),
      );
    }
  });
  test('record cannot declare its own unsupported exemption', () async {
    final result = await run(FakeEngine());
    result.events.firstWhere((e) => e['type'] == 'case')
      ..['status'] = 'UNSUPPORTED'
      ..['expected_unsupported'] = true;
    final report = ValidationReport.parse(
      result.events.map(jsonEncode).join('\n'),
    );
    expect(report.qualified, false);
    expect(report.assertionsPassed, false);
  });
  test(
    'duplicate, missing, malformed or truncated records fail closed',
    () async {
      final result = await run(FakeEngine());
      final lines = result.events.map(jsonEncode).toList();
      for (final altered in [
        [
          ...lines,
          jsonEncode(result.events.firstWhere((e) => e['type'] == 'case')),
        ],
        lines.take(lines.length - 1).toList(),
        [...lines, '{"type":'],
        lines
            .where((s) => !s.contains('C02.unicode') || s.contains('manifest'))
            .toList(),
      ]) {
        expect(ValidationReport.parse(altered.join('\n')).qualified, isFalse);
      }
    },
  );
  test('reports escape generated markup and retain warmup exclusion', () async {
    final result = await run(FakeEngine());
    result.report.cases.first['content'] = '<script>alert(1)</script>';
    expect(result.report.toHtml(), isNot(contains('<script>alert')));
    expect(result.report.toCsv(), isNot(contains('warmup')));
    expect(result.report.toJUnit(), contains('&lt;script&gt;'));
  });
  test('diagnostics redact bearer tokens and signed URLs', () {
    expect(
      redactDiagnostic('Bearer secret https://x.test/a?token=secret'),
      isNot(contains('secret')),
    );
  });
}
