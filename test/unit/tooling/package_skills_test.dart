@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

// Rules from https://dart.dev/tools/pub/package-skills and
// https://agentskills.io/specification. `dart run skills@ get` silently skips
// a skill whose directory lacks the package-name prefix.
const String _packageName = 'llamadart';
const String _consumerName = 'skill_examples';
const int _maxSkillLines = 500;
const int _maxNameLength = 64;
const int _maxDescriptionLength = 1024;
final RegExp _namePattern = RegExp(r'^[a-z0-9]+(-[a-z0-9]+)*$');
final RegExp _frontmatter = RegExp(r'^---\n([\s\S]*?)\n---\n');
final RegExp _dartBlock = RegExp(r'```dart\n([\s\S]*?)```');

void main() {
  final List<Directory> directories =
      Directory('skills').listSync().whereType<Directory>().toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  final Map<String, String> skills = {
    for (final Directory directory in directories)
      // Windows checkouts may convert line endings to CRLF.
      p.basename(directory.path): File(
        p.join(directory.path, 'SKILL.md'),
      ).readAsStringSync().replaceAll('\r\n', '\n'),
  };

  test('ships at least one skill', () {
    expect(skills, isNotEmpty);
  });

  skills.forEach((String directoryName, String markdown) {
    group(directoryName, () {
      test('uses the package-name prefix and a spec-valid name', () {
        expect(directoryName, startsWith('$_packageName-'));
        expect(directoryName, matches(_namePattern));
        expect(directoryName.length, lessThanOrEqualTo(_maxNameLength));
      });

      test('has frontmatter matching the directory', () {
        final RegExpMatch? match = _frontmatter.firstMatch(markdown);
        expect(match, isNotNull, reason: 'missing YAML frontmatter');
        final YamlMap metadata = loadYaml(match!.group(1)!) as YamlMap;
        expect(metadata['name'], directoryName);
        final Object? description = metadata['description'];
        expect(description, isA<String>());
        expect((description as String).trim(), isNotEmpty);
        expect(description.length, lessThanOrEqualTo(_maxDescriptionLength));
      });

      test('stays within the line budget', () {
        expect(
          '\n'.allMatches(markdown).length,
          lessThanOrEqualTo(_maxSkillLines),
        );
      });
    });
  });

  test('Dart examples analyze against the public API', () async {
    final ProcessResult result = await _analyzeDartFences(skills);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('Dart example using a deprecated member fails analysis', () async {
    final ProcessResult result = await _analyzeDartFences({
      'deprecated-example': '''
```dart
import 'package:llamadart/llamadart.dart';

Future<void> load(LlamaEngine engine, String path) => engine.loadModel(path);
```
''',
    });
    final String output = '${result.stdout}\n${result.stderr}';
    expect(output, contains("'loadModel' is deprecated"));
    expect(output, matches(r'\bdeprecated_member_use\b'));
    expect(result.exitCode, isNonZero, reason: output);
  }, timeout: const Timeout(Duration(minutes: 3)));
}

Future<ProcessResult> _analyzeDartFences(Map<String, String> markdownByName) {
  final Directory consumer = _createConsumerPackage();
  final Directory snippets = Directory(p.join(consumer.path, 'lib'))
    ..createSync();

  int count = 0;
  markdownByName.forEach((String name, String markdown) {
    final String prefix = name.replaceAll('-', '_');
    for (final RegExpMatch block in _dartBlock.allMatches(markdown)) {
      File(
        p.join(snippets.path, '${prefix}_${count++}.dart'),
      ).writeAsStringSync(block.group(1)!);
    }
  });
  expect(count, greaterThan(0));

  return Process.run(Platform.resolvedExecutable, [
    '--suppress-analytics',
    'analyze',
    snippets.path,
  ], workingDirectory: consumer.path);
}

Directory _createConsumerPackage() {
  final Directory consumer = Directory.systemTemp.createTempSync('sk2098-');
  addTearDown(() => consumer.deleteSync(recursive: true));

  final YamlMap pubspec = loadYaml(File('pubspec.yaml').readAsStringSync());
  final String sdk = pubspec['environment']['sdk'] as String;
  File(p.join(consumer.path, 'pubspec.yaml')).writeAsStringSync('''
name: $_consumerName
environment:
  sdk: ${jsonEncode(sdk)}
dependencies:
  $_packageName:
    path: ${jsonEncode(p.current)}
''');
  final Uri rootOptions = File('analysis_options.yaml').absolute.uri;
  File(p.join(consumer.path, 'analysis_options.yaml')).writeAsStringSync('''
include: $rootOptions
analyzer:
  errors:
    deprecated_member_use: error
''');

  // Rebase relative package roots so analysis uses the exact workspace
  // resolution without invoking pub or accessing the network.
  final File rootConfig = File(p.join('.dart_tool', 'package_config.json'));
  final config =
      jsonDecode(rootConfig.readAsStringSync()) as Map<String, dynamic>;
  final packages = (config['packages'] as List).cast<Map<String, dynamic>>();
  final Map<String, dynamic> llamadart = packages.singleWhere(
    (package) => package['name'] == _packageName,
  );
  final File consumerConfig = File(
    p.join(consumer.path, '.dart_tool', 'package_config.json'),
  )..createSync(recursive: true);
  consumerConfig.writeAsStringSync(
    jsonEncode({
      ...config,
      'packages': [
        for (final Map<String, dynamic> package in packages)
          {
            ...package,
            'rootUri': rootConfig.absolute.uri
                .resolve(package['rootUri'] as String)
                .toString(),
          },
        {
          'name': _consumerName,
          'rootUri': '../',
          'packageUri': 'lib/',
          'languageVersion': llamadart['languageVersion'],
        },
      ],
    }),
  );
  return consumer;
}
