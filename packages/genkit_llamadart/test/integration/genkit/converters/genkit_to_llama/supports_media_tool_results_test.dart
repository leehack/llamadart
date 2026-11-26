import 'package:genkit/plugin.dart' as genkit;
import 'package:genkit_llamadart/src/integration/genkit/converters/genkit_to_llama.dart';
import 'package:llamadart/llamadart.dart' as llama;
import 'package:test/test.dart';

const _png = 'data:image/png;base64,AQID';
const _wav = 'data:audio/wav;base64,BAUG';

llama.LlamaToolResultContent _convert(
  List<Object?> content, {
  Object? output,
  genkit.Role role = genkit.Role.tool,
}) =>
    toLlamaMessages([
          genkit.Message(
            role: role,
            content: [
              genkit.ToolResponsePart(
                toolResponse: genkit.ToolResponse(
                  ref: 'call-7',
                  name: 'render',
                  output: output,
                  content: content,
                ),
              ),
            ],
          ),
        ]).single.parts.single
        as llama.LlamaToolResultContent;

void main() {
  for (final role in [genkit.Role.tool, genkit.Role.user]) {
    test('mixed text and media keep order, identity and typed content for '
        '${role == genkit.Role.tool ? 'tool' : 'user'}', () {
      final converted = _convert(
        [
          {'text': 'before'},
          {
            'media': {'url': _png, 'contentType': 'image/png'},
          },
          genkit.TextPart(text: 'between'),
          genkit.MediaPart(media: genkit.Media(url: _wav)),
          {
            'media': {'url': '/tmp/photo.jpg'},
            'metadata': {'label': 'file'},
          },
        ],
        output: {'structured': true},
        role: role,
      );

      expect(converted.id, 'call-7');
      expect(converted.name, 'render');
      expect(converted.result, isNull);
      expect(converted.content.map((part) => part.runtimeType), [
        llama.LlamaTextContent,
        llama.LlamaImageContent,
        llama.LlamaTextContent,
        llama.LlamaAudioContent,
        llama.LlamaImageContent,
      ]);
      expect((converted.content[0] as llama.LlamaTextContent).text, 'before');
      expect((converted.content[1] as llama.LlamaImageContent).bytes, [
        1,
        2,
        3,
      ]);
      expect((converted.content[2] as llama.LlamaTextContent).text, 'between');
      expect((converted.content[3] as llama.LlamaAudioContent).bytes, [
        4,
        5,
        6,
      ]);
      expect(
        (converted.content[4] as llama.LlamaImageContent).path,
        '/tmp/photo.jpg',
      );
    });
  }

  test('media-only result needs no text part', () {
    final converted = _convert([
      {
        'media': {'url': _png},
      },
    ]);
    expect(converted.result, isNull);
    expect(converted.content.single, isA<llama.LlamaImageContent>());
  });

  test('a file URL becomes a local path', () {
    final image =
        _convert([
              {
                'media': {
                  'url': 'file:///tmp/a.png',
                  'contentType': 'image/png',
                },
              },
            ]).content.single
            as llama.LlamaImageContent;
    expect(image.path, '/tmp/a.png');
  });

  test('text-only results keep their joined text form', () {
    final converted = _convert([
      {'text': 'one'},
      {'text': 'two'},
    ], output: 'ignored');
    expect(converted.result, 'one\ntwo');
    expect(converted.content, isEmpty);
  });

  const invalid = genkit.StatusCode.invalidArgument;
  const unimplemented = genkit.StatusCode.unimplemented;
  final rejected = <String, (genkit.StatusCode, List<Object?>)>{
    'remote image without a resolver': (
      invalid,
      [
        {
          'media': {
            'url':
                'https://USER:SECRET_SENTINEL@host/PATH?token=TOKEN_SENTINEL',
            'contentType': 'image/png',
          },
        },
      ],
    ),
    'remote audio': (
      unimplemented,
      [
        {
          'media': {
            'url': 'https://host/PATH_SENTINEL.wav?token=TOKEN_SENTINEL',
            'contentType': 'audio/wav',
          },
        },
      ],
    ),
    'remote video by extension': (
      unimplemented,
      [
        {
          'media': {
            'url': 'https://host/PATH_SENTINEL.mp4?token=TOKEN_SENTINEL',
          },
        },
      ],
    ),
    'video data URL': (
      unimplemented,
      [
        {
          'media': {'url': 'data:video/mp4;base64,AQID'},
        },
      ],
    ),
    'PDF data URL': (
      unimplemented,
      [
        {
          'media': {'url': 'data:application/pdf;base64,AQID'},
        },
      ],
    ),
    'unknown media type': (
      unimplemented,
      [
        {
          'media': {'url': '/tmp/PATH_SENTINEL.bin'},
        },
      ],
    ),
    'invalid image data URL': (
      invalid,
      [
        {
          'media': {'url': 'data:image/png;base64,%%%SECRET_SENTINEL'},
        },
      ],
    ),
    'media beside text in one part': (
      unimplemented,
      [
        {
          'text': 'one',
          'media': {'url': _png},
        },
      ],
    ),
    'resource part': (
      unimplemented,
      [
        {
          'resource': {'uri': 'private://SECRET_SENTINEL'},
        },
      ],
    ),
    'media without a URL': (
      unimplemented,
      [
        {
          'media': {'contentType': 'image/png'},
        },
      ],
    ),
  };
  for (final entry in rejected.entries) {
    test('${entry.key} is rejected with its status and no echoed input', () {
      Object? error;
      try {
        _convert([
          {'text': 'first'},
          ...entry.value.$2,
        ]);
      } on genkit.GenkitException catch (e) {
        error = e;
      }
      expect(
        error,
        isA<genkit.GenkitException>().having(
          (e) => e.status,
          'status',
          entry.value.$1,
        ),
      );
      expect(error.toString(), isNot(contains('SENTINEL')));
    });
  }
}
