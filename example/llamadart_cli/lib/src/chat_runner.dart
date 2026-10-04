import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:llamadart/llamadart.dart';
import 'package:path/path.dart' as p;

import 'llama_cli_config.dart';
import 'model_locator.dart';

/// Executes the llama.cpp-style chat session lifecycle.
class LlamaCliRunner {
  static const String _llamaPrompt = '> ';

  /// Parsed runtime configuration.
  final LlamaCliConfig config;

  final ModelLocator _modelLocator;
  final List<LlamaChatMessage> _history = <LlamaChatMessage>[];

  LlamaEngine? _engine;
  StreamSubscription<ProcessSignal>? _sigintSubscription;

  bool _isGenerating = false;
  bool _shutdownRequested = false;
  bool _exitPrinted = false;
  int? _effectiveContextSize;
  String? _loadedModelPath;

  bool get _simpleIo => config.simpleIo;

  /// Creates a runner for one CLI invocation.
  LlamaCliRunner(this.config)
    : _modelLocator = ModelLocator(modelsDirectory: config.modelsDirectory);

  /// Starts model resolution, loading, and chat mode.
  Future<void> run() async {
    _registerSigintHandler();

    final modelPath = await _modelLocator.resolve(
      config,
      onStatus: _simpleIo ? null : _printStatus,
      onProgress: _simpleIo ? null : _printDownloadProgress,
    );
    _loadedModelPath = modelPath;

    final backend = LlamaBackend();
    final engine = LlamaEngine(backend);
    _engine = engine;

    await LlamaLogging.configure(nativeLevel: LlamaLogLevel.warn);
    await engine.setModel(
      LlamaModel(ModelSource.path(modelPath)),
      params: ModelParams(
        contextSize: config.contextSize,
        gpuLayers: config.gpuLayers,
        numberOfThreads: config.threads,
        numberOfThreadsBatch: config.threadsBatch,
      ),
    );

    _effectiveContextSize = await _resolveContextSize(engine);

    if (_shutdownRequested) {
      _printExitLine();
      return;
    }

    final generationParams = config.toGenerationParams();
    _printLlamaCliBanner(modelPath);

    final initialPrompt = await _resolveInitialPrompt();
    if (initialPrompt != null) {
      await _runTurn(
        initialPrompt,
        generationParams,
        promptPrefixMode: _PromptPrefixMode.withText,
      );
      if (_shutdownRequested) {
        _printExitLine();
        return;
      }
      if (!config.interactiveFirst && !config.interactive) {
        _printExitLine();
        return;
      }
    }

    if (!config.interactive && !config.interactiveFirst) {
      _printExitLine();
      return;
    }

    if (!stdin.hasTerminal) {
      final pipedInput = await stdin.transform(utf8.decoder).join();
      if (pipedInput.trim().isEmpty) {
        _printExitLine();
        return;
      }

      if (config.interactive || config.interactiveFirst) {
        await _runPipedTurns(pipedInput, generationParams);
      } else {
        final prompt = pipedInput.trim();
        if (prompt.isNotEmpty) {
          await _runTurn(
            prompt,
            generationParams,
            promptPrefixMode: _PromptPrefixMode.withText,
          );
        }
      }
      _printExitLine();
      return;
    }

    await _runInteractiveLoop(generationParams);
    _printExitLine();
  }

  /// Releases model, backend, signal, and network resources.
  Future<void> dispose() async {
    await _sigintSubscription?.cancel();
    _modelLocator.dispose();

    final engine = _engine;
    _engine = null;
    if (engine != null) {
      await engine.dispose();
    }
  }

  void _registerSigintHandler() {
    _sigintSubscription = ProcessSignal.sigint.watch().listen((_) {
      if (_isGenerating) {
        _engine?.cancelGeneration();
        stdout.writeln('\nGeneration cancelled.');
        return;
      }

      _shutdownRequested = true;
      _printExitLine();
    });
  }

