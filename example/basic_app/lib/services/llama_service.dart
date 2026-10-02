import 'dart:convert';

import 'package:llamadart/llamadart.dart';

/// Service for interacting with the Llama engine in a CLI environment.
class LlamaCliService {
  final LlamaEngine _engine = LlamaEngine(LlamaBackend());
  late ChatSession _session;
  List<ToolDefinition>? _tools;

  /// Creates a new [LlamaCliService].
  LlamaCliService() {
    _session = ChatSession(_engine);
  }

  /// Initializes the engine with the given [modelPath].
  ///
  /// Optionally provide [tools] to enable tool calling for this session.
  Future<void> init(
    String modelPath, {
    List<LoraAdapterConfig> loras = const [],
    LlamaLogLevel logLevel = LlamaLogLevel.none,
    List<ToolDefinition>? tools,
  }) async {
    // Set log level
    await LlamaLogging.configure(level: logLevel);

    await _engine.loadModel(
      modelPath,
      modelParams: ModelParams(gpuLayers: 99, loras: loras),
    );

    // Store tools for later use
    _tools = tools;

    // Create session with system prompt for tool calling if tools are provided
    _session = ChatSession(
      _engine,
      systemPrompt: tools != null && tools.isNotEmpty
          ? 'You are a helpful assistant. When you need to use a tool, output it in the correct format as specified by the model template.'
          : null,
    );
  }

  /// Sets or updates the tools for this session.
  set tools(List<ToolDefinition>? tools) {
    _tools = tools;
  }

  /// Sends a message and returns the full response.
  Future<String> chat(String text, {GenerationParams? params}) async {
    return _session
        .create([LlamaTextContent(text)], params: params, tools: _tools)
        .text();
  }

  /// Maximum number of consecutive tool-call rounds to prevent infinite loops.
  static const int _maxToolRounds = 10;

  /// Sends a message and returns a stream of tokens.
  ///
  /// This method handles tool calls automatically:
  /// 1. Streams tokens while collecting tool calls in parallel
  /// 2. Executes any tool calls and feeds results back
  /// 3. Repeats until no more tool calls or [_maxToolRounds] is reached
  Stream<String> chatStream(
    String text, {
    GenerationParams? params,
    ToolChoice? toolChoice,
  }) async* {
    // First turn: send the user message
    final userParts = <LlamaContentPart>[LlamaTextContent(text)];
    var isFirstTurn = true;

    for (var round = 0; round < _maxToolRounds; round++) {
      // Stream tokens and collect tool call deltas in parallel
      final toolCallAccumulators = <int, _ToolCallAccumulator>{};
      await for (final chunk in _session.create(
        isFirstTurn ? userParts : const <LlamaContentPart>[],
        params: params,
        tools: _tools,
        toolChoice: isFirstTurn ? toolChoice : null,
      )) {
        if (chunk.text.isNotEmpty) {
          yield chunk.text;
        }

        for (final call in chunk.toolCalls) {
          final accumulator = toolCallAccumulators.putIfAbsent(
            call.index,
            _ToolCallAccumulator.new,
          );
          if (call.id != null) {
            accumulator.id = call.id;
          }
          final function = call.function;
          if (function?.name != null) {
            accumulator.name = function!.name;
          }
          if (function?.arguments != null) {
            accumulator.arguments.write(function!.arguments);
          }
        }
      }
      isFirstTurn = false;

      // No tool calls means generation is complete
      if (toolCallAccumulators.isEmpty || _tools == null || _tools!.isEmpty) {
        return;
      }

      // Execute each tool call and add results to the session
      final sortedIndices = toolCallAccumulators.keys.toList()..sort();
      for (final index in sortedIndices) {
        final call = toolCallAccumulators[index]!;
        final functionName = call.name;
        if (functionName == null || functionName.isEmpty) {
          const errorResult = 'Error: Tool call missing function name.';
          yield '\n[tool] unknown_tool(invalid payload)\n';
          yield '[result] $errorResult\n';
          _addToolResultMessage(
            id: call.id,
            name: 'unknown_tool',
            result: errorResult,
          );
          continue;
        }

        final tool = _findToolByName(functionName);
        if (tool == null) {
          final errorResult = 'Error: Unknown tool: $functionName';
          yield '\n[tool] $functionName(unknown tool)\n';
          yield '[result] $errorResult\n';
          _addToolResultMessage(
            id: call.id,
            name: functionName,
            result: errorResult,
          );
          continue;
        }

        final argsJson = call.arguments.toString();
        Map<String, dynamic> args;
        try {
          args = _decodeToolArgs(argsJson);
        } on FormatException catch (e) {
          final errorResult =
              'Error: Invalid arguments for $functionName: ${e.message}';
          yield '\n[tool] $functionName(invalid arguments)\n';
          yield '[result] $errorResult\n';
          _addToolResultMessage(
            id: call.id,
            name: functionName,
            result: errorResult,
          );
          continue;
        }

        yield '\n[tool] $functionName(${_formatToolArgs(args)})\n';

        Object? result;
        try {
          result = await tool.invoke(args);
        } catch (e) {
          result = 'Error: Tool execution failed for $functionName: $e';
        }

        yield '[result] $result\n';
        _addToolResultMessage(id: call.id, name: functionName, result: result);
      }
    }
  }

  ToolDefinition? _findToolByName(String name) {
    final tools = _tools;
    if (tools == null) {
      return null;
    }

    for (final tool in tools) {
      if (tool.name == name) {
        return tool;
      }
    }
    return null;
  }

  Map<String, dynamic> _decodeToolArgs(String argsJson) {
    final trimmed = argsJson.trim();
    if (trimmed.isEmpty) {
      return <String, dynamic>{};
    }

    final decoded = jsonDecode(trimmed);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    if (decoded is Map) {
      return decoded.map((key, value) => MapEntry(key.toString(), value));
    }

    throw const FormatException('arguments must be a JSON object');
  }

  String _formatToolArgs(Map<String, dynamic> args) {
    if (args.isEmpty) {
      return '';
    }

    return args.entries
        .map((entry) => '${entry.key}: ${entry.value}')
        .join(', ');
  }

  void _addToolResultMessage({
    required String? id,
    required String name,
    required Object? result,
  }) {
    _session.addMessage(
      LlamaChatMessage.withContent(
        role: LlamaChatRole.tool,
        content: [LlamaToolResultContent(id: id, name: name, result: result)],
      ),
    );
  }

  /// Disposes the underlying engine resources.
  Future<void> dispose() async {
    await _engine.dispose();
  }
}

class _ToolCallAccumulator {
  String? id;
  String? name;
  final StringBuffer arguments = StringBuffer();
}
