@TestOn('vm')
@Tags(['local-only'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart_validation/android_litert_qualification.dart';
import 'package:llamadart_validation/llamadart_validation.dart';
import 'package:test/test.dart';

import '../../../test/support/suite_system_temp.dart';
import '../../../tool/litert_lm_tokenizer_fixture.dart';

void main() {
  final modelPath = Platform.environment['LITERT_LM_QWEN3_UNICODE_MODEL'];
  if (modelPath == null || modelPath.isEmpty) {
    test(
      'Qwen3 LiteRT GPU Unicode',
      () {},
      skip: 'Run the qwen3-litert-gpu-unicode local E2E scenario.',
    );
    return;
  }
  final model = File(modelPath);
  useSuiteSystemTemp();
  late ValidationProfile profile;
  setUpAll(() async {
    final digest = await verifyQwen3TokenizerArtifact(model);
    final profileAsset = digest == qwen3OriginalModelSha256
        ? s24LiteRtLegacyGpuProfileAsset
        : 'assets/profiles/chat-litert-gpu.json';
    final profileJson =
        jsonDecode(File(profileAsset).readAsStringSync())
            as Map<String, dynamic>;
    profile = ValidationProfile.fromJson(
      profileJson
        ..['selection'] = 'focused'
        ..['focus_features'] = ['unicode'],
    );
    final bytes = await model.length();
    expect(profile.backend, 'gpu');
    expect(digest, profile.modelHash);
    expect(bytes, profile.model['bytes']);
    stdout.writeln(jsonEncode({'model_sha256': digest, 'model_bytes': bytes}));
  });

  test(
    'GPU tokenizer decodes fixed split IDs and preserves literal text',
    () async {
      final engine = LlamaEngine(LlamaBackend());
      final validation = PublicValidationEngine(engineFactory: () => engine);
      addTearDown(validation.dispose);
      await validation.load(model.path, profile);
      stdout.writeln(jsonEncode(await checkQwen3Tokenizer(engine)));
      expect(await engine.getBackendName(), 'LiteRT-LM gpu');
    },
  );

  test('GPU first request streams the exact C02 Unicode reply', () async {
    final engine = LlamaEngine(LlamaBackend());
    final validation = PublicValidationEngine(engineFactory: () => engine);
    addTearDown(validation.dispose);
    await validation.load(model.path, profile);
    final prompt = profile.fixtureText('unicode_generation', 'prompt');
    final expected = profile.fixtureText('unicode_generation', 'expected');
    final generation = await validation.generate(
      prompt,
      profile,
      enableThinking: false,
    );
    final backend = await engine.getBackendName();
    stdout.writeln(
      jsonEncode({
        'backend': backend,
        'prompt': prompt,
        'expected': expected,
        ...generation,
      }),
    );
    expect(backend, 'LiteRT-LM gpu');
    expect(generation['thinking'], isEmpty);
    expect(generation['enable_thinking'], isFalse);
    expect(generation['stream_completed'], isTrue);
    expect(generation['completion_order_valid'], isTrue);
    expect(generation['content'], expected);
  });
}
