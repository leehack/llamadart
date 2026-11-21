@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

// The root Markdown lane does not resolve the private validation package.
// ignore: avoid_relative_lib_imports
import '../../../packages/llamadart_validation/lib/android_litert_qualification.dart';

const adoptionNotes = 'doc/litert_lm_v1_adoption.md';
const adoptionSection = 'Accepted artifact and device scope';
const validationNotes = 'doc/cross_platform_validation.md';
const requalificationSection =
    'Galaxy S24 LiteRT-LM CPU and OpenCL requalification';

void main() {
  // Rebuilds with identical Android libraries share the original device run.
  const recordedRuns = [
    (
      tags: ['v0.19.1', 'v0.19.1-1'],
      matrix: 'matrix-1nd80qbdta8cf',
      run: 'core019-litert0191-s24-20261108',
      path: adoptionNotes,
      heading: adoptionSection,
    ),
    (
      tags: ['v0.19.1-2', 'v0.19.1-3', 'v0.19.1-4'],
      matrix: 'matrix-wmalbq6nz437a',
      run: 'pr1830-litert0191-2-s24-20261108',
      path: adoptionNotes,
      heading: adoptionSection,
    ),
    (
      tags: ['v0.19.1-5'],
      matrix: '8700956042671373601',
      run: 'pr2003-litert0191-5-s24-20261114',
      path: adoptionNotes,
      heading: adoptionSection,
    ),
    (
      tags: ['v0.19.1-6'],
      matrix: '5478981892550641608',
      run: 'pr2133-litert0191-6-s24-20261121',
      path: validationNotes,
      heading: requalificationSection,
    ),
  ];

  test('each admitted S24 runtime maps to exactly one recorded run', () {
    expect(
      recordedRuns.expand((record) => record.tags),
      unorderedEquals(s24LiteRtRuntimeTags),
    );
  });

  for (final record in recordedRuns) {
    final testedTag = record.tags.first;
    test('$testedTag is documented with its S24 matrix and run', () {
      final notes = File(
        record.path,
      ).readAsStringSync().replaceAll('\r\n', '\n');
      final sections = notes.split('\n## ');
      final section = sections.singleWhere(
        (section) => section.startsWith('${record.heading}\n'),
        orElse: () => '',
      );
      final runtimeTag = RegExp(
        '(?:^|[\\s`])${RegExp.escape(testedTag)}(?=[\\s`])',
      );
      expect(
        section
            .split('\n\n')
            .any(
              (paragraph) =>
                  runtimeTag.hasMatch(paragraph) &&
                  paragraph.contains('`${record.matrix}`') &&
                  paragraph.contains('`${record.run}`'),
            ),
        isTrue,
        reason:
            '${record.path} under "${record.heading}" must identify '
            '$testedTag, matrix ${record.matrix}, and run ${record.run} '
            'in the same paragraph.',
      );
    });
  }
}
