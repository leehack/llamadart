part of 'direct_llama_playground_port.dart';

List<DecisionKey<Object?>> _buildDecisionKeysHelper(
  List<SystemOneQuestionSpec> questions,
) {
  final builtKeys = <DecisionKey<Object?>>[];
  for (final spec in questions) {
    switch (spec) {
      case SystemOneChoiceQuestionSpec():
        builtKeys.add(
          ChoiceKey.labels(
            spec.id,
            spec.prompt,
            criteria: <String, Object?>{
              for (final label in spec.labels) label: null,
            },
          ),
        );
      case SystemOneScoreQuestionSpec():
        builtKeys.add(ScoreKey.of(spec.id, spec.prompt, levels: spec.levels));
      case SystemOneNoulQuestionSpec():
        builtKeys.add(NoulKey.of(spec.id, spec.prompt));
    }
  }
  return builtKeys;
}

Future<({int elapsedMs, String modelName, String summary})>
_compareDecisionWithChatLlmHelper({
  required SharedLlamaEngineProvider chatPort,
  required Object normalizedState,
  required List<SystemOneQuestionSpec> questions,
}) async {
  final promptBuf = StringBuffer(
    'Classify the input below by answering every question concisely in JSON.\n'
    'Input:\n$normalizedState\n\nQuestions:\n',
  );
  for (final q in questions) {
    switch (q) {
      case SystemOneChoiceQuestionSpec():
        promptBuf.writeln(
          '- ${q.id}: ${q.prompt} Options: ${q.labels.join(', ')}',
        );
      case SystemOneScoreQuestionSpec():
        promptBuf.writeln(
          '- ${q.id}: ${q.prompt} Scale: ${q.levels.join(', ')}',
        );
      case SystemOneNoulQuestionSpec():
        promptBuf.writeln('- ${q.id}: ${q.prompt} (true/false)');
    }
  }

  late int elapsedMs;
  late String modelName;
  late String summary;
  await chatPort.runExclusiveOnEngine('Decision LLM comparison', (
    LlamaEngine activeEngine,
  ) async {
    final llmOut = StringBuffer();
    final llmWatch = Stopwatch()..start();
    await for (final chunk in activeEngine.create(
      <LlamaChatMessage>[
        LlamaChatMessage.fromText(
          role: LlamaChatRole.user,
          text: promptBuf.toString(),
        ),
      ],
      params: const GenerationParams(
        maxTokens: 160,
        temp: 0.0,
        streamBatchTokenThreshold: 1,
      ),
      enableThinking: false,
      chatTemplateKwargs: const <String, dynamic>{
        'enable_thinking': false,
        'thinking': false,
        'reasoning': false,
      },
    )) {
      llmOut.write(chunk.text);
    }
    llmWatch.stop();
    elapsedMs = math.max(1, llmWatch.elapsedMilliseconds);
    modelName =
        chatPort.runtimeStore.state.activeModelLabel ?? 'Active Chat LLM';
    final rawText = llmOut.toString().trim();
    summary = rawText.length > 180
        ? '${rawText.substring(0, 177)}...'
        : rawText;
  });
  return (elapsedMs: elapsedMs, modelName: modelName, summary: summary);
}

double _cosineSimilarityHelper(List<double> a, List<double> b) {
  final len = math.min(a.length, b.length);
  if (len == 0) {
    return 0.0;
  }
  var dot = 0.0;
  var normA = 0.0;
  var normB = 0.0;
  for (var i = 0; i < len; i++) {
    dot += a[i] * b[i];
    normA += a[i] * a[i];
    normB += b[i] * b[i];
  }
  final denom = math.sqrt(normA) * math.sqrt(normB);
  if (denom <= 0) {
    return 0.0;
  }
  return (dot / denom).clamp(-1.0, 1.0);
}
