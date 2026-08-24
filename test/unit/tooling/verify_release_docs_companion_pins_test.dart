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

List<String> _releaseWorkflowContractProblems(String workflow) {
  final problems = <String>[];
  final strictGate = RegExp(
    r'^\s+dart run tool/testing/verify_release_docs_versions\.dart '
    r'--release-prep\s*$',
    multiLine: true,
  );
  final gateMatches = strictGate.allMatches(workflow).toList();
  if (gateMatches.length != 1) {
    problems.add(
      'expected exactly one strict release-prep verifier, found '
      '${gateMatches.length}',
    );
  }

  const validateStep = '- name: Validate release state';
  const publishStep = '- name: Publish companion packages and core tag';
  const releaseSecret =
      r'RELEASE_TOKEN: ${{ secrets.RELEASE_AUTOMATION_TOKEN }}';
  final validateIndex = workflow.indexOf(validateStep);
  final gateIndex = gateMatches.length == 1 ? gateMatches.single.start : -1;
  final publishIndex = workflow.indexOf(publishStep);
  final secretIndex = workflow.indexOf(releaseSecret);
  if (validateIndex == -1 || publishIndex == -1 || secretIndex == -1) {
    problems.add('release validation, publication, or secret step is missing');
  } else if (!(validateIndex < gateIndex &&
      gateIndex < publishIndex &&
      publishIndex < secretIndex)) {
    problems.add(
      'strict release-prep verification must run in validation before the '
      'secret-bearing publication step',
    );
  }
  return problems;
}

List<String> _releaseDocsCliContractProblems(String source) {
  final problems = <String>[];
  final companionCheck = RegExp(
    r'pending = checkCompanionSwiftPins\(\s*Directory\.current,\s*errors\s*\);',
    multiLine: true,
  ).allMatches(source).toList();
  final strictMode = RegExp(
    r'if \(releasePrep\) \{\s*'
    r'errors\.addAll\(pending\.map\(\(bump\) => bump\.toString\(\)\)\);\s*\}',
    multiLine: true,
  ).allMatches(source).toList();
  if (companionCheck.length != 1) {
    problems.add(
      'expected one production companion-pin check, found '
      '${companionCheck.length}',
    );
  }
  if (strictMode.length != 1) {
    problems.add(
      'expected one fail-closed release-prep pending-bump check, found '
      '${strictMode.length}',
    );
  }

  final errorGuard = source.indexOf('if (errors.isNotEmpty) {');
  if (companionCheck.length == 1 &&
      strictMode.length == 1 &&
      !(companionCheck.single.start < strictMode.single.start &&
          strictMode.single.start < errorGuard)) {
    problems.add(
      'companion-pin and release-prep checks must run before success can be '
      'reported',
    );
  }
  return problems;
}

