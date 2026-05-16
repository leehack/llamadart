import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';

enum _ModelKind { text, vision, audio }

class _ModelCase {
  final String id;
  final String name;
  final _ModelKind kind;
  final String modelFileName;
  final String modelUrl;
  final String? mmprojFileName;
  final String? mmprojUrl;
  final int contextSize;
  final bool expectToolCall;
  final bool expectThinking;

  const _ModelCase({
    required this.id,
    required this.name,
    required this.kind,
    required this.modelFileName,
    required this.modelUrl,
    this.mmprojFileName,
    this.mmprojUrl,
    this.contextSize = 4096,
    this.expectToolCall = false,
    this.expectThinking = false,
  });
}

class _ModelResult {
  final String id;
  final String name;
  final String load;
  final String generate;
  final String tool;
  final String thinking;
  final String multimodal;
  final String notes;

  const _ModelResult({
    required this.id,
    required this.name,
    required this.load,
    required this.generate,
    required this.tool,
    required this.thinking,
    required this.multimodal,
    required this.notes,
  });
}

const List<_ModelCase> _recommendedModels = <_ModelCase>[
  _ModelCase(
    id: 'functiongemma-270m',
    name: 'FunctionGemma 270M',
    kind: _ModelKind.text,
    modelFileName: 'functiongemma-270m-it-Q4_K_M.gguf',
    modelUrl:
        'https://huggingface.co/unsloth/functiongemma-270m-it-GGUF/resolve/main/functiongemma-270m-it-Q4_K_M.gguf?download=true',
    expectToolCall: true,
  ),
  _ModelCase(
    id: 'qwen3.5-0.8b-instruct',
    name: 'Qwen3.5 0.8B Instruct',
    kind: _ModelKind.text,
    modelFileName: 'Qwen3.5-0.8B-Q4_K_M.gguf',
    modelUrl:
        'https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/main/Qwen3.5-0.8B-Q4_K_M.gguf?download=true',
    contextSize: 4096,
    expectToolCall: true,
  ),
  _ModelCase(
    id: 'qwen3.5-2b-instruct',
    name: 'Qwen3.5 2B Instruct',
    kind: _ModelKind.text,
    modelFileName: 'Qwen3.5-2B-Q4_K_M.gguf',
    modelUrl:
        'https://huggingface.co/unsloth/Qwen3.5-2B-GGUF/resolve/main/Qwen3.5-2B-Q4_K_M.gguf?download=true',
    contextSize: 8192,
    expectToolCall: true,
  ),
  _ModelCase(
    id: 'llama-3.2-1b-instruct',
    name: 'Llama 3.2 1B Instruct',
    kind: _ModelKind.text,
    modelFileName: 'Llama-3.2-1B-Instruct-Q4_K_M.gguf',
    modelUrl:
        'https://huggingface.co/bartowski/Llama-3.2-1B-Instruct-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf?download=true',
    contextSize: 8192,
    expectToolCall: true,
  ),
  _ModelCase(
    id: 'gemma-3-1b-it',
    name: 'Gemma 3 1B it',
    kind: _ModelKind.text,
    modelFileName: 'gemma-3-1b-it-Q4_K_M.gguf',
    modelUrl:
        'https://huggingface.co/ggml-org/gemma-3-1b-it-GGUF/resolve/main/gemma-3-1b-it-Q4_K_M.gguf?download=true',
    contextSize: 8192,
  ),
  _ModelCase(
    id: 'lfm2.5-1.2b-instruct',
    name: 'LFM2.5 1.2B Instruct',
    kind: _ModelKind.text,
    modelFileName: 'LFM2.5-1.2B-Instruct-Q4_K_M.gguf',
    modelUrl:
        'https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct-GGUF/resolve/main/LFM2.5-1.2B-Instruct-Q4_K_M.gguf?download=true',
    contextSize: 8192,
  ),
  _ModelCase(
    id: 'lfm2.5-1.2b-thinking',
    name: 'LFM2.5 1.2B Thinking',
    kind: _ModelKind.text,
    modelFileName: 'LFM2.5-1.2B-Thinking-Q4_K_M.gguf',
    modelUrl:
        'https://huggingface.co/LiquidAI/LFM2.5-1.2B-Thinking-GGUF/resolve/main/LFM2.5-1.2B-Thinking-Q4_K_M.gguf?download=true',
    contextSize: 16384,
    expectThinking: true,
  ),
  _ModelCase(
    id: 'smolvlm-500m',
    name: 'SmolVLM 500M Instruct',
    kind: _ModelKind.vision,
    modelFileName: 'SmolVLM-500M-Instruct-Q8_0.gguf',
    modelUrl:
        'https://huggingface.co/ggml-org/SmolVLM-500M-Instruct-GGUF/resolve/main/SmolVLM-500M-Instruct-Q8_0.gguf?download=true',
    mmprojFileName: 'mmproj-SmolVLM-500M-Instruct-f16.gguf',
    mmprojUrl:
        'https://huggingface.co/ggml-org/SmolVLM-500M-Instruct-GGUF/resolve/main/mmproj-SmolVLM-500M-Instruct-f16.gguf?download=true',
  ),
  _ModelCase(
    id: 'lfm2-vl-450m',
    name: 'LFM2-VL 450M',
    kind: _ModelKind.vision,
    modelFileName: 'LFM2-VL-450M-Q4_0.gguf',
    modelUrl:
        'https://huggingface.co/LiquidAI/LFM2-VL-450M-GGUF/resolve/main/LFM2-VL-450M-Q4_0.gguf?download=true',
    mmprojFileName: 'mmproj-LFM2-VL-450M-Q8_0.gguf',
    mmprojUrl:
        'https://huggingface.co/LiquidAI/LFM2-VL-450M-GGUF/resolve/main/mmproj-LFM2-VL-450M-Q8_0.gguf?download=true',
    contextSize: 8192,
  ),
  _ModelCase(
    id: 'ultravox-v0.5-1b',
    name: 'Ultravox v0.5 1B',
    kind: _ModelKind.audio,
    modelFileName: 'ultravox-v0.5-1b-q4_k_m.gguf',
    modelUrl:
        'https://huggingface.co/ggml-org/ultravox-v0_5-llama-3_2-1b-GGUF/resolve/main/Llama-3.2-1B-Instruct-Q4_K_M.gguf?download=true',
    mmprojFileName: 'mmproj-ultravox-v0_5-llama-3_2-1b-f16.gguf',
    mmprojUrl:
        'https://huggingface.co/ggml-org/ultravox-v0_5-llama-3_2-1b-GGUF/resolve/main/mmproj-ultravox-v0_5-llama-3_2-1b-f16.gguf?download=true',
    contextSize: 4096,
  ),
  _ModelCase(
    id: 'llama-3.2-3b-instruct',
    name: 'Llama 3.2 3B Instruct',
    kind: _ModelKind.text,
    modelFileName: 'Llama-3.2-3B-Instruct-Q4_K_M.gguf',
    modelUrl:
        'https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF/resolve/main/Llama-3.2-3B-Instruct-Q4_K_M.gguf?download=true',
    contextSize: 8192,
    expectToolCall: true,
  ),
  _ModelCase(
    id: 'qwen3.5-4b-instruct',
    name: 'Qwen3.5 4B Instruct',
    kind: _ModelKind.text,
    modelFileName: 'Qwen3.5-4B-Q4_K_M.gguf',
    modelUrl:
        'https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/main/Qwen3.5-4B-Q4_K_M.gguf?download=true',
    contextSize: 8192,
    expectToolCall: true,
  ),
  _ModelCase(
    id: 'qwen3.5-9b-instruct',
    name: 'Qwen3.5 9B Instruct',
    kind: _ModelKind.text,
    modelFileName: 'Qwen3.5-9B-Q4_K_M.gguf',
    modelUrl:
        'https://huggingface.co/unsloth/Qwen3.5-9B-GGUF/resolve/main/Qwen3.5-9B-Q4_K_M.gguf?download=true',
    contextSize: 8192,
    expectToolCall: true,
  ),
  _ModelCase(
    id: 'meta-llama-3.1-8b-instruct',
    name: 'Meta-Llama 3.1 8B Instruct',
    kind: _ModelKind.text,
    modelFileName: 'Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf',
    modelUrl:
        'https://huggingface.co/bartowski/Meta-Llama-3.1-8B-Instruct-GGUF/resolve/main/Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf?download=true',
    contextSize: 8192,
    expectToolCall: true,
  ),
];

