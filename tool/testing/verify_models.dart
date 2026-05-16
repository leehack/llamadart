import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:llamadart/llamadart.dart';
import 'package:path/path.dart' as path;

class ModelInfo {
  final String name;
  final String category;
  final String fileName;
  final String downloadUrl;
  final double temp;
  final double topP;
  final int topK;
  final int contextSize;

  final int? gpuLayers;
  final String? systemPrompt;

  const ModelInfo({
    required this.name,
    required this.category,
    required this.fileName,
    required this.downloadUrl,
    this.contextSize = 4096,
    this.temp = 0.7,
    this.topP = 0.9,
    this.topK = 40,
    this.gpuLayers,
    this.systemPrompt,
  });
}

final modelMatrix = [
  ModelInfo(
    name: 'Ministral-3-3B-Reasoning',
    category: 'thinking + tool',
    fileName: 'Ministral-3-3B-Reasoning-2512-Q4_K_M.gguf',
    downloadUrl:
        'https://huggingface.co/unsloth/Ministral-3-3B-Reasoning-2512-GGUF/resolve/main/Ministral-3-3B-Reasoning-2512-Q4_K_M.gguf?download=true',
    temp: 0.0,
    contextSize: 4096,
    systemPrompt:
        "You are a reasoning model. You MUST use <think> tags for your internal reasoning process before answering.",
  ),
  ModelInfo(
    name: 'gemma-3n-E4B-it',
    category: 'thinking + tool',
    fileName: 'gemma-3n-E4B-it-Q4_K_M.gguf',
    downloadUrl:
        'https://huggingface.co/unsloth/gemma-3n-E4B-it-GGUF/resolve/main/gemma-3n-E4B-it-Q4_K_M.gguf?download=true',
    temp: 0.0,
    topP: 0.95,
    topK: 64,
    contextSize: 4096,
    systemPrompt:
        'You are a helpful assistant. You MUST use <think> tags for reasoning. When you need to use a tool, output: <tool_call>{"name": "tool_name", "arguments": {"arg": "value"}}</tool_call>',
  ),
  ModelInfo(
    name: 'functiongemma-270m-it',
    category: 'tool',
    fileName: 'functiongemma-270m-it-Q4_K_M.gguf',
    downloadUrl:
        'https://huggingface.co/unsloth/functiongemma-270m-it-GGUF/resolve/main/functiongemma-270m-it-Q4_K_M.gguf?download=true',
    temp: 0.0,
    contextSize: 4096,
    systemPrompt:
        'You are a helpful assistant. To call a function, output: <start_function_call>function_name({"arg": "value"})<end_function_call>',
  ),
  ModelInfo(
    name: 'Llama-3.2-3B-Instruct',
    category: 'tool',
    fileName: 'Llama-3.2-3B-Instruct-Q4_K_M.gguf',
    downloadUrl:
        'https://huggingface.co/unsloth/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf?download=true',
    temp: 0.0,
    contextSize: 4096,
  ),
  ModelInfo(
    name: 'gemma-3-4b-it',
    category: 'thinking + tool',
    fileName: 'gemma-3-4b-it-Q4_K_M.gguf',
    downloadUrl:
        'https://huggingface.co/unsloth/gemma-3-4b-it-GGUF/resolve/main/gemma-3-4b-it-Q4_K_M.gguf?download=true',
    temp: 0.0,
    topP: 0.95,
    topK: 64,
    contextSize: 4096,
    systemPrompt:
        'You are a helpful assistant. You MUST use <think> tags for reasoning. When you need to use a tool, output: <tool_call>{"name": "tool_name", "arguments": {"arg": "value"}}</tool_call>',
  ),
  ModelInfo(
    name: 'Qwen3.5-4B',
    category: 'tool',
    fileName: 'Qwen3.5-4B-Q4_K_M.gguf',
    downloadUrl:
        'https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-Q4_K_M.gguf?download=true',
    temp: 0.7,
    topP: 0.8,
    topK: 20,
    contextSize: 4096,
  ),
  ModelInfo(
    name: 'Phi-4-mini-instruct-reasoning',
    category: 'thinking',
    fileName: 'Phi-4-mini-instruct-Q4_K_M.gguf',
    downloadUrl:
        'https://huggingface.co/unsloth/Phi-4-mini-instruct-GGUF/resolve/main/Phi-4-mini-instruct-Q4_K_M.gguf',
    temp: 0.0,
    gpuLayers: 0,
    contextSize: 4096,
    systemPrompt:
        "You are a reasoning model. You MUST use <thought> tags to think before you answer.",
  ),
  ModelInfo(
    name: 'DeepSeek-R1-Distill-Llama-8B',
    category: 'thinking + tool',
    fileName: 'DeepSeek-R1-Distill-Llama-8B-Q4_K_M.gguf',
    downloadUrl:
        'https://huggingface.co/unsloth/DeepSeek-R1-Distill-Llama-8B-GGUF/resolve/main/DeepSeek-R1-Distill-Llama-8B-Q4_K_M.gguf?download=true',
    temp: 0.0,
    topP: 0.95,
    contextSize: 4096,
    systemPrompt:
        'You are a helpful assistant. When you need to use a tool, output EXACTLY: <tool_call>\n{"name": "tool_name", "arguments": {"arg": "value"}}\n</tool_call>',
  ),
  ModelInfo(
    name: 'DeepSeek-R1-Distill-Qwen-1.5B',
    category: 'thinking + tool',
    fileName: 'DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf',
    downloadUrl:
        'https://huggingface.co/unsloth/DeepSeek-R1-Distill-Qwen-1.5B-GGUF/resolve/main/DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf?download=true',
    temp: 0.0,
    topP: 0.95,
    contextSize: 4096,
    systemPrompt:
        'You are a helpful assistant. When you need to use a tool, output EXACTLY: <tool_call>\n{"name": "tool_name", "arguments": {"arg": "value"}}\n</tool_call>',
  ),
  ModelInfo(
    name: 'LFM2.5-1.2B-Thinking',
    category: 'thinking + tool',
    fileName: 'LFM2.5-1.2B-Thinking-Q4_K_M.gguf',
    downloadUrl:
        'https://huggingface.co/unsloth/LFM2.5-1.2B-Thinking-GGUF/resolve/main/LFM2.5-1.2B-Thinking-Q4_K_M.gguf?download=true',
    temp: 0.0,
    contextSize: 32768,
  ),
];

