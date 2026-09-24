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
  var ready = false;
  bool ignoresReadiness = false;
  bool ignoresStop = false;
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
  bool tokenizeTimeout = false;
  Duration? tokenizeDelay;
  String? featureFault;
  bool toolsSeen = false;
  var cleanupFails = false;
  @override
  Future<void> load(String location, ValidationProfile profile) async {
    if (location.endsWith('.missing')) {
      throw LlamaModelException('missing model');
    }
    loads++;
    ready = true;
    if (loads == failOnLoad) throw LlamaModelException('reload failed');
    if (loads == 2) await pauseReload?.future;
  }

  @override
  Future<void> unload() async {
    ready = false;
  }

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
  Future<List<int>> tokenize(String text) async {
    if (tokenizeTimeout) await Completer<void>().future;
    if (tokenizeDelay != null) await Future<void>.delayed(tokenizeDelay!);
    return utf8.encode(text);
  }

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
    List<String>? stopSequences,
    bool? enableThinking,
    List<ToolDefinition>? tools,
    ToolChoice? toolChoice,
  }) async {
    generated++;
    if (featureFault == 'tool_followup_error' &&
        prompt.contains('temperature_celsius from the tool result')) {
      throw StateError('synthetic tool followup failure');
    }
    if (tools != null) toolsSeen = true;
    if (!ready && !ignoresReadiness) throw LlamaContextException('Not loaded');
    final adjusted = streamBatchTokens != null || streamBatchBytes != null;
    requests.add({
      'prompt': prompt,
      'history': history,
      'batch_tokens': streamBatchTokens,
      'batch_bytes': streamBatchBytes,
      'stop_sequences': stopSequences,
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
      'enable_thinking': featureFault == 'thinking_config'
          ? false
          : enableThinking ?? profile.enableThinking,
      'tools': tools?.map((t) => t.toJson()).toList(),
      'tool_choice': featureFault == 'tool_config' ? null : toolChoice?.name,
      'stop_sequences': stopSequences ?? const <String>[],
      'content': prompt.contains('temperature_celsius from the tool result')
          ? featureFault == 'tool_followup'
                ? '18'
                : '17'
          : prompt == profile.fixtureText('unicode_generation', 'prompt')
          ? featureFault == 'unicode'
                ? 'Montréal �'
                : profile.fixtureText('unicode_generation', 'expected')
          : prompt.contains('alpha cedar17 omega')
          ? stopSequences != null && !ignoresStop
                ? 'alpha '
                : 'alpha cedar17 omega'
          : (adjusted && batchingFault == 'content') ||
                (recovering && batchingFault == 'recovery')
          ? 'corrupted'
          : history != null || prompt.contains('The secret code is cedar17.')
          ? wrongHistory
                ? '77777777777777777777777777777777'
                : 'cedar17'
          : prompt.contains('3 + 4')
          ? wrongArithmetic
                ? '2'
                : '3 + 4 = 7'
          : prompt.contains('2 + 2')
          ? wrongArithmetic
                ? '2'
                : '4'
          : 'hello',
      'thinking': featureFault == 'thinking_leak'
          ? 'leaked'
          : enableThinking == true && featureFault != 'thinking_missing'
          ? 'Two plus two is four.'
          : adjusted && batchingFault == 'thinking'
          ? 'changed'
          : '',
      'chunks': adjusted ? 32 : 5,
      'stream_batch_tokens': batchingFault == 'config'
          ? 8
          : streamBatchTokens ?? 8,
      'stream_batch_bytes': streamBatchBytes ?? 512,
      'stream_completed':
          !(adjusted && batchingFault == 'incomplete') &&
          !(recovering && batchingFault == 'recovery'),
      'completion_order_valid': !(adjusted && batchingFault == 'order'),
      'tool_call_deltas':
          featureFault == 'tool_recovery' && toolsSeen && tools == null
          ? [
              {
                'index': featureFault == 'tool_index' ? 1 : 0,
                'function': {'name': 'get_weather'},
              },
            ]
          : tools != null &&
                (toolChoice != ToolChoice.none || featureFault == 'tool_none')
          ? [
              {
                'index': featureFault == 'tool_index' ? 1 : 0,
                'function': {
                  'name': 'get_weather',
                  'arguments': featureFault == 'tool_malformed'
                      ? '{broken'
                      : featureFault == 'tool_arguments'
                      ? '{"city":"Paris"}'
                      : '{"city":"Montréal"}',
                },
              },
            ]
          : adjusted && batchingFault == 'tools'
          ? [
              {'index': 0},
            ]
          : [],
      'finish_reasons': tools != null && toolChoice != ToolChoice.none
          ? [featureFault == 'tool_finish' ? 'length' : 'tool_calls']
          : raw
          ? []
          : [
              (adjusted && batchingFault == 'finish') ||
                      (featureFault == 'tool_text_length' &&
                          toolsSeen &&
                          (tools == null || toolChoice == ToolChoice.none) &&
                          !prompt.contains(
                            'temperature_celsius from the tool result',
                          ))
                  ? 'length'
                  : 'stop',
            ],
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
  test(
    'tool followup errors retain successful call evidence and phase',
    () async {
      final result = await run(
        FakeEngine()..featureFault = 'tool_followup_error',
        selected: profile(release: true),
      );
      final record = result.report.cases.singleWhere(
        (c) => c['case_id'] == 'C07.tools',
      );
      expect(record['status'], 'ERROR');
      expect(record['operation_phase'], 'tools.auto.tool_result_followup');
      expect((record['trials'] as List).single['mode_passed'], true);
      expect((record['trials'] as List).single['tool_choice'], 'auto');
      expect(result.report.qualified, false);
    },
  );

  test('native control cannot execute public release feature cases', () async {
    final data =
        jsonDecode(
              File(
                'assets/profiles/npu-qualcomm-sm8650.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    data['execution_path'] = 'native_c_api';
    data['selection'] = 'release';
    data['enable_thinking'] = true;
    final result = await run(
      FakeEngine(),
      selected: ValidationProfile.fromJson(data),
    );
    for (final id in ['C02.generate', 'C05.thinking', 'C07.tools']) {
      final record = result.report.cases.singleWhere((c) => c['case_id'] == id);
      expect(record['status'], 'NOT_RUN');
      expect(record['reason'], 'Requires public chat feature controls');
    }
  });

  for (final entry in {
    'unicode': 'C02.generate',
    'thinking_config': 'C05.thinking',
    'thinking_leak': 'C05.thinking',
    'thinking_missing': 'C05.thinking',
    'tool_config': 'C07.tools',
    'tool_arguments': 'C07.tools',
    'tool_finish': 'C07.tools',
    'tool_followup': 'C07.tools',
    'tool_recovery': 'C07.tools',
    'tool_none': 'C07.tools',
    'tool_index': 'C07.tools',
    'tool_malformed': 'C07.tools',
  }.entries) {
    test('release feature rejects ${entry.key}', () async {
      final result = await run(
        FakeEngine()..featureFault = entry.key,
        selected: profile(release: true),
      );
      expect(
        result.report.cases.singleWhere(
          (c) => c['case_id'] == entry.value,
        )['status'],
        'FAIL',
      );
      expect(result.report.qualified, false);
    });
  }

  test('release tools accept a text answer that reaches its budget', () async {
    final result = await run(
      FakeEngine()..featureFault = 'tool_text_length',
      selected: profile(release: true),
    );
    final tools = result.report.cases.singleWhere(
      (c) => c['case_id'] == 'C07.tools',
    );
    final trials = (tools['trials'] as List).cast<Map>();

    expect(
      trials.singleWhere((t) => t['tool_choice'] == 'none')['finish_reasons'],
      ['length'],
    );
    expect((tools['recovery'] as Map)['finish_reasons'], ['length']);
    expect(tools['status'], 'PASS');
  });

  test('catalog three preserves unimplemented feature obligations', () async {
    final selected = profile(release: true);
    final result = await run(FakeEngine(), selected: selected);
    final events = result.events;
    events.first['catalog'] = selected.catalogForVersion(3);
    events.first['catalog_hash'] = jsonHash(events.first['catalog']);
    for (final record in events.where((e) => e['type'] == 'case')) {
      final id = record['case_id'] as String;
      record['fixture_hash'] = jsonHash(
        selected.caseFixtures(id, catalogVersion: 3),
      );
      if (['C05.thinking', 'C07.tools', 'C02.generate'].contains(id)) {
        record['case_version'] = 1;
        record['status'] = 'NOT_RUN';
      }
    }
    final historical = ValidationReport.parse(
      events.map(jsonEncode).join('\n'),
    );
    expect(historical.problems, isEmpty);
    expect(historical.qualified, false);
    events.firstWhere(
      (e) => e['type'] == 'case' && e['case_id'] == 'C07.tools',
    )['status'] = 'PASS';
    expect(
      ValidationReport.parse(events.map(jsonEncode).join('\n')).problems,
      contains(
        'Unimplemented catalog case cannot claim an executed result: C07.tools',
      ),
    );
  });

  test(
    'first-use timeout preserves deferred initialization attribution',
    () async {
      final result = await run(FakeEngine()..tokenizeTimeout = true);
      final load = result.report.cases.first;
      expect(load['load_scope'], 'public_load_and_readiness');
      expect(load['native_initialization_proven'], false);
      final failed = result.report.cases.singleWhere(
        (c) => c['case_id'] == 'C02.unicode',
      );
      expect(failed['status'], 'ERROR');
      expect(failed['reason'], 'case_timeout');
      expect(
        failed['operation_phase'],
        'tokenize_including_possible_deferred_initialization',
      );
      expect(failed['timeout_ms'], 30);
      expect(failed['elapsed_ms'], greaterThanOrEqualTo(30));
      expect(
        result.report.cases.skip(2).every((c) => c['status'] == 'NOT_RUN'),
        true,
      );
      expect(result.report.qualified, false);

      final success = await run(FakeEngine());
      final unicode = success.report.cases.singleWhere(
        (c) => c['case_id'] == 'C02.unicode',
      );
      expect(unicode['tokenize_call_ms'], isNonNegative);
      expect(unicode['detokenize_call_ms'], isNonNegative);
      expect(
        unicode['tokenize_timing_scope'],
        'public_call_including_possible_deferred_initialization',
      );
    },
  );

  test('report separates missing GPU proof from functional failures', () async {
    final passing = await run(
      FakeEngine()..backendName = 'LiteRT-LM GPU',
      selected: profile(backend: 'gpu'),
    );
    expect(passing.report.assertionsPassed, true);
    expect(passing.report.qualified, false);
    expect(passing.report.qualificationGaps, ['accelerator_evidence_missing']);
    expect((passing.report.toJson()['summary'] as Map)['qualification_gaps'], [
      'accelerator_evidence_missing',
    ]);
    expect(
      passing.report.toHtml(),
      contains('does not by itself establish incompatibility'),
    );

    final failed = await run(FakeEngine()..wrongArithmetic = true);
    expect(failed.report.qualificationGaps, contains('assertion_failure'));
    expect(
      failed.report.qualificationGaps,
      isNot(contains('accelerator_evidence_missing')),
    );

    final incomplete = await run(
      FakeEngine(),
      selected: profile(release: true),
    );
    expect(incomplete.report.qualificationGaps, isEmpty);
    final broken = await run(FakeEngine()..failOnLoad = 1);
    expect(
      broken.report.qualificationGaps,
      containsAll(['execution_error', 'cases_not_run']),
    );
    expect((await run(FakeEngine())).report.qualificationGaps, isEmpty);
  });

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
      expect(result.report.qualified, true);
      expect(
        result.report.cases
            .where((c) => c['status'] == 'NOT_RUN')
            .map((c) => c['case_id']),
        isEmpty,
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
      final stop = events.singleWhere(
        (e) => e['type'] == 'case' && e['case_id'] == 'C10.stop',
      );
      stop['case_version'] = 1;
      stop['fixture_hash'] = jsonHash(
        selected.caseFixtures('C10.stop', catalogVersion: 1),
      );
      stop['status'] = 'NOT_RUN';
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

  test(
    'stop marker requires the exact prefix, forwarded control and recovery',
    () async {
      for (final ignored in [false, true]) {
        final engine = FakeEngine()..ignoresStop = ignored;
        final result = await run(engine, selected: focused(['streaming']));
        final record = result.report.cases.singleWhere(
          (c) => c['case_id'] == 'C10.stop',
        );
        expect(record['status'], ignored ? 'FAIL' : 'PASS');
        expect(record['expected_prefix'], 'alpha ');
        expect(
          engine.requests.any(
            (r) =>
                r['stop_sequences'] is List &&
                (r['stop_sequences'] as List).contains('cedar17'),
          ),
          true,
        );
        expect(record['recovery']['content'], isNotEmpty);
      }
    },
  );
  test(
    'readiness guard cannot pass when unloaded generation is accepted',
    () async {
      for (final ignored in [false, true]) {
        final result = await run(
          FakeEngine()..ignoresReadiness = ignored,
          selected: focused(['guards']),
        );
        final record = result.report.cases.singleWhere(
          (c) => c['case_id'] == 'C12.guards',
        );
        expect(record['status'], ignored ? 'FAIL' : 'PASS');
        expect(record['recovery']['content'], isNotEmpty);
        expect(result.report.cleanupPassed, true);
      }
    },
  );
  test(
    'catalog two cannot claim new stop and readiness guard execution',
    () async {
      final selected = profile(release: true);
      final result = await run(FakeEngine(), selected: selected);
      final events = result.events;
      events.first['catalog'] = selected.catalogForVersion(2);
      events.first['catalog_hash'] = jsonHash(events.first['catalog']);
      expect(
        (events.first['catalog']['fixtures'] as Map).containsKey('stop'),
        false,
      );
      final report = ValidationReport.parse(events.map(jsonEncode).join('\n'));
      expect(report.qualified, false);
      expect(
        report.problems,
        contains(
          'Unimplemented catalog case cannot claim an executed result: C10.stop',
        ),
      );
      expect(
        report.problems,
        contains(
          'Unimplemented catalog case cannot claim an executed result: C12.guards',
        ),
      );
    },
  );

  test('batching feature cannot downgrade to old catalog', () async {
    final selected = focused(['batching']);
    expect(() => selected.catalogForVersion(1), throwsFormatException);
  });

  test(
    'catalog three requires guard reload placement without changing old logs',
    () async {
      final data =
          jsonDecode(
                File('assets/profiles/chat-gguf-metal.json').readAsStringSync(),
              )
              as Map<String, dynamic>;
      data['selection'] = 'focused';
      data['focus_features'] = ['guards'];
      final selected = ValidationProfile.fromJson(data);
      final engine = FakeEngine()..backendName = 'Metal';
      final result = await run(engine, selected: selected);
      final cases = result.report.cases;
      const load =
          'load_tensors: offloaded 7/7 layers to GPU\nMTL0 compute buffer size = 64.0 MiB\n';
      final manifest = result.events.first;
      expect(engine.loads, 4);
      expect(inspectPlacement(manifest, cases, load * 4)['verified'], true);
      expect(inspectPlacement(manifest, cases, load * 3)['verified'], false);
      expect(
        inspectPlacement(
          manifest,
          cases.where((c) => c['case_id'] != 'C12.guards').toList(),
          load * 4,
        )['verified'],
        false,
      );
      final old = {...manifest, 'catalog': selected.catalogForVersion(2)};
      expect(
        inspectPlacement(
          old,
          cases.where((c) => c['case_id'] != 'C12.guards').toList(),
          load * 3,
        )['verified'],
        true,
      );
    },
  );

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
      environment['bridge_tag'] = 'fixture-bridge';
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

  test('software Vulkan cannot qualify despite positive offload records', () {
    final profile =
        jsonDecode(
              File('assets/profiles/tiny-gguf-cpu.json').readAsStringSync(),
            )
            as Map<String, dynamic>;
    profile['backend'] = 'vulkan';
    final manifest = <String, dynamic>{'schema_version': 1, 'profile': profile};
    final cases = [
      for (final id in ['C01.load', 'C09.reload', 'C12.recovery'])
        <String, dynamic>{
          'case_id': id,
          'status': 'PASS',
          'diagnostics': {'backend_name': 'Vulkan0'},
        },
    ];
    final allocations =
        'load_tensors: offloaded 7/7 layers to GPU\n'
            'Vulkan0 compute buffer size = 64.0 MiB\n' *
        3;
    final hardware = 'ggml_vulkan: 0 = NVIDIA L4\n$allocations';
    expect(inspectPlacement(manifest, cases, hardware)['verified'], true);
    String selected(String name, {int index = 0, int free = 21831}) =>
        'llama_prepare_model_devices: using device Vulkan$index '
        '($name) (0000:00:03.0) - $free MiB free\n';
    final selectedHardware = selected('NVIDIA L4');
    for (final valid in [
      '$selectedHardware$allocations',
      '${selected('NVIDIA L4', free: 21760)}$selectedHardware$allocations',
      '$selectedHardware$hardware',
      'ggml_vulkan: 0 = NVIDIA L4 (NVIDIA) | uma: 0\n'
          '$selectedHardware$allocations',
      '${selected('Intel(R) Arc(TM) A770')}$allocations',
    ]) {
      expect(inspectPlacement(manifest, cases, valid)['verified'], true);
    }
    for (final invalid in [
      allocations,
      'ggml_vulkan: 1 = NVIDIA L4\n$allocations',
      'ggml_vulkan: 0 = unknown device\n$allocations',
      'ggml_vulkan: 0 = Intel CPU\n$allocations',
      '$hardware\nggml_vulkan: 0 = AMD Radeon',
      '${selected('AMD Radeon')}$hardware',
      '${selected('NVIDIA L4', index: 1)}$allocations',
      '${selected('Intel CPU')}$allocations',
      '${selected('NVIDIA virtual device')}$allocations',
      '${selected('NVIDIA L4 | virtual device')}$allocations',
      'ggml_vulkan: 0 = NVIDIA L4 | virtual device\n$allocations',
      'ggml_vulkan: 0 = NVIDIA L4 | CPU\n$allocations',
      'ggml_vulkan: 0 = NVIDIA L4 | software\n$allocations',
      '${selected('unknown device')}$allocations',
      '${selected('NVIDIA (L4')}$allocations',
      '${selectedHardware.replaceFirst(' MiB free', '')}$allocations',
      'unrecognized: $selectedHardware$allocations',
      '$selectedHardware${allocations.replaceFirst('7/7', '0/7')}',
      '$selectedHardware${allocations.replaceFirst('64.0', '0.0')}',
      '$selectedHardware$allocations$allocations',
    ]) {
      expect(inspectPlacement(manifest, cases, invalid)['verified'], false);
    }
    for (final device in [
      'llvmpipe (LLVM 20.1.2, 256 bits)',
      'Lavapipe',
      'SwiftShader Device',
      'Microsoft Basic Render Driver',
      'Software Rasterizer',
    ]) {
      final result = inspectPlacement(
        manifest,
        cases,
        'ggml_vulkan: 0 = $device\n$allocations',
      );
      expect(result['verified'], false, reason: device);
      expect(result['reason'], contains('software Vulkan'));
      expect(
        inspectPlacement(
          manifest,
          cases,
          '${selected(device)}$allocations',
        )['verified'],
        false,
      );
      // Mixed inventory cannot identify which physical device executed work.
      expect(
        inspectPlacement(manifest, cases, '$hardware\n$device')['verified'],
        false,
      );
    }
    profile['backend'] = 'cpu';
    expect(inspectPlacement(manifest, cases, 'llvmpipe')['required'], false);
  });

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
  test('Qwen3 LiteRT arithmetic oracle accepts only the correct sum', () {
    for (final backend in ['cpu', 'gpu']) {
      final litert = ValidationProfile.fromJson(
        jsonDecode(
              File(
                'assets/profiles/chat-litert-$backend.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>,
      );
      expect(
        litert.fixtureText('arithmetic', 'prompt'),
        'What is 3 + 4? Reply with only the number.',
      );
      final oracle = RegExp(litert.fixtureText('arithmetic', 'regex'));
      for (final output in ['7', '7.', '3 + 4 = 7']) {
        expect(oracle.hasMatch(output), isTrue, reason: output);
      }
      for (final output in ['2', '4', '17', '3 + 4 = 8', '7 + 3 = 10']) {
        expect(oracle.hasMatch(output), isFalse, reason: output);
      }
    }
  });
  test('engine create deadline override rejects invalid contracts', () {
    for (final patch in <Map<String, dynamic>>[
      {'engine_create_case_timeout_ms': 120000},
      {'backend': 'gpu', 'engine_create_case_timeout_ms': '120000'},
      {'backend': 'gpu', 'engine_create_case_timeout_ms': 59999},
      {'backend': 'gpu', 'engine_create_case_timeout_ms': 180001},
      {'backend': 'npu', 'engine_create_case_timeout_ms': 120000},
    ]) {
      expect(
        () => ValidationProfile.fromJson(profile().toJson()..addAll(patch)),
        throwsFormatException,
      );
    }
    final gguf =
        jsonDecode(
                File('assets/profiles/chat-gguf-metal.json').readAsStringSync(),
              )
              as Map<String, dynamic>
          ..['engine_create_case_timeout_ms'] = 120000;
    expect(() => ValidationProfile.fromJson(gguf), throwsFormatException);
  });

  test(
    'only the measured LiteRT GPU profile extends engine create deadlines',
    () {
      for (final file in Directory(
        'assets/profiles',
      ).listSync().whereType<File>()) {
        final selected = ValidationProfile.fromJson(
          jsonDecode(file.readAsStringSync()) as Map<String, dynamic>,
        );
        expect(
          selected.engineCreateCaseTimeout,
          selected.id == 'qwen35-litert-gpu'
              ? const Duration(seconds: 120)
              : null,
          reason: selected.id,
        );
        final runner = ValidationRunner(
          profile: selected,
          engine: FakeEngine(),
          emit: (_) async {},
        );
        for (final id in selected.caseIds) {
          expect(
            runner.caseDeadline(id),
            selected.id == 'qwen35-litert-gpu' &&
                    ValidationRunner.engineReloadCaseIds.contains(id)
                ? const Duration(seconds: 120)
                : const Duration(seconds: 60),
            reason: '${selected.id} $id',
          );
        }
        expect(
          runner.caseDeadline('C02.unicode', firstUse: true),
          selected.id == 'qwen35-litert-gpu'
              ? const Duration(seconds: 120)
              : const Duration(seconds: 60),
          reason: selected.id,
        );
      }
    },
  );

  test('engine create deadline override leaves other cases bounded', () async {
    Future<Map<String, dynamic>> reload(ValidationProfile selected) async {
      final paused = Completer<void>();
      final engine = FakeEngine()..pauseReload = paused;
      Timer(const Duration(milliseconds: 120), paused.complete);
      final result = await run(engine, selected: selected);
      return result.report.cases.singleWhere(
        (c) => c['case_id'] == 'C09.reload',
      );
    }

    final base = await reload(profile(backend: 'gpu'));
    expect(base['reason'], 'case_timeout');
    expect(base['timeout_ms'], 30);

    final extended = await reload(
      ValidationProfile.fromJson(
        profile(backend: 'gpu').toJson()
          ..['engine_create_case_timeout_ms'] = 60000,
      ),
    );
    expect(extended['reason'], isNot('case_timeout'));
    expect(extended['status'], isNot('ERROR'));

    Future<Map<String, dynamic>> firstUse(ValidationProfile selected) async {
      final result = await run(
        FakeEngine()..tokenizeDelay = const Duration(milliseconds: 120),
        selected: selected,
      );
      return result.report.cases.singleWhere(
        (c) => c['case_id'] == 'C02.unicode',
      );
    }

    expect((await firstUse(profile(backend: 'gpu')))['reason'], 'case_timeout');
    expect(
      (await firstUse(
        ValidationProfile.fromJson(
          profile(backend: 'gpu').toJson()
            ..['engine_create_case_timeout_ms'] = 60000,
        ),
      ))['status'],
      'PASS',
    );

    final hung = await run(
      FakeEngine()..timeout = true,
      selected: ValidationProfile.fromJson(
        profile(backend: 'gpu').toJson()
          ..['engine_create_case_timeout_ms'] = 60000,
      ),
    );
    final raw = hung.report.cases.singleWhere((c) => c['case_id'] == 'C03.raw');
    expect(raw['reason'], 'case_timeout');
    expect(raw['timeout_ms'], 30);
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
  test('release selection executes every implemented obligation', () async {
    final result = await run(FakeEngine(), selected: profile(release: true));
    expect(result.report.qualified, isTrue);
    expect(
      result.report.cases.singleWhere(
        (c) => c['case_id'] == 'C07.tools',
      )['status'],
      'PASS',
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