void main() {
  test(
    'release workflow runs the strict gate before publication authority',
    () {
      final workflow = File(
        '.github/workflows/release_on_prep_merge.yml',
      ).readAsStringSync();

      expect(_releaseWorkflowContractProblems(workflow), isEmpty);
    },
  );

  test('release workflow contract rejects deletion, bypass, and miswiring', () {
    final workflow = File(
      '.github/workflows/release_on_prep_merge.yml',
    ).readAsStringSync();
    const strictCommand =
        'dart run tool/testing/verify_release_docs_versions.dart '
        '--release-prep';
    const publishStep = '- name: Publish companion packages and core tag';

    expect(
      _releaseWorkflowContractProblems(
        workflow.replaceFirst(strictCommand, ''),
      ),
      isNotEmpty,
    );
    expect(
      _releaseWorkflowContractProblems(
        workflow.replaceFirst(strictCommand, '$strictCommand || true'),
      ),
      isNotEmpty,
    );
    expect(
      _releaseWorkflowContractProblems(
        workflow
            .replaceFirst(strictCommand, '')
            .replaceFirst(
              publishStep,
              '$publishStep\n          $strictCommand',
            ),
      ),
      isNotEmpty,
    );
  });

  test('release docs CLI wires companion checks into strict mode', () {
    final source = File(
      'tool/testing/verify_release_docs_versions.dart',
    ).readAsStringSync();

    expect(_releaseDocsCliContractProblems(source), isEmpty);
  });

  test('release docs CLI contract rejects deletion and bypass', () {
    final source = File(
      'tool/testing/verify_release_docs_versions.dart',
    ).readAsStringSync();

    expect(
      _releaseDocsCliContractProblems(
        source.replaceFirst(
          'checkCompanionSwiftPins(Directory.current, errors)',
          'checkCompanionSwiftPins(Directory.systemTemp, errors)',
        ),
      ),
      isNotEmpty,
    );
    expect(
      _releaseDocsCliContractProblems(
        source.replaceFirst('if (releasePrep) {', 'if (false) {'),
      ),
      isNotEmpty,
    );
    expect(
      _releaseDocsCliContractProblems(
        source.replaceFirst(
          'pending = checkCompanionSwiftPins(Directory.current, errors);',
          '',
        ),
      ),
      isNotEmpty,
    );
  });

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

  test('duplicate CHANGELOG sections fail closed', () {
    final root = _fakeRepo(
      swiftTag: 'b10545',
      version: '0.0.15',
      changelog:
          '## 0.0.15\n\n* Pin `leehack/llamadart-native@b10545`.\n\n'
          '## 0.0.15\n\n* Pin `leehack/llamadart-native@b10514`.\n',
    );
    final errors = <String>[];

    expect(checkCompanionSwiftPins(root, errors), isEmpty);
    expect(
      errors,
      contains(
        'packages/llamadart_llama_cpp_flutter/CHANGELOG.md contains '
        'duplicate `## 0.0.15` sections.',
      ),
    );
  });

  test('invalid UTF-8 scalar input is reported without throwing', () {
    final root = _fakeRepo(
      swiftTag: 'b10545',
      version: '0.0.15',
      changelog: '## 0.0.15\n\n* Pin `leehack/llamadart-native@b10545`.\n',
    );
    final path = 'packages/llamadart_llama_cpp_flutter/pubspec.yaml';
    File('${root.path}/$path').writeAsBytesSync(<int>[0xff]);
    final errors = <String>[];

    expect(() => checkCompanionSwiftPins(root, errors), returnsNormally);
    expect(errors, contains(contains('$path could not be')));
  });

  test('invalid UTF-8 Swift pin input is reported without throwing', () {
    final root = _fakeRepo(
      swiftTag: 'b10545',
      version: '0.0.15',
      changelog: '## 0.0.15\n\n* Pin `leehack/llamadart-native@b10545`.\n',
    );
    final path =
        'packages/llamadart_llama_cpp_flutter/darwin/'
        'llamadart_llama_cpp_flutter/Package.swift';
    File('${root.path}/$path').writeAsBytesSync(<int>[0xff]);
    final errors = <String>[];

    expect(() => checkCompanionSwiftPins(root, errors), returnsNormally);
    expect(errors, contains(contains('$path could not be')));
  });

  test('an unreadable changelog is reported without throwing', () {
    final root = _fakeRepo(
      swiftTag: 'b10545',
      version: '0.0.15',
      changelog: '## 0.0.15\n\n* Pin `leehack/llamadart-native@b10545`.\n',
    );
    final path = 'packages/llamadart_llama_cpp_flutter/CHANGELOG.md';
    final changelog = File('${root.path}/$path');
    final chmod = Process.runSync('chmod', <String>['000', changelog.path]);
    expect(chmod.exitCode, 0);
    addTearDown(
      () => Process.runSync('chmod', <String>['600', changelog.path]),
    );
    final errors = <String>[];

    expect(() => checkCompanionSwiftPins(root, errors), returnsNormally);
    expect(errors, contains(contains('$path could not be read:')));
  }, skip: Platform.isWindows ? 'requires POSIX file permissions' : false);
}
