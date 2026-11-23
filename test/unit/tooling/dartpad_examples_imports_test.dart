@TestOn('vm')
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

const List<String> _dartpadExampleRoots = [
  'example/dartpad_gguf',
  'packages/genkit_llamadart/example/dartpad',
];

final RegExp _deprecatedImportPattern = RegExp(
  r'''^\s*(?:import|export)\s+['"]package:flutter/(?:material|cupertino)\.dart['"]''',
  multiLine: true,
);

String _normalizeRelativePath(String path) =>
    p.posix.joinAll(p.split(p.relative(path)));

void main() {
  test('DartPad example pubspec.yaml declares material_ui dependency', () {
    final failures = <String>[];
    for (final root in _dartpadExampleRoots) {
      final pubspecPath = p.posix.join(root, 'pubspec.yaml');
      final pubspecFile = File(p.joinAll(p.posix.split(pubspecPath)));
      expect(
        pubspecFile.existsSync(),
        isTrue,
        reason: 'Missing pubspec at $pubspecPath',
      );
      final document = loadYaml(pubspecFile.readAsStringSync());
      final dependencies = document is YamlMap
          ? document['dependencies']
          : null;
      final constraint = dependencies is YamlMap
          ? dependencies['material_ui']
          : null;
      if (constraint is! String || constraint.trim().isEmpty) {
        failures.add('$pubspecPath is missing dependencies.material_ui');
      }
    }
    expect(failures, isEmpty, reason: failures.join('\n'));
  });

  test(
    'DartPad examples do not import deprecated flutter/material.dart or flutter/cupertino.dart',
    () {
      final offendingFiles = <String>[];
      for (final root in _dartpadExampleRoots) {
        for (final subdir in ['lib', 'test']) {
          final directory = Directory(
            p.joinAll([...p.posix.split(root), subdir]),
          );
          expect(
            directory.existsSync(),
            isTrue,
            reason: 'Missing directory $root/$subdir',
          );
          final dartFiles = directory
              .listSync(recursive: true, followLinks: false)
              .whereType<File>()
              .where((file) => file.path.endsWith('.dart'))
              .toList();
          expect(
            dartFiles,
            isNotEmpty,
            reason: 'Expected at least one .dart file under $root/$subdir',
          );
          for (final file in dartFiles) {
            final contents = file.readAsStringSync();
            if (_deprecatedImportPattern.hasMatch(contents)) {
              offendingFiles.add(_normalizeRelativePath(file.path));
            }
          }
        }
      }
      offendingFiles.sort();
      expect(
        offendingFiles,
        isEmpty,
        reason:
            'Deprecated Flutter material/cupertino imports found in:\n'
            '${offendingFiles.join('\n')}',
      );
    },
  );
}
