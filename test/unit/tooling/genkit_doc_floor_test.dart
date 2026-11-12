@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

void main() {
  final floor = RegExp(r'^  llamadart: \^(\S+)\s*$', multiLine: true)
      .firstMatch(
        File('packages/genkit_llamadart/pubspec.yaml').readAsStringSync(),
      )![1]!;

  for (final (path, claim) in <(String, String)>[
    (
      'website/docs/maintainers/genkit-package.md',
      'published llamadart $floor',
    ),
    ('packages/genkit_llamadart/README.md', 'llamadart $floor or newer'),
    ('packages/genkit_llamadart/doc/migration.md', 'llamadart `^$floor`'),
    (
      'packages/genkit_llamadart/doc/tool-input-schemas.md',
      'llamadart `^$floor`',
    ),
    ('.github/workflows/ci.yml', 'llamadart@$floor '),
  ]) {
    test('$path names the genkit_llamadart llamadart floor $floor', () {
      expect(File(path).readAsStringSync(), contains(claim));
    });
  }
}
