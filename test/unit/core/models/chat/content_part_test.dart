import 'dart:typed_data';

import 'package:llamadart/src/core/models/chat/content_part.dart';
import 'package:test/test.dart';

void main() {
  test('LlamaTextContent serializes to JSON', () {
    const part = LlamaTextContent('hello');
    expect(part.toJson(), {'type': 'text', 'text': 'hello'});
  });

  test('LlamaThinkingContent serializes to JSON', () {
    const part = LlamaThinkingContent('reasoning');
    expect(part.toJson(), {'type': 'thinking', 'thinking': 'reasoning'});
  });

  test('LlamaVideoContent keeps path and bytes explicit', () {
    expect(const LlamaVideoContent(path: '/tmp/clip.mp4').toJson(), {
      'type': 'input_video',
      'input_video': {'data': '', 'path': '/tmp/clip.mp4'},
    });
    expect(
      LlamaVideoContent(bytes: Uint8List.fromList(<int>[1, 2, 3])).toJson(),
      {
        'type': 'input_video',
        'input_video': {'data': 'AQID'},
      },
    );
  });
}
