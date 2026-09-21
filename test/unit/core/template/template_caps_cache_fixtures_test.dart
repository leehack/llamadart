@TestOn('vm')
library;

import 'dart:io';

import 'package:llamadart/src/core/template/jinja/jinja_analyzer.dart';
import 'package:llamadart/src/core/template/template_caps.dart';
import 'package:llamadart/src/core/template/template_caps_cache.dart';
import 'package:test/test.dart';

List<File> _fixtureTemplates() {
  final files = <File>[];
  for (final path in const <String>[
    'test/fixtures/llama_cpp_templates',
    'test/fixtures/templates',
    'tool/litert_lm_templates',
  ]) {
    files.addAll(
      Directory(path).listSync().whereType<File>().where(
        (file) => file.path.endsWith('.jinja'),
      ),
    );
  }
  files.sort((a, b) => a.path.compareTo(b.path));
  return files;
}

void main() {
  setUp(TemplateCapsCache.shared.clear);
  tearDown(TemplateCapsCache.shared.clear);

  test('matches uncached analysis for every fixture template', () {
    final fixtures = _fixtureTemplates();
    expect(fixtures, isNotEmpty);

    for (final file in fixtures) {
      final source = file.readAsStringSync();
      final expected = JinjaAnalyzer.analyze(source).toMap();

      expect(TemplateCaps.detect(source).toMap(), expected, reason: file.path);
      expect(TemplateCaps.detect(source).toMap(), expected, reason: file.path);
    }
  });
}
