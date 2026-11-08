import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:llamadart/llamadart.dart';

const Map<String, TextToSpeechAdapter> _adapters = {
  'qwen3-tts': Qwen3TtsAdapter(),
  'lfm3-audio': Lfm3AudioTtsAdapter(),
  'soprano': SopranoTtsAdapter(),
};

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('model', abbr: 'm', help: 'Model GGUF path or URL.')
    ..addOption('projector', abbr: 'p', help: 'Projector GGUF path or URL.')
    ..addOption(
      'adapter',
      abbr: 'a',
      allowed: _adapters.keys,
      defaultsTo: 'qwen3-tts',
      help: 'Model family.',
    )
    ..addOption('text', abbr: 't', defaultsTo: 'Hello from llamadart.')
    ..addOption('voice', help: 'Predefined voice; see the listed voices.')
    ..addOption('language', help: 'Language, for models that take one.')
    ..addOption('temperature', help: 'Sampling temperature.')
    ..addOption('out', abbr: 'o', defaultsTo: 'speech.wav')
    ..addFlag('help', abbr: 'h', negatable: false);
  final options = parser.parse(arguments);
  final model = options['model'] as String?;
  final projector = options['projector'] as String?;
  if (options['help'] == true || model == null || projector == null) {
    stdout.writeln(
      'Usage: dart run bin/llamadart_text_to_speech_example.dart '
      '-m <model.gguf> -p <mmproj.gguf> [options]\n${parser.usage}',
    );
    return;
  }

  final TextToSpeechEngine synthesizer;
  try {
    synthesizer = await TextToSpeechEngine.load(
      TextToSpeechModel(
        ModelSource.parse(model),
        projector: ModelSource.parse(projector),
        adapter: _adapters[options['adapter']]!,
      ),
    );
  } on LlamaUnsupportedException catch (error) {
    stderr.writeln('Unsupported: ${error.message}');
    exitCode = 1;
    return;
  }
  StreamSubscription<ProcessSignal>? interrupt;
  try {
    final capabilities = await synthesizer.capabilities;
    stdout.writeln(
      '${synthesizer.adapter.name}: ${capabilities.sampleRateHz} Hz, '
      'voices: ${capabilities.voices.isEmpty ? 'none listed' : capabilities.voices.join(', ')}',
    );
    final temperature = options['temperature'] as String?;
    final task = await synthesizer.synthesize(
      TextToSpeechRequest(
        text: options['text'] as String,
        voice: options['voice'] as String?,
        language: options['language'] as String?,
        temperature: temperature == null ? 0.8 : double.parse(temperature),
        maxFrames: 1024,
      ),
    );
    interrupt = ProcessSignal.sigint.watch().listen((_) => task.cancel());
    task.events.listen((event) {
      if (event is TextToSpeechProgressEvent) {
        stdout.write('\r${event.phase.name}: ${event.framesGenerated} frames');
      }
    });
    final result = await task.result;
    final output = options['out'] as String;
    await File(output).writeAsBytes(result.toWavBytes());
    stdout.writeln('\nWrote ${result.duration} to $output');
  } on LlamaException catch (error) {
    stderr.writeln('\nSynthesis failed or was cancelled: $error');
    exitCode = 1;
  } finally {
    await interrupt?.cancel();
    await synthesizer.dispose();
  }
}
