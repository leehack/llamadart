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

    // No table entry is a substring of another today, so exact matching keeps
    // these distinct: `<image>` does not occur inside `<image_soft_token>`,
    // because the character after `image` is `_` rather than `>`. That safety
    // depends on matching the full literal — a looser match on `<image` would
    // rewrite the soft-token placeholder into `<__media__>_soft_token>`, so pin
    // the exact behaviour here.
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
      // `<img>` and `<|img|>` existed only in the llama.cpp service table, and
      // `<start_of_image>` only in the Gemma handler, so the same prompt
      // normalized differently depending on which path rendered it.
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
    // Guards the reason this module exists: a placeholder added to one consumer
    // and not the other is exactly the drift this replaced.
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
        expect(
          source,
          isNot(contains("'<image_soft_token>'")),
          reason: '$path should not re-declare its own placeholder table',
        );
      });
    }
  });
}
