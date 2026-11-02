@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  late Directory directory;
  late Map<String, dynamic> row;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('lfm-generation-contract-');
    File('${directory.path}/existing.gguf').writeAsBytesSync([1]);
    row = {
      'set': 'fixture',
      'key': 'original',
      'model': 'existing.gguf',
      'system': 'Use a tool.',
      'prompt': 'Copy this.',
      'choice': 'auto',
      'parallel': false,
      'thinking': false,
      'tools': [
        {
          'type': 'function',
          'function': {
            'name': 'clock',
            'description': 'Return time.',
            'parameters': {'type': 'object', 'properties': <String, dynamic>{}},
          },
        },
      ],
      'sampling': <String, dynamic>{
        'maxTokens': 16,
        'temp': 0.0,
        'seed': 7,
        'topK': 40,
        'topP': 0.9,
        'minP': 0.0,
        'penalty': 1.1,
      },
    };
    addTearDown(() => directory.deleteSync(recursive: true));
  });

  Future<ProcessResult> run(List<Map<String, dynamic>> rows) async {
    final manifest = File('${directory.path}/manifest.json')
      ..writeAsStringSync(jsonEncode(rows));
    return Process.run('dart', [
      'run',
      'test/support/lfm2_schema_generation.dart',
      manifest.path,
      '${directory.path}/output.json',
      directory.path,
      'python',
      '--dry-run',
    ]);
  }

  test(
    'capture dry-run validates original declarations without loading weights',
    () async {
      final result = await run([row]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(result.stdout, contains('"tools_and_sampling":"validated"'));
      expect(File('${directory.path}/output.json').existsSync(), isFalse);
    },
  );

  test('capture rejects dropped sampling metadata before generation', () async {
    (row['sampling'] as Map).remove('seed');
    final result = await run([row]);
    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('Incomplete sampling metadata'));
    expect(File('${directory.path}/output.json').existsSync(), isFalse);
  });

  test(
    'capture rejects changed tool reconstruction before generation',
    () async {
      final function =
          ((row['tools'] as List).single as Map)['function'] as Map;
      (function['parameters'] as Map)['additionalProperties'] = false;
      final result = await run([row]);
      expect(result.exitCode, isNot(0));
      expect(result.stderr, contains('Tool reconstruction changed'));
    },
  );

  test('capture rejects duplicate row identities before generation', () async {
    final result = await run([row, row]);
    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('Duplicate capture identity'));
  });

  test('capture rejects sampling type changes before generation', () async {
    (row['sampling'] as Map)['seed'] = '7';
    final result = await run([row]);
    expect(result.exitCode, isNot(0));
    expect(result.stderr, contains('Invalid original sampling'));
  });
}
