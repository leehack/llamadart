import 'dart:io';
import 'package:args/args.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_basic_example/services/model_service.dart';
import 'package:llamadart_basic_example/services/llama_service.dart';

const defaultModelSource =
    'hf://unsloth/Qwen3.5-0.8B-GGUF/Qwen3.5-0.8B-Q4_K_M.gguf';

void main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption(
      'model',
      abbr: 'm',
      help:
          'Local path, HTTP(S) URL, or hf:// Hugging Face source for a GGUF model.',
      defaultsTo: defaultModelSource,
    )
    ..addMultiOption(
      'lora',
      abbr: 'l',
      help: 'Path to LoRA adapter(s). Can be specified multiple times.',
    )
    ..addOption('prompt', abbr: 'p', help: 'Prompt for single response mode.')
    ..addFlag(
      'interactive',
      abbr: 'i',
      help: 'Start in interactive conversation mode.',
      defaultsTo: true,
    )
    ..addFlag(
      'log',
      abbr: 'g',
      help: 'Enable native engine logging output.',
      defaultsTo: false,
    )
    ..addOption(
      'grammar',
      abbr: 'G',
      help:
          'GBNF grammar string for structured output.\n'
          'Example: "root ::= [0-9]+" (only numbers)\n'
          'Example: "root ::= \\"yes\\" | \\"no\\"" (binary choice)',
    )
    ..addFlag(
      'tool-test',
      abbr: 't',
      help: 'Enable a sample "get_weather" tool for testing tool calls.',
      defaultsTo: false,
    )
    ..addOption(
      'temp',
      help: 'Generation temperature (default: 0.7)',
      defaultsTo: '0.7',
    )
    ..addOption('top-k', help: 'Top-k sampling (default: 20)', defaultsTo: '20')
    ..addOption(
      'top-p',
      help: 'Top-p sampling (default: 0.8)',
      defaultsTo: '0.8',
    )
    ..addOption(
      'penalty',
      help: 'Repeat penalty (default: 1.0)',
      defaultsTo: '1.0',
    )
    ..addFlag(
      'help',
      abbr: 'h',
      help: 'Show this help message.',
      negatable: false,
    );

  final results = parser.parse(arguments);

  if (results['help'] as bool) {
    print('🦙 llamadart CLI Chat\n');
    print(parser.usage);
    print('\nUsage Examples:');
    print('  - Structured Numbers: -G \'root ::= [0-9]+\'');
    print('  - Binary Choice:      -G \'root ::= "yes" | "no"\'');
    print(
      '  - List of colors:    -G \'root ::= ("red" | "green" | "blue") (", " ("red" | "green" | "blue"))*\'',
    );
    return;
  }

  final modelUrlOrPath = results['model'] as String;
  final singlePrompt = results['prompt'] as String?;
  final grammar = results['grammar'] as String?;
  final enableToolTest = results['tool-test'] as bool;
  final isInteractive = results['interactive'] as bool && singlePrompt == null;

  final modelService = ModelService();
  final llamaService = LlamaCliService();

  // Define sample tools using ToolDefinition
  final tools = enableToolTest
      ? <ToolDefinition>[
          ToolDefinition(
            name: 'get_weather',
            description: 'Get the current weather for a location.',
            parameters: [
              ToolParam.string(
                'location',
                description: 'The city and state, e.g. San Francisco, CA',
                required: true,
              ),
              ToolParam.enumType(
                'unit',
                values: ['celsius', 'fahrenheit'],
                description: 'The unit of temperature',
              ),
            ],
            handler: (params) async {
              final location = params.getRequiredString('location');
              final unit = params.getString('unit') ?? 'celsius';
              // Mock weather response
              final temp = 22;
              final unitSymbol = unit == 'fahrenheit' ? '°F' : '°C';
              return 'The weather in $location is $temp$unitSymbol and Sunny.';
            },
          ),
        ]
      : null;

  try {
    print('Checking model...');
    final modelFile = await modelService.ensureModel(modelUrlOrPath);

    final loraPaths = results['lora'] as List<String>;
    final loras = loraPaths.map((p) => LoraAdapterConfig(path: p)).toList();
    final enableLog = results['log'] as bool;

    print('Initializing engine...');
    await llamaService.init(
      modelFile.path,
      loras: loras,
      logLevel: enableLog ? LlamaLogLevel.info : LlamaLogLevel.none,
      tools: tools,
    );
    print('Model loaded successfully.\n');

    if (enableToolTest) {
      print(
        '🛠️ Tool test enabled. The model will be forced to use the "get_weather" tool.',
      );
    }

    if (grammar != null) {
      print('📜 Using custom grammar: $grammar');
    }

    final generationParams = GenerationParams(
      grammar: grammar,
      temp: double.tryParse(results['temp'] as String) ?? 0.7,
      topK: int.tryParse(results['top-k'] as String) ?? 20,
      topP: double.tryParse(results['top-p'] as String) ?? 0.8,
      penalty: double.tryParse(results['penalty'] as String) ?? 1.0,
    );

    if (singlePrompt != null) {
      await _runSingleResponse(
        llamaService,
        singlePrompt,
        generationParams,
        toolChoice: enableToolTest ? ToolChoice.required : null,
      );
    } else if (isInteractive) {
      await _runInteractiveMode(
        llamaService,
        generationParams,
        toolChoice: enableToolTest ? ToolChoice.required : null,
      );
    }
  } catch (e) {
    print('\nError: $e');
  } finally {
    // CRITICAL: Always dispose resources to prevent memory leaks and native process hangs
    await llamaService.dispose();
    exit(0);
  }
}

Future<void> _runSingleResponse(
  LlamaCliService service,
  String prompt,
  GenerationParams params, {
  ToolChoice? toolChoice,
}) async {
  stdout.write('\nAssistant: ');
  await for (final token in service.chatStream(
    prompt,
    params: params,
    toolChoice: toolChoice,
  )) {
    stdout.write(token);
  }
  print('\n');
}

Future<void> _runInteractiveMode(
  LlamaCliService service,
  GenerationParams params, {
  ToolChoice? toolChoice,
}) async {
  print('Starting interactive mode. Type "exit" or "quit" to stop.\n');

  while (true) {
    stdout.write('User: ');
    final input = stdin.readLineSync();

    if (input == null ||
        input.toLowerCase() == 'exit' ||
        input.toLowerCase() == 'quit') {
      break;
    }

    stdout.write('Assistant: ');
    await for (final token in service.chatStream(
      input,
      params: params,
      toolChoice: toolChoice,
    )) {
      stdout.write(token);
    }
    print('\n');
  }
}
