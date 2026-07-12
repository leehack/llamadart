import 'package:llamadart/llamadart.dart';

import '../domain/api_server_engine.dart';

/// Adapter that delegates to a real [LlamaEngine].
class LlamaApiServerEngine implements ApiServerEngine {
  /// Wrapped engine instance.
  final LlamaEngine engine;

  /// Creates an adapter around [engine].
  LlamaApiServerEngine(this.engine);

  @override
  bool get isReady => engine.isReady;

  @override
  Future<LlamaChatTemplateResult> chatTemplate(
    List<LlamaChatMessage> messages, {
    bool addAssistant = true,
    List<ToolDefinition>? tools,
    ToolChoice toolChoice = ToolChoice.auto,
    bool parallelToolCalls = false,
    bool enableThinking = false,
  }) {
    return engine.chatTemplate(
      messages,
      addAssistant: addAssistant,
      tools: tools,
      toolChoice: toolChoice,
      parallelToolCalls: parallelToolCalls,
      enableThinking: enableThinking,
    );
  }

  @override
  Stream<LlamaCompletionChunk> create(
    List<LlamaChatMessage> messages, {
    GenerationParams params = const GenerationParams(),
    List<ToolDefinition>? tools,
    ToolChoice? toolChoice,
    bool parallelToolCalls = false,
    bool enableThinking = false,
  }) {
    return engine.create(
      messages,
      params: params,
      tools: tools,
      toolChoice: toolChoice,
      parallelToolCalls: parallelToolCalls,
      enableThinking: enableThinking,
    );
  }

  @override
  Future<int> getTokenCount(String text) {
    return engine.getTokenCount(text);
  }

  @override
  Future<List<double>> embed(String input, {bool normalize = true}) {
    return engine.embed(input, normalize: normalize);
  }

  @override
  Future<List<List<double>>> embedBatch(
    List<String> inputs, {
    bool normalize = true,
  }) {
    return engine.embedBatch(inputs, normalize: normalize);
  }

  @override
  void cancelGeneration() {
    engine.cancelGeneration();
  }
}
