@TestOn('vm')
library;

import 'dart:io';

import 'package:llamadart/src/core/template/media_placeholders.dart';
import 'package:test/test.dart';

void main() {
  group('normalizeMediaPlaceholders', () {
    test('rewrites every placeholder in the shared table', () {
      for (final placeholder in mtmdMediaPlaceholders) {
        expect(
          normalizeMediaPlaceholders('before $placeholder after'),
          'before $mtmdMediaMarker after',
          reason: '$placeholder should normalize to the mtmd marker',
        );
      }
    });

    test('rewrites indexed image placeholders', () {
      expect(
        normalizeMediaPlaceholders('a <|image_1|> b <|image_12|> c'),
        'a $mtmdMediaMarker b $mtmdMediaMarker c',
      );
    });

    test('honours a runtime-resolved marker', () {
      expect(
        normalizeMediaPlaceholders('<image>', marker: '<<media>>'),
        '<<media>>',
      );
    });

    test('rewrites every occurrence, not just the first', () {
      expect(
        normalizeMediaPlaceholders('<image><image>'),
        '$mtmdMediaMarker$mtmdMediaMarker',
      );
    });

    // A looser match on `<image` would corrupt `<image_soft_token>`.
    test('matches full literals rather than shared prefixes', () {
      expect(normalizeMediaPlaceholders('<image_soft_token>'), mtmdMediaMarker);
      expect(normalizeMediaPlaceholders('<|image_1|>'), mtmdMediaMarker);
    });

    test('leaves unrelated markup alone', () {
      expect(
        normalizeMediaPlaceholders('<think>text</think> <imagine>'),
        '<think>text</think> <imagine>',
      );
    });

    test('covers the markers that previously differed between layers', () {
      // Each of these lived in only one of the tables before.
      for (final placeholder in <String>[
        '<img>',
        '<|img|>',
        '<start_of_image>',
      ]) {
        expect(mtmdMediaPlaceholders, contains(placeholder));
        expect(normalizeMediaPlaceholders(placeholder), mtmdMediaMarker);
      }
    });
  });

  group('shared table adoption', () {
    // A placeholder added to one consumer and not the other is the drift
    // this module replaced.
    const consumers = <String>[
      'lib/src/core/template/chat_template_handler.dart',
      'lib/src/core/template/handlers/function_gemma_handler.dart',
      'lib/src/backends/llama_cpp/llama_cpp_service.dart',
    ];

    for (final path in consumers) {
      test('$path normalizes through the shared helper', () {
        final source = File(path).readAsStringSync();
        expect(
          source,
          contains('normalizeMediaPlaceholders('),
          reason: '$path should delegate to the shared helper',
        );
        for (final placeholder in mtmdMediaPlaceholders) {
          for (final literal in ["'$placeholder'", '"$placeholder"']) {
            expect(
              source,
              isNot(contains(literal)),
              reason: '$path should not re-declare $placeholder',
            );
          }
        }
        expect(
          source,
          isNot(contains(mtmdIndexedImagePlaceholder.pattern)),
          reason: '$path should not re-declare the indexed image pattern',
        );
      });
    }
  });
}
