@TestOn('vm')
@Tags(['local-only', 'e2e'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:llamadart/src/backends/litert_lm/litert_lm_bundle_template.dart';
import 'package:llamadart/src/backends/litert_lm/litert_lm_cache.dart';
import 'package:llamadart/src/backends/litert_lm/litert_lm_runtime.dart';
import 'package:test/test.dart';

void main() {
  final model = Platform.environment['LITERT_LM_MODEL'];

  test('the real runtime renders text through the content adapter', () async {
    if (model == null || !File(model).existsSync()) {
      fail('Set LITERT_LM_MODEL to an existing .litertlm model.');
    }
    final bundleTemplate = readLiteRtLmBundleChatTemplate(model);

    final client = LiteRtLmRuntimeClient();
    addTearDown(client.dispose);
    await client.initialize(
      modelPath: model,
      backend: 'cpu',
      maxTokens: 1024,
      cacheDir: liteRtLmNoCacheDirectory,
      speculativeDecoding: false,
    );
    String render(String? template) {
      client.createConversation(
        promptTemplate: template,
        systemMessage: 'Remember the code.',
        messages: const [
          {'role': 'user', 'content': 'The code is cedar17.'},
          {'role': 'assistant', 'content': 'Understood.'},
        ],
      );
      return client.renderMessageToString(liteRtLmContentShapeProbeMessage);
    }

    final rendered = render(null);
    if (bundleTemplate == null) {
      // The runtime builds the template of a bundle that embeds none.
      expect(liteRtLmRendersTextPartsAsList(rendered), isFalse);
      return;
    }
    final adapted = render(liteRtLmTextContentAdapter(bundleTemplate));
    const text = liteRtLmContentShapeProbeText;

    // A template that reads content parts renders the same prompt either way;
    // one that reads a string differs only in each serialized part list.
    expect(liteRtLmRendersTextPartsAsList(adapted), isFalse);
    expect(adapted, contains(text));
    expect(
      adapted,
      rendered.replaceAllMapped(
        RegExp(r'''\[\{(?:"type": "text", )?"text": "([^"]*)"[^\]]*\}\]'''),
        (match) => match[1]!,
      ),
    );
  });
}
