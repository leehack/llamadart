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
  'test/fixtures/llama_cpp_templates/LFM2-8B-A1B.jinja': '10101000',
  'test/fixtures/llama_cpp_templates/Qwen-QwQ-32B.jinja': '11111011',
  'test/fixtures/llama_cpp_templates/deepseek-ai-DeepSeek-V3.1.jinja':
      '11011011',
  'test/fixtures/llama_cpp_templates/fireworks-ai-llama-3-firefunction-v2.jinja':
      '11111001',
  'test/fixtures/llama_cpp_templates/google-gemma-4-31B-it-interleaved.jinja':
      '11111111',
  'test/fixtures/llama_cpp_templates/meetkai-functionary-medium-v3.1.jinja':
      '11111001',
  'test/fixtures/llama_cpp_templates/meetkai-functionary-medium-v3.2.jinja':
      '11111000',
  'test/fixtures/llama_cpp_templates/openai-gpt-oss-120b.jinja': '11101001',
  'test/fixtures/llama_cpp_templates/unsloth-mistral-Devstral-Small-2507.jinja':
      '11111101',
  'test/fixtures/llama_cpp_templates/upstage-Solar-Open-100B.jinja': '11111011',
  'test/fixtures/templates/DeepSeek-R1-Distill-Llama-8B.jinja': '10001000',
  'test/fixtures/templates/DeepSeek-R1-Distill-Qwen-1_5B.jinja': '10001000',
  'test/fixtures/templates/LFM2_5-1_2B-Thinking.jinja': '10101000',
  'test/fixtures/templates/Llama-3_2-3B-Instruct.jinja': '11101001',
  'test/fixtures/templates/Ministral-3-3B-Reasoning.jinja': '11111111',
  'test/fixtures/templates/Phi-4-mini-instruct-reasoning.jinja': '10001000',
  'test/fixtures/templates/Qwen3-4B.jinja': '11111011',
  'test/fixtures/templates/Qwen3_5-0_8B.jinja': '11111111',
  'test/fixtures/templates/TranslateGemma-2B-it.jinja': '00001100',
  'test/fixtures/templates/functiongemma-270m-it.jinja': '11111100',
  'test/fixtures/templates/gemma-3-4b-it.jinja': '10001100',
  'test/fixtures/templates/gemma-3n-E4B-it.jinja': '10001100',
  'test/fixtures/templates/gemma-4-E2B-it.jinja': '11111111',
  'tool/litert_lm_templates/gemma.jinja': '10001100',
  'tool/litert_lm_templates/gemma3n.jinja': '10001100',
  'tool/litert_lm_templates/gemma4.jinja': '11111111',
  'tool/litert_lm_templates/qwen25.jinja': '11111001',
  'tool/litert_lm_templates/qwen3.jinja': '11111011',
};

const List<String> _capsOrder = <String>[
  'supports_system_role',
  'supports_tool_calls',
  'supports_tools',
  'supports_parallel_tool_calls',
  'supports_string_content',
  'supports_typed_content',
  'supports_thinking',
  'supports_object_arguments',
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