  Future<void> _runInteractiveLoop(GenerationParams params) async {
    while (!_shutdownRequested) {
      stdout.write(_llamaPrompt);
      final input = stdin.readLineSync();
      if (input == null) {
        break;
      }

      final trimmed = input.trim();
      if (trimmed.isEmpty) {
        continue;
      }

      if (_isExitInput(trimmed)) {
        break;
      }

      if (trimmed == '/clear' || trimmed == '/reset') {
        _history.clear();
        if (!_simpleIo) {
          stdout.writeln('Conversation cleared.');
        }
        continue;
      }

      if (trimmed == '/regen') {
        await _regenerateLastTurn(params);
        continue;
      }

      if (trimmed.startsWith('/read')) {
        await _runReadCommand(trimmed, params);
        continue;
      }

      if (trimmed == '/model') {
        final loadedModel = _loadedModelPath ?? '(not loaded)';
        stdout.writeln('model: $loadedModel');
        continue;
      }

      if (trimmed == '/params') {
        stdout.writeln(_paramsLine(params));
        continue;
      }

      if (trimmed == '/help') {
        _printInteractiveHelp();
        continue;
      }

      await _runTurn(trimmed, params);
    }
  }

  Future<void> _runTurn(
    String prompt,
    GenerationParams baseParams, {
    _PromptPrefixMode promptPrefixMode = _PromptPrefixMode.none,
  }) async {
    final engine = _engine;
    if (engine == null) {
      throw StateError('Engine is not initialized.');
    }

    if (promptPrefixMode == _PromptPrefixMode.bare) {
      stdout.writeln(_llamaPrompt);
    } else if (promptPrefixMode == _PromptPrefixMode.withText) {
      stdout.writeln('$_llamaPrompt$prompt');
    }

    final userMessage = LlamaChatMessage.fromText(
      role: LlamaChatRole.user,
      text: prompt,
    );
    _history.add(userMessage);

    await _trimHistoryIfNeeded(
      engine,
      requestedMaxTokens: baseParams.maxTokens,
    );
    final messages = _buildMessages();
    final promptTokens = await _countPromptTokens(engine, messages);

    final contextSize = _effectiveContextSize ?? config.contextSize;
    final available = contextSize - promptTokens;

    if (available <= 0) {
      _history.removeLast();
      stderr.writeln(
        'Error: prompt exceeds context window '
        '($promptTokens tokens with --ctx-size $contextSize).',
      );
      return;
    }

    var turnMaxTokens = baseParams.maxTokens;
    if (turnMaxTokens > available) {
      if (!config.fitContext) {
        _history.removeLast();
        stderr.writeln(
          'Error: insufficient context for --predict $turnMaxTokens '
          '(available: $available). Use --fit on or lower --predict.',
        );
        return;
      }

      turnMaxTokens = available;
      if (turnMaxTokens < 1) {
        turnMaxTokens = 1;
      }
      if (!_simpleIo) {
        stdout.writeln('Adjusted --predict to $turnMaxTokens to fit context.');
      }
    }

    final turnParams = baseParams.copyWith(maxTokens: turnMaxTokens);

    _isGenerating = true;
    final assistantText = StringBuffer();
    final assistantThinking = StringBuffer();
    var printedThinkingStart = false;
    try {
      await for (final chunk in engine.create(messages, params: turnParams)) {
        final thinking = chunk.thinking;
        if (thinking.isNotEmpty) {
          if (!printedThinkingStart) {
            stdout.writeln('[Start thinking]');
            printedThinkingStart = true;
          }
          assistantThinking.write(thinking);
          stdout.write(thinking);
        }

        final content = chunk.text;
        if (content.isNotEmpty) {
          assistantText.write(content);
          stdout.write(content);
        }
      }
      stdout.writeln();
      stdout.writeln();
    } finally {
      _isGenerating = false;
    }

    final responseParts = <LlamaContentPart>[];
    if (assistantThinking.isNotEmpty) {
      responseParts.add(LlamaThinkingContent(assistantThinking.toString()));
    }
    if (assistantText.isNotEmpty) {
      responseParts.add(LlamaTextContent(assistantText.toString()));
    }

    if (responseParts.isNotEmpty) {
      _history.add(
        LlamaChatMessage.withContent(
          role: LlamaChatRole.assistant,
          content: responseParts,
        ),
      );
    }
  }

