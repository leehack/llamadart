@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('custom bridge repositories require an explicit speech opt-in', () {
    final bootstrap = File('web/index.html').readAsStringSync();

    expect(
      bootstrap,
      contains("bridgeAssetsRepo === 'leehack/llama-web-bridge-assets'"),
    );
    expect(
      bootstrap,
      contains(
        'isOfficialBridgeAssetsRepo &&\n'
        '          bridgeTagSupportsSpeechToText(bridgeAssetsTag)',
      ),
    );
  });
}
