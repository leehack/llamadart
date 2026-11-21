@TestOn('vm')
library;

import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:test/test.dart';

// The root Markdown lane does not resolve the private validation package.
// ignore: avoid_relative_lib_imports
import '../../../packages/llamadart_validation/lib/android_litert_qualification.dart';

const adoptionNotes = 'doc/litert_lm_v1_adoption.md';
const adoptionSection = 'Accepted artifact and device scope';
const validationNotes = 'doc/cross_platform_validation.md';
const requalificationSection =
    'Galaxy S24 LiteRT-LM CPU and OpenCL requalification';
const qualificationSource =
    'packages/llamadart_validation/lib/android_litert_qualification.dart';

Map<String, String> readRuntimeAliases() {
  final source = parseString(
    content: File(qualificationSource).readAsStringSync(),
    path: qualificationSource,
  );
  final declaration = source.unit.declarations
      .whereType<TopLevelVariableDeclaration>()
      .expand((declaration) => declaration.variables.variables)
      .singleWhere(
        (variable) => variable.name.lexeme == '_s24LiteRtRuntimeAliases',
      );
  final literal = declaration.initializer as SetOrMapLiteral;
  return {
    for (final element in literal.elements.cast<MapLiteralEntry>())
      (element.key as StringLiteral).stringValue!:
          (element.value as StringLiteral).stringValue!,
  };
}

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
    (
      tags: ['v0.19.1-7'],
      matrix: '5637049545946379077',
      run: 'w2134a-litert0191-7-s24-20261121',
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

  test('each Android rebuild alias maps to its recorded runtime', () {
    expect(readRuntimeAliases(), {
      for (final record in recordedRuns)
        for (final alias in record.tags.skip(1)) alias: record.tags.first,
    });
  });

  for (final record in recordedRuns) {
    test('${record.tags.first} and its aliases name the same S24 run', () {
      final notes = File(
        record.path,
      ).readAsStringSync().replaceAll('\r\n', '\n');
      final sections = notes.split('\n## ');
      final section = sections.singleWhere(
        (section) => section.startsWith('${record.heading}\n'),
        orElse: () => '',
      );
      final runParagraph = section
          .split('\n\n')
          .singleWhere(
            (paragraph) =>
                paragraph.contains('`${record.matrix}`') &&
                paragraph.contains('`${record.run}`'),
            orElse: () => '',
          );
      for (final tag in record.tags) {
        final runtimeTag = RegExp(
          '(?:^|[\\s`])${RegExp.escape(tag)}(?=\$|[\\s`])',
        );
        expect(
          runParagraph,
          matches(runtimeTag),
          reason:
              '${record.path} under "${record.heading}" must identify '
              '$tag, matrix ${record.matrix}, and run ${record.run} '
              'in the same paragraph.',
        );
      }
    });
  }
}