  void _printLlamaCliBanner(String modelPath) {
    final modelName = p.basename(modelPath);
    final buildLabel =
        Platform.environment['LLAMADART_LLAMA_BUILD'] ?? 'b8061-57088276d';

    stdout.writeln();
    stdout.writeln('Loading model... ');
    stdout.writeln();
    stdout.writeln();
    stdout.writeln(
      '██      ██       █████   ███    ███   █████   ██████   █████  ██████  ████████',
    );
    stdout.writeln(
      '██      ██      ██   ██  ████  ████  ██   ██  ██   ██ ██   ██ ██   ██    ██',
    );
    stdout.writeln(
      '██      ██      ███████  ██ ████ ██  ███████  ██   ██ ███████ ██████     ██',
    );
    stdout.writeln(
      '██      ██      ██   ██  ██  ██  ██  ██   ██  ██   ██ ██   ██ ██   ██    ██',
    );
    stdout.writeln(
      '███████ ███████ ██   ██  ██      ██  ██   ██  ██████  ██   ██ ██   ██    ██',
    );
    stdout.writeln('                              L L A M A D A R T');
    stdout.writeln();
    stdout.writeln('build      : $buildLabel');
    stdout.writeln('model      : $modelName');
    stdout.writeln('modalities : text');
    stdout.writeln();
    stdout.writeln('available commands:');
    stdout.writeln('  /exit or Ctrl+C     stop or exit');
    stdout.writeln('  /regen              regenerate the last response');
    stdout.writeln('  /clear              clear the chat history');
    stdout.writeln('  /read               add a text file');
    stdout.writeln();
    stdout.writeln();
  }

  Future<int> _resolveContextSize(LlamaEngine engine) async {
    if (config.contextSize > 0) {
      return config.contextSize;
    }

    final detected = await engine.getContextSize();
    if (detected > 0) {
      return detected;
    }

    return 16384;
  }

  Future<void> _trimHistoryIfNeeded(
    LlamaEngine engine, {
    required int requestedMaxTokens,
  }) async {
    if (!config.fitContext) {
      return;
    }

    final contextSize = _effectiveContextSize ?? config.contextSize;
    if (contextSize <= 0) {
      return;
    }

    final reserve = requestedMaxTokens.clamp(64, 2048);

    while (_history.length > 1) {
      final tokenCount = await _countPromptTokens(engine, _buildMessages());
      if (tokenCount + reserve <= contextSize) {
        break;
      }

      _dropOldestTurn();
    }
  }

  void _dropOldestTurn() {
    if (_history.isEmpty) {
      return;
    }

    _history.removeAt(0);
    if (_history.isNotEmpty && _history.first.role == LlamaChatRole.assistant) {
      _history.removeAt(0);
    }
  }

  List<LlamaChatMessage> _buildMessages() {
    final messages = <LlamaChatMessage>[];

    final systemPrompt = config.systemPrompt?.trim();
    if (systemPrompt != null && systemPrompt.isNotEmpty) {
      messages.add(
        LlamaChatMessage.fromText(
          role: LlamaChatRole.system,
          text: systemPrompt,
        ),
      );
    }

    messages.addAll(
      _history.where((message) => message.role != LlamaChatRole.system),
    );
    return messages;
  }

  Future<int> _countPromptTokens(
    LlamaEngine engine,
    List<LlamaChatMessage> messages,
  ) async {
    final template = await engine.chatTemplate(messages);
    final tokenCount = template.tokenCount;
    if (tokenCount != null) {
      return tokenCount;
    }
    return engine.getTokenCount(template.prompt);
  }

  bool _isExitInput(String value) {
    final normalized = value.toLowerCase();
    return normalized == 'exit' ||
        normalized == 'quit' ||
        normalized == '/exit' ||
        normalized == '/quit';
  }

  void _printInteractiveHelp() {
    if (_simpleIo) {
      return;
    }

    stdout.writeln(
      'Commands:\n'
      '/help  - show command list\n'
      '/regen - regenerate last response\n'
      '/read  - read prompt from file\n'
      '/clear - clear conversation history\n'
      '/reset - alias of /clear\n'
      '/model - print loaded model path\n'
      '/params - print active sampling settings\n'
      '/exit  - quit interactive mode',
    );
  }

