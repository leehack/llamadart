import 'package:llamadart/llamadart.dart';

/// Sends a date-dependent ChatML prompt using a fixed session clock.
Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    throw ArgumentError(
      'Usage: dart run bin/llamadart_template_time_example.dart '
      '/path/model.gguf',
    );
  }
  final engine = await LlamaEngine.load(
    LlamaModel(ModelSource.path(arguments.single)),
    params: const LlamaCppModelParams(
      chatTemplate:
          '<|im_start|>system\nToday is '
          "{{ strftime_now('%Y-%m-%d') }}.<|im_end|>\n"
          '{% for message in messages %}<|im_start|>{{ message.role }}\n'
          '{{ message.content }}<|im_end|>\n{% endfor %}'
          '{% if add_generation_prompt %}<|im_start|>assistant\n{% endif %}',
    ),
  );
  try {
    final now = DateTime.utc(2026, 1, 2);
    final session = TemplateTimeChatSession(engine, templateNow: now);
    final reply = await session.send(
      'What date does your system prompt specify?',
      params: const GenerationParams(maxTokens: 64),
    );
    print(reply.text);
  } finally {
    await engine.dispose();
  }
}