Future<void> main(List<String> args) async {
  final String? filter = args.isEmpty ? null : args.join(' ').toLowerCase();

  final Directory modelsDir = Directory('models');
  if (!modelsDir.existsSync()) {
    modelsDir.createSync(recursive: true);
  }

  final List<_ModelCase> selected = _recommendedModels
      .where((m) {
        if (filter == null) {
          return true;
        }
        return m.id.contains(filter) || m.name.toLowerCase().contains(filter);
      })
      .toList(growable: false);

  if (selected.isEmpty) {
    stdout.writeln('No models matched filter: $filter');
    exitCode = 1;
    return;
  }

  final LlamaBackend backend = LlamaBackend();
  final LlamaEngine engine = LlamaEngine(backend);
  engine.setLogLevel(LlamaLogLevel.warn);

  final List<_ModelResult> results = <_ModelResult>[];

  for (final _ModelCase model in selected) {
    stdout.writeln(
      '\n================================================================',
    );
    stdout.writeln('Testing ${model.name} (${model.id})');
    stdout.writeln('Kind: ${model.kind.name}');
    stdout.writeln(
      '================================================================',
    );

    try {
      final String modelPath = await _ensureFile(
        modelsDir: modelsDir,
        fileName: model.modelFileName,
        downloadUrl: model.modelUrl,
      );

      String? mmprojPath;
      if (model.mmprojFileName != null && model.mmprojUrl != null) {
        mmprojPath = await _ensureFile(
          modelsDir: modelsDir,
          fileName: model.mmprojFileName!,
          downloadUrl: model.mmprojUrl!,
        );
      }

      switch (model.kind) {
        case _ModelKind.text:
          results.add(await _runTextModel(engine, model, modelPath));
        case _ModelKind.vision:
          results.add(
            await _runVisionModel(engine, model, modelPath, mmprojPath!),
          );
        case _ModelKind.audio:
          results.add(
            await _runAudioModel(engine, model, modelPath, mmprojPath!),
          );
      }
    } catch (e) {
      results.add(
        _ModelResult(
          id: model.id,
          name: model.name,
          load: 'FAIL',
          generate: 'FAIL',
          tool: model.expectToolCall ? 'FAIL' : 'N/A',
          thinking: model.expectThinking ? 'FAIL' : 'N/A',
          multimodal: model.kind == _ModelKind.text ? 'N/A' : 'FAIL',
          notes: 'Unhandled error: $e',
        ),
      );
    } finally {
      try {
        await engine.unloadModel();
      } catch (_) {}
    }
  }

  await engine.dispose();
  _printSummary(results);
}

