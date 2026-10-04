import 'dart:async';

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

    await _engine.setModel(
      LlamaModel(ModelSource.path(modelPath)),
      params: ModelParams(gpuLayers: 99, loras: loras),
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

  /// Sends a message and returns the full response, running any tool calls.
  Future<String> chat(String text, {GenerationParams? params}) async {
    final tools = _tools;
    if (tools == null || tools.isEmpty) {
      return (await _session.send(text, params: params)).text;
    }
    final result = await _session.sendWithTools(
      text,
      tools: tools,
      params: params,
      maxRounds: _maxToolRounds,
    );
    return result.text;
  }

  /// Maximum number of consecutive tool-call rounds to prevent infinite loops.
  static const int _maxToolRounds = 10;

  /// Sends a message and returns a stream of output.
  ///
  /// Without tools, the reply streams token by token. With tools,
  /// [ChatSession.sendWithTools] runs each tool call and feeds its result
  /// back until the model answers or [_maxToolRounds] is reached; the stream
  /// reports each call, result and reply as it is added to the history.
  Stream<String> chatStream(
    String text, {
    GenerationParams? params,
    ToolChoice? toolChoice,
  }) {
    final tools = _tools;
    if (tools == null || tools.isEmpty) {
      return _session.create([
        LlamaTextContent(text),
      ], params: params).textDeltas();
    }

    final output = StreamController<String>();
    _session
        .sendWithTools(
          text,
          tools: tools,
          params: params,
          toolChoice: toolChoice,
          maxRounds: _maxToolRounds,
          onMessageAdded: (message) {
            for (final part in message.parts) {
              switch (part) {
                case LlamaTextContent(:final text)
                    when message.role == LlamaChatRole.assistant:
                  output.add(text);
                case LlamaToolCallContent(:final name, :final rawJson):
                  output.add('\n[tool] $name($rawJson)\n');
                case LlamaToolResultContent(:final result):
                  output.add('[result] $result\n');
                default:
              }
            }
          },
        )
        .then((result) {
          if (result.stopReason != LlamaToolLoopStopReason.completed) {
            output.add('\n[stopped: ${result.stopReason.name}]');
          }
        }, onError: output.addError)
        .whenComplete(output.close);
    return output.stream;
  }

  /// Disposes the underlying engine resources.
  Future<void> dispose() async {
    await _engine.dispose();
  }
}