Future<void> main(List<String> args) async {
  final filter = args.isNotEmpty ? args[0].toLowerCase() : null;
  final backend = LlamaBackend();
  final engine = LlamaEngine(backend);
  engine.setLogLevel(LlamaLogLevel.warn);

  final modelsDir = Directory('models');
  if (!modelsDir.existsSync()) {
    print('Creating models/ directory...');
    modelsDir.createSync();
  }

  final tools = [
    ToolDefinition(
      name: 'get_weather',
      description: 'Get weather in location',
      parameters: [ToolParam.string('location', description: 'City name')],
      handler: (p) async => "Sunny",
    ),
  ];

  final messages = [
    LlamaChatMessage.fromText(
      role: LlamaChatRole.user,
      text:
          "Solve this step by step: A bat and a ball cost \$1.10 in total. The bat costs \$1.00 more than the ball. How much does the ball cost?",
    ),
  ];

  // Specific prompt for tools
  final toolMessages = [
    LlamaChatMessage.fromText(
      role: LlamaChatRole.user,
      text: "Please use the get_weather tool to check the weather in London.",
    ),
  ];

  final results = <VerificationResult>[];

  for (final model in modelMatrix) {
    if (filter != null && !model.name.toLowerCase().contains(filter)) {
      continue;
    }
    final source = ModelSource.url(
      Uri.parse(model.downloadUrl),
      fileName: model.fileName,
    );
    final manager = DefaultModelDownloadManager(
      defaultCacheDirectory: modelsDir.path,
    );
    final cachedEntry = await manager.get(source.cacheKey);
    final legacyFilePath = path.join(modelsDir.path, model.fileName);
    var filePath = cachedEntry?.filePath ?? legacyFilePath;
    final file = File(filePath);

    print('\n================================================================');
    print('TESTING MODEL: ${model.name}');
    print('CATEGORY: ${model.category}');
    print('================================================================');

    if (!file.existsSync()) {
      print(
        cachedEntry == null
            ? 'Model not found at legacy path: $legacyFilePath'
            : 'Model not found at cached path: $filePath',
      );
      print('Downloading...');
      try {
        filePath = await _ensureModel(
          modelsDir: modelsDir,
          fileName: model.fileName,
          downloadUrl: model.downloadUrl,
        );
        print('Download complete.');
      } catch (e) {
        print('FAILED to download model: $e');
        continue;
      }
    } else {
      print(
        cachedEntry == null
            ? 'Model found at legacy path.'
            : 'Model found in package cache.',
      );
    }
    print('FILE: $filePath');

    try {
      print('Loading model...');
      await engine.loadModel(
        filePath,
        modelParams: ModelParams(
          gpuLayers: model.gpuLayers ?? ModelParams.maxGpuLayers,
          preferredBackend: GpuBackend.auto,
          contextSize: model.contextSize,
        ),
      );
    } catch (e) {
      print('FAILED to load model: $e');
      continue;
    }

    bool hasMetadataTemplate = false;
    try {
      final metadata = await engine.getMetadata();
      if (metadata.containsKey('tokenizer.chat_template')) {
        hasMetadataTemplate = true;
      }
    } catch (e) {
      print('Error fetching metadata: $e');
    }

    LlamaChatTemplateResult? templateResult;
    bool passThinking = false;
    bool passTool = false;
    bool toolCallFound = false;
    bool thinkingFound = false;
    String fullThinking = '';
    bool stopTokenPass = true;
    List<String> detectedStops = [];

    try {
      var activeMessages = model.category.contains('tool')
          ? List<LlamaChatMessage>.from(toolMessages)
          : List<LlamaChatMessage>.from(messages);

      if (model.systemPrompt != null) {
        activeMessages.insert(
          0,
          LlamaChatMessage.fromText(
            role: LlamaChatRole.system,
            text: model.systemPrompt!,
          ),
        );
      }

      print(' Inspecting template...');
      templateResult = await engine.chatTemplate(activeMessages, tools: tools);
      print('Template Format: ${templateResult.format}');

      // RETRY LOOP
      for (int attempt = 1; attempt <= 3; attempt++) {
        if (attempt > 1) {
          print('\n--- RETRY ATTEMPT $attempt for ${model.name} ---');
        }
        passThinking = false;
        passTool = false;
        toolCallFound = false;
        thinkingFound = false;
        fullThinking = '';

        print('Generating raw output...');
        final rawStream = engine.backend
            .generate(
              engine.contextHandle!,
              templateResult.prompt,
              GenerationParams(
                temp: model.temp,
                topP: model.topP,
                topK: model.topK,
                stopSequences: templateResult.additionalStops,
              ),
            )
            .transform(const Utf8Decoder(allowMalformed: true));

        final rawBuffer = StringBuffer();
        await for (final chunk in rawStream) {
          rawBuffer.write(chunk);
        }
        print(
          '\n----------------------------------------------------------------',
        );
        print('RAW OUTPUT COMPLETE (${rawBuffer.length} chars)');

        if (!passThinking) {
          print('\n--- RAW OUTPUT BEGIN ---');
          print(rawBuffer.toString());
          print('--- RAW OUTPUT END ---\n');
        }

        print('Parsing raw output...');

        // DETECT STOP TOKENS FROM METADATA
        detectedStops = List<String>.from(templateResult.additionalStops);
        try {
          final meta = await engine.getMetadata();
          final eosIdStr = meta['tokenizer.ggml.eos_token_id'];
          if (eosIdStr != null) {
            final eosId = int.tryParse(eosIdStr);
            if (eosId != null) {
              final eosToken = await engine.detokenize([eosId], special: true);
              if (eosToken.isNotEmpty && !detectedStops.contains(eosToken)) {
                print(' Detected metadata EOS token: "$eosToken"');
                detectedStops.add(eosToken);
              }
            }
          }
        } catch (e) {
          print(' Warning: Could not extract EOS from metadata: $e');
        }

        final parsed = ChatTemplateEngine.parse(
          templateResult.format,
          rawBuffer.toString(),
        );

        // Extract results from the parsed output
        final parsedContent = parsed.content;
        if (parsed.hasReasoning) {
          thinkingFound = true;
          fullThinking = parsed.reasoningContent ?? '';
        }
        if (parsed.hasToolCalls) {
          toolCallFound = true;
          for (final tc in parsed.toolCalls) {
            final name = tc.function?.name;
            final args = tc.function?.arguments;
            print('\n[TOOL CALL] $name($args)');
          }
        }

        print('\n--- ATTEMPT $attempt SUMMARY for ${model.name} ---');
        passThinking = true;
        if (thinkingFound) {
          print(
            'SUCCESS: Thinking content found! (${fullThinking.length} chars)',
          );
        } else if (model.category.contains('thinking')) {
          print('FAIL: Expected thinking content but none found.');
          passThinking = false;
        }

        passTool = true;
        if (toolCallFound) {
          print('SUCCESS: Tool call parsed correctly!');
        } else if (model.category.contains('tool')) {
          print('FAIL: Expected tool call but none found.');
          passTool = false;
        }

        final finalParsed = parsedContent;
        stopTokenPass = true;
        for (final stop in detectedStops) {
          if (finalParsed.contains(stop)) {
            print(
              'FAIL: Leaking stop token detected in parsed output: "$stop"',
            );
            stopTokenPass = false;
          }
        }
        if (stopTokenPass) {
          print('SUCCESS: No leaking stop tokens in final output.');
        }

        if (passThinking && passTool && stopTokenPass) {
          break; // Success!
        }

        if (attempt == 3) {
          print('\n--- FINAL FAILURE FOR ${model.name} after 3 attempts ---');
          print('\n--- RAW CONTENT ---');
          print(rawBuffer.toString());
          print('-------------------\n');
        }
      }
    } catch (e) {
      print('ERROR during test: $e');
      results.add(
        VerificationResult(
          modelName: model.name,
          format: -1,
          thinkingStatus: 'ERROR',
          toolCallStatus: 'ERROR',
          stopStatus: 'ERROR',
          hasTemplate: false,
        ),
      );
    } finally {
      print('Disposing model...');
      await engine.unloadModel();
    }

    results.add(
      VerificationResult(
        modelName: model.name,
        format: templateResult?.format ?? -1,
        thinkingStatus: model.category.contains('thinking')
            ? (thinkingFound ? 'PASS' : 'FAIL')
            : 'N/A',
        toolCallStatus: model.category.contains('tool')
            ? (toolCallFound ? 'PASS' : 'FAIL')
            : 'N/A',
        stopStatus: stopTokenPass ? 'PASS' : 'FAIL',
        hasTemplate: hasMetadataTemplate,
      ),
    );
  }

  await engine.dispose();
  print('\nMatrix testing complete.');

  print('\n================================================================');
  print('VERIFICATION SUMMARY');
  print('================================================================');
  print(
    '| ${"Model".padRight(30)} | ${"Format".padRight(6)} | ${"HasTmpl".padRight(7)} | ${"Think".padRight(5)} | ${"Tool".padRight(5)} | ${"Stop".padRight(5)} |',
  );
  print('|${'-' * 32}|${'-' * 8}|${'-' * 9}|${'-' * 7}|${'-' * 7}|${'-' * 7}|');
  for (final result in results) {
    print(
      '| ${result.modelName.padRight(30)} | ${result.format.toString().padRight(6)} | ${result.hasTemplate.toString().padRight(7)} | ${result.thinkingStatus.padRight(5)} | ${result.toolCallStatus.padRight(5)} | ${result.stopStatus.padRight(5)} |',
    );
  }
  print('================================================================\n');
}

class VerificationResult {
  final String modelName;
  final int format;
  final String thinkingStatus;
  final String toolCallStatus;
  final String stopStatus;
  final bool hasTemplate;

  VerificationResult({
    required this.modelName,
    required this.format,
    required this.thinkingStatus,
    required this.toolCallStatus,
    required this.stopStatus,
    required this.hasTemplate,
  });
}

Future<String> _ensureModel({
  required Directory modelsDir,
  required String fileName,
  required String downloadUrl,
}) async {
  final manager = DefaultModelDownloadManager(
    defaultCacheDirectory: modelsDir.path,
  );
  final entry = await manager.ensureModel(
    ModelSource.url(Uri.parse(downloadUrl), fileName: fileName),
    onProgress: (progress) {
      final fraction = progress.fraction;
      if (fraction != null) {
        stdout.write('\rDownloading: ${(fraction * 100).toStringAsFixed(2)}%');
      }
    },
  );
  print(''); // New line after progress
  return entry.filePath;
}
