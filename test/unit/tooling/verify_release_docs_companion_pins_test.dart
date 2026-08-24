@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

import '../../../tool/testing/verify_release_docs_versions.dart';

/// Builds a repo holding only what [checkCompanionSwiftPins] reads for
/// `llamadart_llama_cpp_flutter`, plus a valid litert companion so the second
/// entry never contributes noise.
Directory _fakeRepo({
  required String swiftTag,
  required String version,
  required String changelog,
}) {
  final root = Directory.systemTemp.createTempSync('companion_pins');
  addTearDown(() => root.deleteSync(recursive: true));
  final entries = <String, String>{
    'packages/llamadart_llama_cpp_flutter/darwin/'
            'llamadart_llama_cpp_flutter/Package.swift':
        'let llamaCppTag = "$swiftTag"\n',
    'packages/llamadart_llama_cpp_flutter/pubspec.yaml': 'version: $version\n',
    'packages/llamadart_llama_cpp_flutter/CHANGELOG.md': changelog,
    'packages/llamadart_litert_lm_flutter/darwin/'
            'llamadart_litert_lm_flutter/Package.swift':
        'let liteRtLmTag = "v1.0.0"\n',
    'packages/llamadart_litert_lm_flutter/pubspec.yaml': 'version: 1.2.3\n',
    'packages/llamadart_litert_lm_flutter/CHANGELOG.md':
        '## 1.2.3\n\n* Pin `leehack/litert-lm-native@v1.0.0`.\n',
  };
  for (final entry in entries.entries) {
    File('${root.path}/${entry.key}')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(entry.value);
  }
  return root;
}

void main() {
  test('the checked-in companions are release-ready', () {
    final errors = <String>[];

    expect(checkCompanionSwiftPins(Directory.current, errors), isEmpty);
    expect(errors, isEmpty);
  });

  test('a pin recorded in the released section passes', () {
    final root = _fakeRepo(
      swiftTag: 'b10545',
      version: '0.0.15',
      changelog:
          '## 0.0.15\n\n* Pin `leehack/llamadart-native@b10545`.\n\n'
          '## 0.0.14\n\n* Pin `leehack/llamadart-native@b10514`.\n',
    );
    final errors = <String>[];

    expect(checkCompanionSwiftPins(root, errors), isEmpty);
    expect(errors, isEmpty);
  });

  test('a pin sitting only in Unreleased is pending, not an error', () {
    final root = _fakeRepo(
      swiftTag: 'b10545',
      version: '0.0.14',
      changelog:
          '## Unreleased\n\n* Pin `leehack/llamadart-native@b10545`.\n\n'
          '## 0.0.14\n\n* Pin `leehack/llamadart-native@b10514`.\n',
    );
    final errors = <String>[];

    expect(
      checkCompanionSwiftPins(root, errors).map((bump) => bump.toString()),
      contains(
        'llamadart_llama_cpp_flutter 0.0.14 publishes b10514, but '
        'Package.swift pins b10545; bump the version and rename '
        '`## Unreleased` to the new version before releasing.',
      ),
    );
    expect(errors, isEmpty);
  });

  test('a pin recorded nowhere is an error in every mode', () {
    final root = _fakeRepo(
      swiftTag: 'b10545',
      version: '0.0.14',
      changelog: '## 0.0.14\n\n* Pin `leehack/llamadart-native@b10514`.\n',
    );
    final errors = <String>[];

    expect(checkCompanionSwiftPins(root, errors), isEmpty);
    expect(
      errors,
      contains(
        'packages/llamadart_llama_cpp_flutter/darwin/'
        'llamadart_llama_cpp_flutter/Package.swift pins b10545, but '
        'packages/llamadart_llama_cpp_flutter/CHANGELOG.md section '
        '`## 0.0.14` records b10514 and no `## Unreleased` entry records '
        'b10545.',
      ),
    );
  });

  test('a version with no CHANGELOG section is an error', () {
    final root = _fakeRepo(
      swiftTag: 'b10545',
      version: '0.0.15',
      changelog: '## 0.0.14\n\n* Pin `leehack/llamadart-native@b10514`.\n',
    );
    final errors = <String>[];

    checkCompanionSwiftPins(root, errors);
    expect(
      errors,
      contains(
        'packages/llamadart_llama_cpp_flutter/CHANGELOG.md has no '
        '`## 0.0.15` section for the version in '
        'packages/llamadart_llama_cpp_flutter/pubspec.yaml.',
      ),
    );
  });

  test('a released section with no pin at all is an error', () {
    final root = _fakeRepo(
      swiftTag: 'b10545',
      version: '0.0.15',
      changelog: '## 0.0.15\n\n* Something unrelated.\n',
    );
    final errors = <String>[];

    checkCompanionSwiftPins(root, errors);
    expect(
      errors,
      contains(
        'packages/llamadart_llama_cpp_flutter/CHANGELOG.md section '
        '`## 0.0.15` does not record a `leehack/llamadart-native@<tag>` pin.',
      ),
    );
  });
}