Future<String> _ensureFile({
  required Directory modelsDir,
  required String fileName,
  required String downloadUrl,
}) async {
  final manager = DefaultModelDownloadManager(
    defaultCacheDirectory: modelsDir.path,
  );
  final source = ModelSource.url(Uri.parse(downloadUrl), fileName: fileName);
  stdout.writeln('Ensuring cached model: $fileName');
  final entry = await manager.ensureModel(
    source,
    onProgress: (progress) {
      final total = progress.totalBytes;
      if (total != null &&
          progress.receivedBytes % (32 * 1024 * 1024) < 1024 * 1024) {
        final pct = progress.fraction == null
            ? null
            : (progress.fraction! * 100).toStringAsFixed(1);
        if (pct != null) {
          stdout.write('\r  $fileName $pct%');
        }
      }
    },
  );
  stdout.writeln('\nReady: ${entry.filePath}');
  return entry.filePath;
}

Future<_ModelResult> _runTextModel(
  LlamaEngine engine,
  _ModelCase model,
  String modelPath,
) async {
  await engine
      .loadModel(
        modelPath,
        modelParams: ModelParams(
          contextSize: model.contextSize,
          gpuLayers: 0,
          preferredBackend: GpuBackend.auto,
          numberOfThreads: 4,
          numberOfThreadsBatch: 4,
        ),
      )
      .timeout(const Duration(minutes: 5));

  final _EvalResult smoke = await _evaluateScenario(
    engine: engine,
    messages: <LlamaChatMessage>[
      LlamaChatMessage.fromText(
        role: LlamaChatRole.user,
        text: 'Reply with one short sentence saying hello.',
      ),
    ],
    tools: const <ToolDefinition>[],
    maxTokens: 64,
    enableThinking: false,
  );

  String toolStatus = model.expectToolCall ? 'FAIL' : 'N/A';
  final List<String> debugNotes = <String>[];
  if (model.expectToolCall) {
    final List<ToolDefinition> tools = <ToolDefinition>[
      ToolDefinition(
        name: 'get_weather',
        description: 'Returns current weather for a city',
        parameters: <ToolParam>[
          ToolParam.string('location', description: 'City name'),
        ],
        handler: (ToolParams params) async => 'Sunny',
      ),
    ];

    _EvalResult toolEval = await _evaluateScenario(
      engine: engine,
      messages: <LlamaChatMessage>[
        LlamaChatMessage.fromText(
          role: LlamaChatRole.system,
          text:
              'You must call get_weather for London. Return only a tool call.',
        ),
        LlamaChatMessage.fromText(
          role: LlamaChatRole.user,
          text: 'Check weather in London using the tool.',
        ),
      ],
      tools: tools,
      maxTokens: 160,
      toolChoiceRequired: true,
      enableThinking: false,
    );

    if (!toolEval.hasToolCall) {
      debugNotes.add('toolRaw=${_clip(toolEval.rawText)}');
      toolEval = await _evaluateScenario(
        engine: engine,
        messages: <LlamaChatMessage>[
          LlamaChatMessage.fromText(
            role: LlamaChatRole.system,
            text:
                'You are a strict tool-caller. Output only a get_weather tool call.',
          ),
          LlamaChatMessage.fromText(
            role: LlamaChatRole.user,
            text: 'Call get_weather with location London.',
          ),
        ],
        tools: tools,
        maxTokens: 192,
        toolChoiceRequired: true,
        enableThinking: false,
      );
    }

    if (!toolEval.hasToolCall) {
      final List<ToolDefinition> chatAppStyleTools = <ToolDefinition>[
        ToolDefinition(
          name: 'getWeather',
          description: 'gets the weather for a requested city',
          parameters: <ToolParam>[
            ToolParam.string('city', description: 'City name'),
          ],
          handler: (ToolParams params) async => 'Sunny',
        ),
      ];

      toolEval = await _evaluateScenario(
        engine: engine,
        messages: <LlamaChatMessage>[
          LlamaChatMessage.fromText(
            role: LlamaChatRole.system,
            text:
                'When function declarations are available, call tools only when they are needed. If no tool is needed, answer directly.',
          ),
          LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'hi'),
          LlamaChatMessage.fromText(
            role: LlamaChatRole.assistant,
            text: 'Hello! How can I assist you today?',
          ),
          LlamaChatMessage.fromText(
            role: LlamaChatRole.user,
            text: "how's weather in london?",
          ),
        ],
        tools: chatAppStyleTools,
        maxTokens: 384,
        toolChoiceRequired: false,
        enableThinking: true,
      );
    }

    toolStatus = toolEval.hasToolCall ? 'PASS' : 'FAIL';
    if (!toolEval.hasToolCall) {
      debugNotes.add('toolRetryRaw=${_clip(toolEval.rawText)}');
    }
  }

  String thinkingStatus = model.expectThinking ? 'FAIL' : 'N/A';
  if (model.expectThinking) {
    _EvalResult thinkingEval = await _evaluateScenario(
      engine: engine,
      messages: <LlamaChatMessage>[
        LlamaChatMessage.fromText(
          role: LlamaChatRole.system,
          text:
              'Reason in <think> tags before final answer. Keep answer concise.',
        ),
        LlamaChatMessage.fromText(
          role: LlamaChatRole.user,
          text:
              'A bat and ball cost 1.10 total. Bat costs 1.00 more than ball. What is the ball price?',
        ),
      ],
      tools: const <ToolDefinition>[],
      maxTokens: 128,
      enableThinking: true,
    );

    if (!thinkingEval.hasReasoning) {
      debugNotes.add('thinkRaw=${_clip(thinkingEval.rawText)}');
      thinkingEval = await _evaluateScenario(
        engine: engine,
        messages: <LlamaChatMessage>[
          LlamaChatMessage.fromText(
            role: LlamaChatRole.system,
            text:
                'You must include your reasoning inside <think>...</think> tags.',
          ),
          LlamaChatMessage.fromText(
            role: LlamaChatRole.user,
            text: 'Compute 27 * 14 and show reasoning first.',
          ),
        ],
        tools: const <ToolDefinition>[],
        maxTokens: 128,
        enableThinking: true,
      );
    }

    thinkingStatus = thinkingEval.hasReasoning ? 'PASS' : 'FAIL';
    if (!thinkingEval.hasReasoning) {
      debugNotes.add('thinkRetryRaw=${_clip(thinkingEval.rawText)}');
    }
  }

  final bool hasAnyGeneration =
      smoke.generatedText.isNotEmpty ||
      smoke.hasReasoning ||
      smoke.hasToolCall ||
      smoke.rawText.trim().isNotEmpty;

  return _ModelResult(
    id: model.id,
    name: model.name,
    load: 'PASS',
    generate: hasAnyGeneration ? 'PASS' : 'FAIL',
    tool: toolStatus,
    thinking: thinkingStatus,
    multimodal: 'N/A',
    notes: [
      if (hasAnyGeneration)
        'format=${smoke.formatId}, chars=${smoke.generatedText.length}, raw=${smoke.rawText.length}'
      else
        'No generation output',
      ...debugNotes,
    ].join('; '),
  );
}

