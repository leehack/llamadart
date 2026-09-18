import 'dart:convert';
import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';
import 'package:test/test.dart';

// tokenizer.chat_template from the issue #517 pinned Qwen3-ASR GGUF.
const _qwenAsrTemplate =
    r"{% for message in messages %}{{'<|im_start|>' + message['role'] + '\n' + message['content'] + '<|im_end|>' + '\n'}}{% endfor %}{% if add_generation_prompt %}{{ '<|im_start|>assistant\n' }}{% endif %}";

void main() {
  test('Qwen3-ASR renders identical bounded prompts for file, bytes and PCM', () {
    final bytes = Uint8List.fromList(
      List<int>.generate(352078, (i) => i % 256),
    );
    final parts = <LlamaAudioContent>[
      const LlamaAudioContent(path: '/private/audio.wav'),
      LlamaAudioContent(bytes: bytes),
      LlamaAudioContent(samples: Float32List.fromList([0.1, -0.1])),
    ];
    for (final audio in parts) {
      final message = LlamaChatMessage.withContent(
        role: LlamaChatRole.user,
        content: [
          const LlamaTextContent('Transcribe this audio accurately.'),
          audio,
        ],
      );
      final result = ChatTemplateEngine.render(
        templateSource: _qwenAsrTemplate,
        messages: [message],
        metadata: const {},
        enableThinking: false,
      );
      expect(
        result.prompt,
        '<|im_start|>user\nTranscribe this audio accurately.<__media__><|im_end|>\n<|im_start|>assistant\n',
      );
      expect(
        result.prompt,
        isNot(contains(base64Encode(bytes).substring(0, 80))),
      );
      expect(message.parts.last, same(audio));
      expect(audio.bytes, audio == parts[1] ? same(bytes) : isNull);
    }
  });

  test(
    'string templates preserve media order, text, reasoning and tool calls',
    () {
      final message = LlamaChatMessage.withContent(
        role: LlamaChatRole.assistant,
        content: [
          const LlamaTextContent('before'),
          LlamaAudioContent(bytes: Uint8List.fromList([1, 2, 3])),
          const LlamaTextContent('between'),
          const LlamaImageContent(path: '/private/image.png'),
          const LlamaTextContent('after'),
          const LlamaThinkingContent('reason'),
          const LlamaToolCallContent(
            name: 'lookup',
            arguments: {'key': 'value'},
            rawJson: '{"key":"value"}',
          ),
        ],
      );
      final result = ChatTemplateEngine.render(
        templateSource:
            '{{ messages[0].content }}|{{ messages[0].reasoning_content }}|{{ messages[0].tool_calls[0].function.name }}',
        messages: [message],
        metadata: const {},
      );
      expect(
        result.prompt,
        'before<__media__>between<__media__>after|reason|lookup',
      );
      expect(message.parts.whereType<LlamaAudioContent>(), hasLength(1));
      expect(message.parts.whereType<LlamaImageContent>(), hasLength(1));
    },
  );

  test('typed audio templates retain their model-specific wrappers', () {
    const template =
        '{% for part in messages[0].content %}{% if part.type == "text" %}{{ part.text }}{% elif part.type == "audio" %}<audio_start><|audio|><audio_end>{% endif %}{% endfor %}';
    for (final audio in <LlamaAudioContent>[
      const LlamaAudioContent(path: '/private/audio.wav'),
      LlamaAudioContent(bytes: Uint8List.fromList([1, 2, 3])),
    ]) {
      final result = ChatTemplateEngine.render(
        templateSource: template,
        messages: [
          LlamaChatMessage.withContent(
            role: LlamaChatRole.user,
            content: [const LlamaTextContent('listen'), audio],
          ),
        ],
        metadata: const {},
      );
      expect(result.prompt, 'listen<audio_start><__media__><audio_end>');
    }
  });

  test('text-only Qwen3-ASR rendering is unchanged', () {
    final result = ChatTemplateEngine.render(
      templateSource: _qwenAsrTemplate,
      messages: const [
        LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hello'),
      ],
      metadata: const {},
    );
    expect(
      result.prompt,
      '<|im_start|>user\nhello<|im_end|>\n<|im_start|>assistant\n',
    );
  });
}
