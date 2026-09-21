import 'dart:convert';
import 'dart:io';

import 'package:llamadart_validation/llamadart_validation.dart';
import 'package:test/test.dart';

const _enforcedKeywords = {
  r'$schema',
  'title',
  'type',
  'const',
  'enum',
  'pattern',
  'minimum',
  'maximum',
  'required',
  'properties',
  'additionalProperties',
  'minProperties',
  'items',
  'minItems',
  'uniqueItems',
  'allOf',
  'if',
  'then',
  'else',
  'not',
};

Map<String, dynamic> _readJson(String path) =>
    jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

Set<String> _keywords(Map<String, dynamic> schema) {
  final found = <String>{...schema.keys};
  for (final entry in schema.entries) {
    final value = entry.value;
    if (entry.key == 'properties') {
      for (final child in (value as Map).values) {
        found.addAll(_keywords((child as Map).cast<String, dynamic>()));
      }
    } else if (entry.key == 'allOf') {
      for (final child in value as List) {
        found.addAll(_keywords((child as Map).cast<String, dynamic>()));
      }
    } else if (value is Map) {
      found.addAll(_keywords(value.cast<String, dynamic>()));
    }
  }
  return found;
}

bool _hasType(Object? value, String type) => switch (type) {
  'object' => value is Map,
  'array' => value is List,
  'string' => value is String,
  'integer' => value is int,
  'number' => value is num,
  'boolean' => value is bool,
  'null' => value == null,
  _ => throw UnsupportedError('type $type'),
};

bool _same(Object? a, Object? b) => canonicalJson(a) == canonicalJson(b);

List<String> _violations(
  Object? value,
  Map<String, dynamic> schema, [
  String path = '',
]) {
  final out = <String>[];
  final type = schema['type'];
  if (type != null) {
    final types = type is List ? type.cast<String>() : [type as String];
    if (!types.any((candidate) => _hasType(value, candidate))) {
      out.add('$path: expected type $types');
    }
  }
  if (schema.containsKey('const') && !_same(value, schema['const'])) {
    out.add('$path: expected const ${schema['const']}');
  }
  if (schema['enum'] case final List options) {
    if (!options.any((option) => _same(option, value))) {
      out.add('$path: expected one of $options');
    }
  }
  if (value is String) {
    if (schema['pattern'] case final String pattern) {
      if (!RegExp(pattern).hasMatch(value)) {
        out.add('$path: does not match $pattern');
      }
    }
  }
  if (value is num) {
    if (schema['minimum'] case final num minimum when value < minimum) {
      out.add('$path: below $minimum');
    }
    if (schema['maximum'] case final num maximum when value > maximum) {
      out.add('$path: above $maximum');
    }
  }
  if (value is Map) {
    for (final key in schema['required'] as List? ?? const []) {
      if (!value.containsKey(key)) out.add('$path: missing $key');
    }
    if (schema['minProperties'] case final int minimum) {
      if (value.length < minimum) out.add('$path: fewer than $minimum keys');
    }
    final properties = schema['properties'] as Map? ?? const {};
    final additional = schema['additionalProperties'];
    for (final entry in value.entries) {
      final child = '$path/${entry.key}';
      if (properties[entry.key] case final Map declared) {
        out.addAll(_violations(entry.value, declared.cast(), child));
      } else if (additional is Map) {
        out.addAll(_violations(entry.value, additional.cast(), child));
      } else if (additional == false) {
        out.add('$child: undeclared property');
      }
    }
  }
  if (value is List) {
    if (schema['minItems'] case final int minimum when value.length < minimum) {
      out.add('$path: fewer than $minimum items');
    }
    if (schema['uniqueItems'] == true &&
        value.map(canonicalJson).toSet().length != value.length) {
      out.add('$path: duplicate items');
    }
    if (schema['items'] case final Map items) {
      for (var i = 0; i < value.length; i++) {
        out.addAll(_violations(value[i], items.cast(), '$path/$i'));
      }
    }
  }
  for (final sub in schema['allOf'] as List? ?? const []) {
    out.addAll(_violations(value, (sub as Map).cast(), path));
  }
  if (schema['if'] case final Map condition) {
    final branch = _violations(value, condition.cast(), path).isEmpty
        ? schema['then']
        : schema['else'];
    if (branch is Map) out.addAll(_violations(value, branch.cast(), path));
  }
  if (schema['not'] case final Map forbidden) {
    if (_violations(value, forbidden.cast(), path).isEmpty) {
      out.add('$path: matches a forbidden schema');
    }
  }
  return out;
}

Set<String> _literalKeys(String source, List<String> receivers) => {
  for (final match in RegExp(
    "(?<![.\\w])(${receivers.join('|')})\\['([a-z0-9_]+)'\\]",
  ).allMatches(source))
    match.group(2)!,
};