String _clip(String input, {int max = 120}) {
  final String normalized = input.replaceAll('\n', r'\n').trim();
  if (normalized.length <= max) {
    return normalized;
  }
  return '${normalized.substring(0, max)}...';
}

Future<_ModelResult> _runVisionModel(
  LlamaEngine engine,
  _ModelCase model,
  String modelPath,
  String mmprojPath,
) async {
  await engine
      .loadModel(
        modelPath,
        modelParams: ModelParams(
          contextSize: model.contextSize,
          gpuLayers: 0,
          preferredBackend: GpuBackend.auto,
          numberOfThreads: 4,
          numberOfThreadsBatch: 4,
        ),
      )
      .timeout(const Duration(minutes: 5));

  await engine
      .loadMultimodalProjector(mmprojPath)
      .timeout(const Duration(minutes: 5));

  final bool supportsVision = await engine.supportsVision;
  final Uint8List tinyPng = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a9qsAAAAASUVORK5CYII=',
  );

  final List<LlamaCompletionChunk> chunks = await engine
      .create(<LlamaChatMessage>[
        LlamaChatMessage.withContent(
          role: LlamaChatRole.user,
          content: <LlamaContentPart>[
            const LlamaTextContent('Describe the image in one short phrase.'),
            LlamaImageContent(bytes: tinyPng, width: 1, height: 1),
          ],
        ),
      ], params: const GenerationParams(maxTokens: 32, temp: 0.2, topP: 0.9))
      .timeout(const Duration(minutes: 3))
      .toList();

  final String text = chunks
      .map((LlamaCompletionChunk c) => c.choices.first.delta.content ?? '')
      .join()
      .trim();

  return _ModelResult(
    id: model.id,
    name: model.name,
    load: 'PASS',
    generate: text.isNotEmpty ? 'PASS' : 'FAIL',
    tool: 'N/A',
    thinking: 'N/A',
    multimodal: supportsVision && text.isNotEmpty ? 'PASS' : 'FAIL',
    notes: 'supportsVision=$supportsVision, chars=${text.length}',
  );
}

