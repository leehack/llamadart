import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:llamadart/backend.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_validation/llamadart_validation.dart';
import 'package:llamadart_validation/src/structured_output_evidence.dart';
import 'package:test/test.dart';

String _prompt(String section, [String field = 'prompt']) =>
    structuredFixture(section)[field] as String;

const _conformingMember =
    '{"name":"Ada","age":34,"rating":4.5,"active":true,"nickname":null,'
    '"tier":"gold","address":{"city":"Paris","zip":"75001"},'
    '"loans":[{"title":"Dune","days":14}],"fines":[],"notes":"",'
    '"preferences":{}}';

/// Public-engine backend that emits scripted replies. With [honorGrammar] it
/// returns grammar-conforming replies whenever a grammar reaches it, standing
/// in for constrained decoding; without it every request gets the reply an
/// unconstrained model would give.
class _ScriptedBackend
    implements
        LlamaBackend,
        BackendGrammarConstraintsSupport,
        BackendLazyGrammarSupport {
  _ScriptedBackend({
    this.honorGrammar = true,
    this.grammarSupport = true,
    this.controlConforms = false,
  });

  final bool honorGrammar;
  final bool grammarSupport;
  final bool controlConforms;
  final requests = <GenerationParams>[];

  @override
  bool get supportsUrlLoading => false;
  @override
  bool get supportsGrammarConstraints => grammarSupport;
  @override
  bool get supportsLazyGrammar => grammarSupport;
  @override
  Future<void> setLogLevel(LlamaLogLevel level) async {}
  @override
  Future<int> modelLoad(String path, ModelParams params) async {
    if (!File(path).existsSync()) {
      throw LlamaModelException('Missing model', path);
    }
    return 1;
  }

  @override
  Future<int> contextCreate(int modelHandle, ModelParams params) async => 1;
  @override
  Future<void> contextFree(int handle) async {}
  @override
  Future<void> modelFree(int handle) async {}
  @override
  Future<void> dispose() async {}
  @override
  void cancelGeneration() {}
  @override
  Future<String> getBackendName() async => 'CPU';
  @override
  Future<int> getContextSize(int handle) async => 2048;
  @override
  Future<Map<String, String>> modelMetadata(int handle) async => {
    'tokenizer.chat_template':
        '{# <tool_call> #}'
        '{{ messages[0]["content"] }}',
    'llm.context_length': '2048',
  };

  String _reply(String prompt, GenerationParams params) {
    final constrained = honorGrammar && params.grammar != null;
    if (prompt.contains(_prompt('json_object'))) {
      return constrained || controlConforms
          ? '{"description":"A red apple"}'
          : 'A red apple is crisp and sweet.';
    }
    if (prompt.contains(_prompt('json_schema'))) {
      return constrained ? _conformingMember : 'Ada borrows two books.';
    }
    if (prompt.contains(_prompt('grammar'))) {
      return constrained ? 'cedar-123' : 'The sea is calm today.';
    }
    if (prompt.contains(_prompt('lazy_grammar'))) {
      return constrained && params.grammarLazy
          ? 'It is sunny today.\nANSWER: alpha'
          : 'It is sunny today.\nANSWER: blue';
    }
    if (prompt.contains(_prompt('reject', 'mismatch_prompt'))) {
      return constrained ? '{"city":"Paris"}' : 'Paris is a city.';
    }
    if (prompt.contains(_prompt('reject', 'malformed_prompt'))) {
      return 'The sea is wide.';
    }
    if (prompt.contains(_prompt('tools'))) {
      final arguments = constrained
          ? '{"city":"Montréal","unit":"celsius","days":7}'
          : '{"city":"Montréal","unit":"fahrenheit","days":30}';
      return '<tool_call>\n{"name":"get_forecast","arguments":$arguments}'
          '\n</tool_call>';
    }
    return 'Hello there.';
  }

  @override
  Stream<List<int>> generate(
    int handle,
    String prompt,
    GenerationParams params, {
    List<LlamaContentPart>? parts,
  }) async* {
    requests.add(params);
    final bytes = utf8.encode(_reply(prompt, params));
    for (var i = 0; i < bytes.length; i += 5) {
      yield bytes.sublist(i, min(i + 5, bytes.length));
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ValidationProfile _profile(String backend) => ValidationProfile.fromJson(
  jsonDecode(
        File(
          'assets/profiles/structured-gguf-$backend.json',
        ).readAsStringSync(),
      )
      as Map<String, dynamic>,
);

const _structuredIds = [
  'S01.capabilities',
  'S02.json_object',
  'S03.json_schema',
  'S04.grammar',
  'S05.grammar.lazy',
  'S06.reject',
  'S07.stream',
  'S08.tools.schema',
];

Future<({ValidationReport report, List<Map<String, dynamic>> events})> _run(
  _ScriptedBackend backend,
) async {
  final directory = Directory.systemTemp.createTempSync('structured-pack-');
  addTearDown(() => directory.deleteSync(recursive: true));
  final model = File('${directory.path}/fixture.gguf')
    ..writeAsBytesSync([0, 0, 0, 0]);
  final selected = _profile('cpu');
  final events = <Map<String, dynamic>>[];
  await ValidationRunner(
    profile: selected,
    engine: PublicValidationEngine(engineFactory: () => LlamaEngine(backend)),
    emit: (event) async => events.add(event),
    caseTimeout: const Duration(seconds: 10),
  ).run(
    model.path,
    runId: 'structured-test',
    preparation: {
      'verified': true,
      'sha256': selected.modelHash,
      'bytes': selected.model['bytes'],
    },
    environment: {
      'source_commit': List.filled(40, 'a').join(),
      'source_dirty': false,
      'hook_sha256': List.filled(64, 'b').join(),
      'native_tag': 'v0.7.0',
    },
  );
  return (
    report: ValidationReport.parse(events.map(jsonEncode).join('\n')),
    events: events,
  );
}

Map<String, dynamic> _record(List<Map<String, dynamic>> events, String id) =>
    events.singleWhere((e) => e['type'] == 'case' && e['case_id'] == id);

void main() {
  test('structured profiles select every structured case from catalog 8', () {
    for (final backend in ['cpu', 'metal']) {
      final selected = _profile(backend);
      expect(selected.caseIds, containsAll(_structuredIds));
      expect(
        () => selected.catalogForVersion(7),
        throwsA(isA<FormatException>()),
      );
    }
  });

  test('runtimes without a constraint keep only what they can run', () {
    ValidationProfile focused(String id) => ValidationProfile.fromJson(
      (jsonDecode(File('assets/profiles/$id.json').readAsStringSync())
            as Map<String, dynamic>)
        ..['selection'] = 'focused'
        ..['focus_features'] = ['structured_output'],
    );
    List<String> structured(ValidationProfile profile) =>
        profile.caseIds.where((id) => id.startsWith('S')).toList();
    Map<String, Object?> omissions(ValidationProfile profile) => {
      for (final entry in (profile.catalog['cases'] as List).cast<Map>())
        if ('${entry['id']}'.startsWith('S') && entry['selected'] == false)
          '${entry['id']}': entry['omission_reason'],
    };
    final litert = focused('chat-litert-cpu');
    expect(structured(litert), ['S01.capabilities']);
    expect(omissions(litert).values.toSet(), {'litert_grammar_unsupported'});
    final webgpu = focused('chat-gguf-webgpu');
    expect(structured(webgpu), [
      for (final id in _structuredIds)
        if (id != 'S05.grammar.lazy') id,
    ]);
    expect(omissions(webgpu), {
      'S05.grammar.lazy': 'webgpu_lazy_grammar_unsupported',
    });
  });

  test(
    'constrained public requests pass and the journal rechecks them',
    () async {
      final backend = _ScriptedBackend();
      final result = await _run(backend);
      for (final id in _structuredIds) {
        expect(
          _record(result.events, id)['status'],
          'PASS',
          reason: jsonEncode(_record(result.events, id)),
        );
      }
      expect(
        result.report.problems.where((p) => p.contains('structured-output')),
        isEmpty,
      );
      final stream = _record(result.events, 'S07.stream');
      expect(
        ((stream['output'] as Map)['content_deltas'] as List).length,
        greaterThan(2),
      );
      expect(stream['partial_rejections'], isNotEmpty);
      final lazy = backend.requests.where((r) => r.grammarLazy).single;
      expect(lazy.grammarTriggers.single.value, 'ANSWER:');
      expect(lazy.grammarTriggers.single.triggerType, GrammarTriggerType.word);
      final reject = _record(result.events, 'S06.reject');
      expect(
        (reject['unsupported_schema'] as Map)['error_type'],
        ['LlamaUnsupportedException'].single,
      );
      expect((reject['unsupported_response_format'] as Map)['chunks'], 0);
    },
  );

  test(
    'a backend that ignores grammars fails every constrained case',
    () async {
      final result = await _run(_ScriptedBackend(honorGrammar: false));
      expect(_record(result.events, 'S01.capabilities')['status'], 'PASS');
      for (final id in _structuredIds.skip(1)) {
        expect(_record(result.events, id)['status'], 'FAIL', reason: id);
      }
      expect(result.report.qualified, isFalse);
    },
  );

  test('a fixture whose control already conforms stays NOT_RUN', () async {
    final result = await _run(_ScriptedBackend(controlConforms: true));
    final record = _record(result.events, 'S02.json_object');
    expect(record['status'], 'NOT_RUN');
    expect(record['reason'], contains('unconstrained control'));
  });

  test(
    'missing grammar support fails capabilities and skips the rest',
    () async {
      final result = await _run(_ScriptedBackend(grammarSupport: false));
      expect(_record(result.events, 'S01.capabilities')['status'], 'FAIL');
      for (final id in _structuredIds.skip(1)) {
        final record = _record(result.events, id);
        expect(record['status'], 'NOT_RUN', reason: id);
        expect(record['reason'], contains('reports no'));
      }
    },
  );

  test('a forged PASS without conforming evidence fails import', () async {
    final result = await _run(_ScriptedBackend());
    for (final (id, forge) in <(String, void Function(Map<String, dynamic>))>[
      (
        'S03.json_schema',
        (r) => (r['constrained'] as Map)['content'] = '{"name":"Ada"}',
      ),
      ('S03.json_schema', (r) => (r['helper'] as Map)['value'] = {'name': 1}),
      ('S04.grammar', (r) => (r['constrained'] as Map)['content'] = 'cedar-1'),
      (
        'S05.grammar.lazy',
        (r) => (r['constrained'] as Map)['content'] = 'ANSWER: alpha',
      ),
      (
        'S06.reject',
        (r) => (r['malformed'] as Map)['parse_error'] = {
          'error_type': 'FormatException',
        },
      ),
      ('S07.stream', (r) => r['partial_rejections'] = <Object>[]),
      (
        'S08.tools.schema',
        (r) => (r['output'] as Map)['tool_call_deltas'] = [
          {
            'index': 0,
            'function': {
              'name': 'get_forecast',
              'arguments': '{"city":"Montréal","unit":"fahrenheit","days":30}',
            },
          },
        ],
      ),
    ]) {
      final events = (jsonDecode(jsonEncode(result.events)) as List)
          .cast<Map<String, dynamic>>();
      forge(_record(events, id));
      expect(
        ValidationReport.parse(events.map(jsonEncode).join('\n')).problems,
        contains('Invalid structured-output case evidence: $id'),
      );
    }
  });

  group('independent fixture schema check', () {
    final schema = structuredFixture('json_schema')['schema'] as Map;
    Map<String, dynamic> member() =>
        jsonDecode(_conformingMember) as Map<String, dynamic>;

    test('accepts the optional property and rejects each violation', () {
      expect(conformsToFixtureSchema(member(), schema), isTrue);
      expect(
        conformsToFixtureSchema({...member(), 'email': 'a@b.c'}, schema),
        isTrue,
      );
      for (final (field, value) in <(String, Object?)>[
        ('tier', 'platinum'),
        ('age', 17),
        ('age', 34.5),
        ('nickname', 'Ace'),
        ('fines', [1]),
        ('notes', 'late'),
        ('preferences', {'quiet': true}),
        ('loans', <Object>[]),
        ('address', {'city': 'Paris', 'zip': '7500'}),
        ('address', {'city': 'Paris'}),
        ('extra', 1),
      ]) {
        expect(
          conformsToFixtureSchema({...member(), field: value}, schema),
          isFalse,
          reason: '$field=$value',
        );
      }
      expect(
        conformsToFixtureSchema(member()..remove('rating'), schema),
        isFalse,
      );
    });

    test('fails closed on keywords it does not check', () {
      expect(
        conformsToFixtureSchema(1, {'type': 'integer', 'multipleOf': 2}),
        isFalse,
      );
    });
  });
}
