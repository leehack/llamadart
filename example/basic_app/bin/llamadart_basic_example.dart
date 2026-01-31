import 'dart:io';
import 'package:args/args.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_basic_example/services/model_service.dart';
import 'package:llamadart_basic_example/services/llama_service.dart';

const defaultModelUrl =
    'https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf?download=true';

void main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('model',
        abbr: 'm',
        help: 'Path or URL to the GGUF model file.',
        defaultsTo: defaultModelUrl)
    ..addMultiOption('lora',
        abbr: 'l',
        help: 'Path to LoRA adapter(s). Can be specified multiple times.')
    ..addOption('prompt', abbr: 'p', help: 'Prompt for single response mode.')
    ..addFlag('interactive',
        abbr: 'i',
        help: 'Start in interactive conversation mode.',
        defaultsTo: true)
    ..addFlag('help',
        abbr: 'h', help: 'Show this help message.', negatable: false);

  final results = parser.parse(arguments);

  if (results['help'] as bool) {
    print('🦙 llamadart CLI Chat\n');
    print(parser.usage);
    return;
  }

  final modelUrlOrPath = results['model'] as String;
  final singlePrompt = results['prompt'] as String?;
  final isInteractive = results['interactive'] as bool && singlePrompt == null;

  final modelService = ModelService();
  final llamaService = LlamaCliService();

  try {
    print('Checking model...');
    final modelFile = await modelService.ensureModel(modelUrlOrPath);

    final loraPaths = results['lora'] as List<String>;
    final loras = loraPaths.map((p) => LoraAdapterConfig(path: p)).toList();

    print('Initializing engine...');
    await llamaService.init(modelFile.path, loras: loras);
    print('Model loaded successfully.\n');

    if (singlePrompt != null) {
      await _runSingleResponse(llamaService, singlePrompt);
    } else if (isInteractive) {
      await _runInteractiveMode(llamaService);
    }
  } catch (e) {
    print('\nError: $e');
  } finally {
    await llamaService.dispose();
    exit(0);
  }
}

Future<void> _runSingleResponse(LlamaCliService service, String prompt) async {
  print('User: $prompt');
  stdout.write('Assistant: ');
  await for (final token in service.chatStream(prompt)) {
    stdout.write(token);
  }
  print('\n');
}

Future<void> _runInteractiveMode(LlamaCliService service) async {
  print('--- Interactive Mode ---');
  print('Type your message and press Enter. Type "exit" or "quit" to quit.\n');

  while (true) {
    stdout.write('User: ');
    final input = stdin.readLineSync();
    if (input == null ||
        input.toLowerCase() == 'exit' ||
        input.toLowerCase() == 'quit') {
      break;
    }

    if (input.trim().isEmpty) continue;

    stdout.write('Assistant: ');
    await for (final token in service.chatStream(input)) {
      stdout.write(token);
    }
    print('\n');
  }
}