Future<_ModelResult> _runAudioModel(
  LlamaEngine engine,
  _ModelCase model,
  String modelPath,
  String mmprojPath,
) async {
  await engine
      .loadModel(
        modelPath,
        modelParams: ModelParams(
          contextSize: model.contextSize,
          gpuLayers: 0,
          preferredBackend: GpuBackend.auto,
          numberOfThreads: 4,
          numberOfThreadsBatch: 4,
        ),
      )
      .timeout(const Duration(minutes: 5));

  await engine
      .loadMultimodalProjector(mmprojPath)
      .timeout(const Duration(minutes: 5));

  final bool supportsAudio = await engine.supportsAudio;
  final Float32List samples = _makeSineWave(sampleRate: 16000, ms: 250);

  final List<LlamaCompletionChunk> chunks = await engine
      .create(<LlamaChatMessage>[
        LlamaChatMessage.withContent(
          role: LlamaChatRole.user,
          content: <LlamaContentPart>[
            const LlamaTextContent('Transcribe this short audio.'),
            LlamaAudioContent(samples: samples),
          ],
        ),
      ], params: const GenerationParams(maxTokens: 48, temp: 0.2, topP: 0.9))
      .timeout(const Duration(minutes: 3))
      .toList();

  final String text = chunks
      .map((LlamaCompletionChunk c) => c.choices.first.delta.content ?? '')
      .join()
      .trim();

  return _ModelResult(
    id: model.id,
    name: model.name,
    load: 'PASS',
    generate: text.isNotEmpty ? 'PASS' : 'FAIL',
    tool: 'N/A',
    thinking: 'N/A',
    multimodal: supportsAudio && text.isNotEmpty ? 'PASS' : 'FAIL',
    notes: 'supportsAudio=$supportsAudio, chars=${text.length}',
  );
}