  String _paramsLine(GenerationParams params) {
    return 'params: '
        '--ctx-size ${_effectiveContextSize ?? config.contextSize} '
        '--predict ${params.maxTokens} '
        '--temp ${params.temp} '
        '--top-k ${params.topK} '
        '--top-p ${params.topP} '
        '--min-p ${params.minP} '
        '--repeat-penalty ${params.penalty} '
        '--fit ${config.fitContext ? 'on' : 'off'}';
  }

  void _printStatus(String status) {
    if (_simpleIo) {
      return;
    }
    stdout.writeln(status);
  }

  void _printDownloadProgress(DownloadProgress progress) {
    if (_simpleIo) {
      return;
    }

    final receivedMb = progress.receivedBytes / (1024 * 1024);
    final fraction = progress.fraction;
    if (fraction == null || progress.totalBytes == null) {
      stdout.write('\rDownloading... ${receivedMb.toStringAsFixed(1)} MB');
      return;
    }

    final totalMb = progress.totalBytes! / (1024 * 1024);
    final percent = (fraction * 100).toStringAsFixed(1);
    stdout.write(
      '\rDownloading... $percent% '
      '(${receivedMb.toStringAsFixed(1)} / ${totalMb.toStringAsFixed(1)} MB)',
    );

    if (progress.receivedBytes >= progress.totalBytes!) {
      stdout.writeln();
    }
  }

  Future<void> _runPipedTurns(String stdinText, GenerationParams params) async {
    final lines = const LineSplitter().convert(stdinText);
    for (final line in lines) {
      if (_shutdownRequested) {
        break;
      }

      final prompt = line.trim();
      if (prompt.isEmpty) {
        continue;
      }

      stdout.writeln(_llamaPrompt);

      if (_isExitInput(prompt)) {
        break;
      }

      if (prompt == '/clear' || prompt == '/reset') {
        _history.clear();
        continue;
      }

      if (prompt == '/regen') {
        await _regenerateLastTurn(params);
        continue;
      }

      if (prompt.startsWith('/read')) {
        await _runReadCommand(prompt, params);
        continue;
      }

      await _runTurn(prompt, params);
    }
  }

  Future<void> _regenerateLastTurn(GenerationParams params) async {
    if (_history.isEmpty) {
      return;
    }

    if (_history.last.role == LlamaChatRole.assistant) {
      _history.removeLast();
    }

    if (_history.isEmpty || _history.last.role != LlamaChatRole.user) {
      return;
    }

    final prompt = _history.removeLast().content.trim();
    if (prompt.isEmpty) {
      return;
    }

    await _runTurn(prompt, params, promptPrefixMode: _PromptPrefixMode.bare);
  }

  Future<void> _runReadCommand(String input, GenerationParams params) async {
    final spaceIndex = input.indexOf(' ');
    if (spaceIndex == -1) {
      return;
    }

    final path = input.substring(spaceIndex + 1).trim();
    if (path.isEmpty) {
      return;
    }

    final file = File(path);
    if (!file.existsSync()) {
      stderr.writeln('Error: file not found: $path');
      return;
    }

    final prompt = (await file.readAsString()).trim();
    if (prompt.isEmpty) {
      return;
    }

    await _runTurn(prompt, params, promptPrefixMode: _PromptPrefixMode.bare);
  }

  void _printExitLine() {
    if (_exitPrinted) {
      return;
    }

    stdout.writeln();
    stdout.writeln('Exiting...');
    _exitPrinted = true;
  }

  Future<String?> _resolveInitialPrompt() async {
    final inlinePrompt = config.prompt;
    if (inlinePrompt != null && inlinePrompt.trim().isNotEmpty) {
      return inlinePrompt;
    }

    final promptFilePath = config.promptFile;
    if (promptFilePath == null || promptFilePath.trim().isEmpty) {
      return null;
    }

    final file = File(promptFilePath);
    if (!file.existsSync()) {
      throw FileSystemException('Prompt file not found', promptFilePath);
    }

    final text = await file.readAsString();
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return null;
    }

    return trimmed;
  }
}

enum _PromptPrefixMode { none, bare, withText }
