@TestOn('vm')
library;

import 'package:llamadart/src/core/models/inference/model_params.dart';
import 'package:test/test.dart';

void main() {
  test('ModelParams preserves all three JS-backed staging settings', () {
    const params = ModelParams();
    expect(params.jsBackedModelStaging, isNull);
    final enabled = params.copyWith(jsBackedModelStaging: true);
    expect(enabled.jsBackedModelStaging, isTrue);
    expect(enabled.copyWith(contextSize: 512).jsBackedModelStaging, isTrue);
    final disabled = enabled.copyWith(jsBackedModelStaging: false);
    expect(disabled.jsBackedModelStaging, isFalse);
    expect(disabled.copyWith().jsBackedModelStaging, isFalse);
    expect(
      disabled.copyWith(clearJsBackedModelStaging: true).jsBackedModelStaging,
      isNull,
    );
  });

  group('ModelParams mem64 fields', () {
    test('default to null', () {
      const params = ModelParams();
      expect(params.preferMemory64, isNull);
      expect(params.modelBytesHint, isNull);
    });

    test('copyWith sets and preserves the fields', () {
      const params = ModelParams();
      final updated = params.copyWith(
        preferMemory64: true,
        modelBytesHint: 1234,
      );
      expect(updated.preferMemory64, isTrue);
      expect(updated.modelBytesHint, 1234);

      // Omitting the fields preserves them.
      final preserved = updated.copyWith(contextSize: 2048);
      expect(preserved.preferMemory64, isTrue);
      expect(preserved.modelBytesHint, 1234);
    });

    test('copyWith clear sentinels reset the fields to null', () {
      final params = const ModelParams().copyWith(
        preferMemory64: false,
        modelBytesHint: 99,
      );
      final cleared = params.copyWith(
        clearPreferMemory64: true,
        clearModelBytesHint: true,
      );
      expect(cleared.preferMemory64, isNull);
      expect(cleared.modelBytesHint, isNull);
    });
  });
}