class _EvalResult {
  final int formatId;
  final String generatedText;
  final String rawText;
  final bool hasToolCall;
  final bool hasReasoning;

  const _EvalResult({
    required this.formatId,
    required this.generatedText,
    required this.rawText,
    required this.hasToolCall,
    required this.hasReasoning,
  });
}

Future<_EvalResult> _evaluateScenario({
  required LlamaEngine engine,
  required List<LlamaChatMessage> messages,
  required List<ToolDefinition> tools,
  required int maxTokens,
  bool toolChoiceRequired = false,
  bool enableThinking = true,
}) async {
  final LlamaChatTemplateResult template = await engine.chatTemplate(
    messages,
    tools: tools.isEmpty ? null : tools,
    toolChoice: toolChoiceRequired ? ToolChoice.required : ToolChoice.auto,
    enableThinking: enableThinking,
  );

  final Stream<String> rawStream = engine.backend
      .generate(
        engine.contextHandle!,
        template.prompt,
        GenerationParams(
          maxTokens: maxTokens,
          temp: 0.0,
          topP: 0.9,
          topK: 40,
          stopSequences: template.additionalStops,
        ),
      )
      .transform(const Utf8Decoder(allowMalformed: true));

  final StringBuffer raw = StringBuffer();
  await for (final String chunk in rawStream) {
    raw.write(chunk);
  }

  final String rawText = raw.toString();
  final parsed = ChatTemplateEngine.parse(template.format, rawText);

  final bool hasFallbackToolCall =
      RegExp(
        r'<tool_call>[\s\S]*?</tool_call>',
        multiLine: true,
        dotAll: true,
      ).hasMatch(rawText) ||
      RegExp(
        r'<start_function_call>[\s\S]*?<end_function_call>',
        multiLine: true,
        dotAll: true,
      ).hasMatch(rawText);

  final bool hasFallbackReasoning = RegExp(
    r'<think>[\s\S]*?</think>',
    multiLine: true,
    dotAll: true,
  ).hasMatch(rawText);

  return _EvalResult(
    formatId: template.format,
    generatedText: parsed.content.trim(),
    rawText: rawText,
    hasToolCall: parsed.hasToolCalls || hasFallbackToolCall,
    hasReasoning: parsed.hasReasoning || hasFallbackReasoning,
  );
}

Float32List _makeSineWave({required int sampleRate, required int ms}) {
  final int sampleCount = ((sampleRate * ms) / 1000).round();
  final Float32List out = Float32List(sampleCount);
  const double hz = 440.0;
  for (int i = 0; i < sampleCount; i++) {
    final double t = i / sampleRate;
    out[i] = (0.2 * math.sin(2.0 * math.pi * hz * t)).toDouble();
  }
  return out;
}

void _printSummary(List<_ModelResult> results) {
  stdout.writeln(
    '\n================================================================',
  );
  stdout.writeln('RECOMMENDED MODEL VERIFICATION SUMMARY');
  stdout.writeln(
    '================================================================',
  );
  stdout.writeln(
    '| ${'Model'.padRight(27)} | ${'Load'.padRight(4)} | ${'Gen'.padRight(4)} | ${'Tool'.padRight(5)} | ${'Think'.padRight(5)} | ${'MM'.padRight(4)} | Notes |',
  );
  stdout.writeln(
    '|${'-' * 29}|${'-' * 6}|${'-' * 6}|${'-' * 7}|${'-' * 7}|${'-' * 6}|-------|',
  );

  for (final _ModelResult r in results) {
    stdout.writeln(
      '| ${r.name.padRight(27)} | ${r.load.padRight(4)} | ${r.generate.padRight(4)} | ${r.tool.padRight(5)} | ${r.thinking.padRight(5)} | ${r.multimodal.padRight(4)} | ${r.notes} |',
    );
  }

  stdout.writeln(
    '================================================================\n',
  );
}