void main() {
  final schema = _readJson('schemas/profile.schema.json');
  final properties = schema['properties'] as Map<String, dynamic>;
  final profiles = {
    for (final file in Directory(
      'assets/profiles',
    ).listSync().whereType<File>())
      file.uri.pathSegments.last: _readJson(file.path),
  };

  Map<String, dynamic> patched(String name, Map<String, dynamic> patch) =>
      jsonDecode(jsonEncode(profiles[name]!)) as Map<String, dynamic>
        ..addAll(patch);

  test('schema uses only keywords the structural check enforces', () {
    expect(_keywords(schema).difference(_enforcedKeywords), isEmpty);
  });

  test('every shipped profile satisfies the schema and the manifest', () {
    expect(profiles, isNotEmpty);
    for (final entry in profiles.entries) {
      expect(_violations(entry.value, schema), isEmpty, reason: entry.key);
      expect(() => ValidationProfile.fromJson(entry.value), returnsNormally);
    }
  });

  test('schema declares every property the manifest reads', () {
    final manifest = File('lib/src/manifest.dart').readAsStringSync();
    final npuReaders = [
      'lib/src/npu_evidence.dart',
      'lib/src/placement.dart',
    ].map((path) => File(path).readAsStringSync()).join();
    final topLevel = _literalKeys(manifest, ['data'])
      ..addAll(_literalKeys(npuReaders, ['profile', r'profile\.data']));
    final model = _literalKeys(manifest, ['model']);
    final target = _literalKeys(npuReaders, ['target']);
    expect(
      topLevel,
      containsAll(['fixtures', 'history_controls', 'npu_target']),
    );
    expect(model, contains('sha256'));
    expect(target, contains('libraries'));
    expect(topLevel.difference(properties.keys.toSet()), isEmpty);
    expect(
      model.difference(
        ((properties['model'] as Map)['properties'] as Map).keys.toSet(),
      ),
      isEmpty,
    );
    expect(
      target.difference(
        ((properties['npu_target'] as Map)['properties'] as Map).keys.toSet(),
      ),
      isEmpty,
    );
  });

  test('fixture overrides mirror the string fields of the shared catalog', () {
    final expected = {
      for (final entry in validationFixtures.entries)
        entry.key: {
          for (final field in entry.value.entries)
            if (field.value is String) field.key: const {'type': 'string'},
        },
    };
    final declared = properties['fixtures'] as Map;
    expect(declared['additionalProperties'], isFalse);
    final actual = {
      for (final entry in (declared['properties'] as Map).entries)
        entry.key: (entry.value as Map)['properties'],
    };
    expect(actual, expected);
    for (final fixture in (declared['properties'] as Map).values) {
      expect((fixture as Map)['additionalProperties'], isFalse);
    }
  });

  test('undeclared or mistyped properties violate the schema', () {
    final schemaOnly = <String, Map<String, dynamic>>{
      'top-level key': patched('chat-litert-cpu.json', {'unexpected': 1}),
      'model key': patched('chat-litert-cpu.json', {
        'model': {...profiles['chat-litert-cpu.json']!['model'], 'extra': 'x'},
      }),
      'npu profile without target': patched('npu-tensor-g5.json', {})
        ..remove('npu_target'),
      'npu target key': patched('npu-tensor-g5.json', {
        'npu_target': {
          ...profiles['npu-tensor-g5.json']!['npu_target'],
          'extra': 'x',
        },
      }),
      'library without elf class': patched('npu-tensor-g5.json', {
        'npu_target': {
          ...profiles['npu-tensor-g5.json']!['npu_target'],
          'libraries': {
            'libExtra.so': {'elf_machine': 183},
          },
        },
      }),
    };
    for (final entry in schemaOnly.entries) {
      expect(_violations(entry.value, schema), isNotEmpty, reason: entry.key);
    }
    final schemaAndManifest = <String, Map<String, dynamic>>{
      'unknown fixture': patched('chat-litert-cpu.json', {
        'fixtures': {'bogus': <String, Object>{}},
      }),
      'unknown fixture field': patched('chat-litert-cpu.json', {
        'fixtures': {
          'hello': {'bogus': 'x'},
        },
      }),
      'non-string fixture field': patched('chat-litert-cpu.json', {
        'fixtures': {
          'cancel': {'max_tokens': 1},
        },
      }),
      'non-boolean history controls': patched('chat-litert-cpu.json', {
        'history_controls': 'yes',
      }),
    };
    for (final entry in schemaAndManifest.entries) {
      expect(_violations(entry.value, schema), isNotEmpty, reason: entry.key);
      expect(
        () => ValidationProfile.fromJson(entry.value),
        throwsFormatException,
        reason: entry.key,
      );
    }
  });
}
