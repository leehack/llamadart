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

const Map<String, String> _pinnedCaps = <String, String>{
  'test/fixtures/llama_cpp_templates/fireworks-ai-llama-3-firefunction-v2.jinja':
      '1111100',
  'test/fixtures/llama_cpp_templates/google-gemma-4-31B-it-interleaved.jinja':
      '1111111',
  'test/fixtures/llama_cpp_templates/meetkai-functionary-medium-v3.1.jinja':
      '1111100',
  'test/fixtures/llama_cpp_templates/meetkai-functionary-medium-v3.2.jinja':
      '1111100',
  'test/fixtures/templates/DeepSeek-R1-Distill-Llama-8B.jinja': '1000100',
  'test/fixtures/templates/DeepSeek-R1-Distill-Qwen-1_5B.jinja': '1000100',
  'test/fixtures/templates/LFM2_5-1_2B-Thinking.jinja': '1010100',
  'test/fixtures/templates/Llama-3_2-3B-Instruct.jinja': '1110100',
  'test/fixtures/templates/Ministral-3-3B-Reasoning.jinja': '1111111',
  'test/fixtures/templates/Phi-4-mini-instruct-reasoning.jinja': '1000100',
  'test/fixtures/templates/Qwen3-4B.jinja': '1111101',
  'test/fixtures/templates/Qwen3_5-0_8B.jinja': '1111111',
  'test/fixtures/templates/TranslateGemma-2B-it.jinja': '0000110',
  'test/fixtures/templates/functiongemma-270m-it.jinja': '1111110',
  'test/fixtures/templates/gemma-3-4b-it.jinja': '1000110',
  'test/fixtures/templates/gemma-3n-E4B-it.jinja': '1000110',
  'test/fixtures/templates/gemma-4-E2B-it.jinja': '1111111',
  'tool/litert_lm_templates/gemma.jinja': '1000110',
  'tool/litert_lm_templates/gemma3n.jinja': '1000110',
  'tool/litert_lm_templates/gemma4.jinja': '1111111',
  'tool/litert_lm_templates/qwen25.jinja': '1111100',
  'tool/litert_lm_templates/qwen3.jinja': '1111101',
};

const List<String> _capsOrder = <String>[
  'supports_system_role',
  'supports_tool_calls',
  'supports_tools',
  'supports_parallel_tool_calls',
  'supports_string_content',
  'supports_typed_content',
  'supports_thinking',
];

String _capsBits(TemplateCaps caps) {
  final map = caps.toMap();
  return _capsOrder.map((key) => map[key]! ? '1' : '0').join();
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

  test('pins detected capabilities for every fixture template', () {
    final detected = <String, String>{};
    final failed = <String>[];
    for (final file in _fixtureTemplates()) {
      final path = file.path.replaceAll(r'\', '/');
      final outcome = JinjaAnalyzer.analyzeWithOutcome(file.readAsStringSync());
      detected[path] = _capsBits(outcome.caps);
      if (outcome.failed) {
        failed.add(path);
      }
    }

    expect(detected, _pinnedCaps);
    expect(failed, isEmpty);
  });

  test('caches every fixture template', () {
    for (final file in _fixtureTemplates()) {
      TemplateCapsCache.shared.clear();
      TemplateCaps.detect(file.readAsStringSync());

      expect(TemplateCapsCache.shared.length, 1, reason: file.path);
    }
  });
}
