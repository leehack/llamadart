import 'package:llamadart/src/core/template/template_internal_metadata.dart';
import 'package:test/test.dart';

void main() {
  group('chatTemplateKwargsFromMetadata', () {
    test('decodes the stored kwargs object', () {
      expect(
        chatTemplateKwargsFromMetadata({
          internalChatTemplateKwargsMetadataKey: '{"a": 1, "b": "x"}',
        }),
        {'a': 1, 'b': 'x'},
      );
    });

    test('returns an empty map for missing or unreadable kwargs', () {
      expect(chatTemplateKwargsFromMetadata(const {}), isEmpty);
      expect(
        chatTemplateKwargsFromMetadata({
          internalChatTemplateKwargsMetadataKey: '  ',
        }),
        isEmpty,
      );
      expect(
        chatTemplateKwargsFromMetadata({
          internalChatTemplateKwargsMetadataKey: '[1, 2]',
        }),
        isEmpty,
      );
      expect(
        chatTemplateKwargsFromMetadata({
          internalChatTemplateKwargsMetadataKey: '{not json',
        }),
        isEmpty,
      );
    });
  });
}
