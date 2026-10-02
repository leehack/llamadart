---
name: llamadart-decision-models
description: >-
  Use when classifying, routing or rating input with llamadart without
  generating text: loading a Laya-style decision model (ModernBERT GGUF plus a
  .safetensors head) with DecisionEngine, asking typed choice, score or yes/no
  questions with DecisionKey, gating on confidence, scoring option letters
  with engine.scoreNextToken on an instruction model, or fine-tuning and
  shipping a custom decision head.
---

# Decision models with llamadart

## Guidelines

- `DecisionEngine` answers typed questions about a state in one encoder pass
  per question, with no text generation. It needs a ModernBERT
  (`modern-bert`) encoder GGUF loaded in a `LlamaEngine`, such as
  `laya-Q8_0.gguf` from `fr0stbit3/laya-gguf`, plus a head file such as
  `laya-head.safetensors`. Loading GGUFs and downloads are covered by the
  llamadart-getting-started skill.
- Load the backbone with `ModelParams(contextSize: 512)`: the head creates its
  own encoder context of `decisions.info.maxTokens` tokens, so a larger engine
  context only wastes memory.
- Probe `DecisionEngine.capabilitiesFor(engine)` after the backbone is loaded
  (before that it reports that a model must be loaded) and show
  `unsupportedReason` when `isSupported` is false.
- Runtimes: native llama.cpp is experimental (validated on macOS Metal and
  CPU); WebGPU needs bridge assets `v0.1.47+` (the default pin includes them);
  LiteRT-LM, native or Web, is unsupported and `DecisionEngine.load` throws
  `LlamaUnsupportedException`.
- `DecisionEngine.load(engine, headPath: ...)` throws
  `LlamaUnsupportedException` for a non-encoder model, `LlamaModelException`
  for an unreadable or mismatched head, and `LlamaStateException` if the model
  is unloaded meanwhile. Pass `configPath:` (Laya's `rl_agent_config.json`)
  only for heads without `laya.config` metadata, such as the official
  `convaiinnovations/laya` `model.safetensors`; heads exported by the training
  notebooks carry it.
- On Web, `headPath` and `configPath` are URLs resolved against the document
  base URL; the model download manager is unavailable there, so pass
  `ModelSource.resolvedUri` instead of a cached file path.
- Prefer typed keys over string ids: build questions with `ChoiceKey.enumOf`,
  `ChoiceKey.of`, `ChoiceKey.labels`, `ScoreKey.of` and `YesNoKey.of`, pass
  `DecisionKey.questionsOf([...])` to `answer`, and read each answer with
  `result.answerOf(key)`. Keep keys as long-lived finals: `answerOf` throws
  `LlamaDecisionException` when the result's question is not the key's own
  question object (a key rebuilt by a getter, or a question parsed from JSON,
  does not match).
- Use string ids with `DecisionQuestion.choice/score/yesNo` or
  `DecisionQuestion.fromJson` when questions are data (Laya's wire format) and
  results leave through `toJson()`; read them with `result.choices`,
  `result.scores` and `result.yesNos`.
- `systemOne`, `systemOneBatch`, `DecisionQuestion.noul`, `NoulQuestion`,
  `NoulAnswer.noul`, `NoulKey` and `result.nouls` are deprecated aliases of
  the names above; JSON keeps Laya's `noul` type.
- Choice and score `confidence` is `1 - H(p) / ln K` (one minus normalized
  entropy), not the top probability; yes/no confidence is
  `max(probability, 1 - probability)`.
  Pick gate thresholds per head and option count on held-out data; the command
  bar example gates Laya at 0.3. Act only above the gate and fall back
  (ask the user, keep the previous state) below it.
- Cost grows with the number of questions: each question re-encodes the
  state. Use `answerBatch([DecisionRequest(...)])` to answer several states
  in one backend call. Calls cannot be cancelled; in interactive UI run at
  most one call and collapse pending inputs into the latest.
- Limits: sequences are cut to 512 tokens and a long state is truncated
  silently; question text and options share `headMaxTokens` (192 for Laya),
  so keep options few and short. Text containing U+0000 throws
  `LlamaDecisionException`. Pass NFC-normalized English text; parity is only
  validated for the English Laya checkpoint.
- Accuracy: `laya-Q8_0.gguf` can flip decisions; use an F32 backbone (or F16
  on Metal) when answers must match Laya.
- Lifecycle: a `DecisionEngine` belongs to the model loaded when it was
  created; unloading or replacing that model frees the head and later calls
  throw `LlamaStateException`. Several decision engines can share one
  backbone (for example a base and a tuned head). Dispose decision engines
  before the `LlamaEngine`.
- Instruction-model alternative: with no trained head, put lettered options in
  a chat-templated prompt and call `engine.scoreNextToken(prompt, candidates:
  letterTokens)`. Check `engine.supportsNextTokenScoring` first (native
  llama.cpp and WebGPU bridge assets `v0.1.52+`; LiteRT-LM and older bridges
  throw `LlamaUnsupportedException`). Verify each letter tokenizes to exactly
  one token, and renormalize the candidate probabilities, which are a softmax
  over the whole vocabulary. Keep the variable input last in the prompt so
  `reusePromptPrefix` (on by default) skips the cached instructions.

## Training a custom head

The encoder stays frozen; only the head is fine-tuned, so an app keeps its
backbone GGUF and swaps a `.safetensors` head. Both Laya examples follow the
same pipeline (Python with `laya`, `torch` and `safetensors`, pinned in each
README):

1. Generate a dataset from Dart: `dart run bin/make_dataset.dart dataset`
   writes `train.jsonl` and `val.jsonl` (the command bar adds `test.jsonl`)
   with `state` and `q` in Laya's request format plus `target` and `h`. The
   command bar can first grow its data with a chat model through
   `bin/generate_commands.dart` and `bin/verify_commands.dart`, then pass
   `--generated verified.jsonl`.
2. Run all cells of `training/laya_head_tuning.ipynb`. Its first cell holds
   the settings, including `OUT_PATH` and `OUT_DTYPE` (`"F32"`, 106 MB, or
   `"F16"`, 53 MB). MPS training is not bit-for-bit repeatable; check the
   printed validation accuracy and change the seed if it is low.
3. The exported head embeds Laya's config as `laya.config` metadata, so load
   it with `DecisionEngine.load(engine, headPath: ...)` and no `configPath`.
   The apps prefer a head copied into their `laya/` cache folder over the
   published one; `bin/bench.dart` scores a head headlessly.

Keep the Dart question text and option labels identical between dataset
generation and inference, since the head is tuned on those exact sequences.

## Examples

Load a backbone and head, ask typed questions and gate on confidence:

```dart
import 'package:llamadart/llamadart.dart';

enum Department { billing, technical, other }

final ChoiceKey<Department> department = ChoiceKey.enumOf<Department>(
  'department',
  'Which department should handle this request?',
  criteria: {
    Department.billing: 'invoices, payments, refunds',
    Department.technical: 'bugs, outages, system errors',
    Department.other: null,
  },
);
final ScoreKey urgency = ScoreKey.of(
  'urgency',
  'How urgent is this request?',
  levels: ['not urgent', 'soon', 'critical'],
);
final YesNoKey refund = YesNoKey.of('refund', 'Does the user request a refund?');

const String repoId = 'fr0stbit3/laya-gguf';
const String revision = 'ce2afdc0a8766af56a29a22dcf4a781e1f5c7d3c';

Future<DecisionEngine> loadDecisions(LlamaEngine engine) async {
  await engine.loadModelSource(
    ModelSource.huggingFace(
      repoId: repoId,
      revision: revision,
      filePath: 'laya-Q8_0.gguf',
    ),
    modelParams: const ModelParams(contextSize: 512),
  );
  final DecisionCapabilities capabilities =
      await DecisionEngine.capabilitiesFor(engine);
  if (!capabilities.isSupported) {
    throw LlamaUnsupportedException(
      capabilities.unsupportedReason ?? 'Decision models are unsupported.',
    );
  }
  final ModelCacheEntry head = await engine.modelDownloadManager.ensureModel(
    ModelSource.huggingFace(
      repoId: repoId,
      revision: revision,
      filePath: 'laya-head.safetensors',
    ),
  );
  return DecisionEngine.load(engine, headPath: head.filePath);
}

Future<Department?> route(DecisionEngine decisions, String ticket) async {
  final DecisionResult result = await decisions.answer(
    state: ticket,
    questions: DecisionKey.questionsOf([department, urgency, refund]),
  );
  final ChoiceOf<Department> choice = result.answerOf(department);
  print(
    'urgency ${result.answerOf(urgency).score}, '
    'refund ${result.answerOf(refund).probability}',
  );
  return choice.confidence >= 0.3 ? choice.value : null;
}

Future<void> main() async {
  final LlamaEngine engine = LlamaEngine(LlamaBackend());
  final DecisionEngine decisions = await loadDecisions(engine);
  try {
    print(await route(decisions, 'We were billed twice for March.'));
  } finally {
    await decisions.dispose();
    await engine.dispose();
  }
}
```

Score option letters with an instruction model instead of a decision head:

```dart
import 'dart:math' as math;

import 'package:llamadart/llamadart.dart';

const List<String> labels = ['reminder', 'search', 'message'];
const String letters = 'ABC';

Future<List<double>> classify(LlamaEngine engine, String text) async {
  if (!engine.supportsNextTokenScoring) {
    throw LlamaUnsupportedException(
      'Next-token scoring is not supported by the active backend.',
    );
  }
  final List<int> letterTokens = [];
  for (final String letter in letters.split('')) {
    final List<int> ids = await engine.tokenize(letter, addSpecial: false);
    if (ids.length != 1) {
      throw StateError('Option letter $letter is not a single token.');
    }
    letterTokens.add(ids.single);
  }
  final StringBuffer question = StringBuffer(
    'Pick the intent of the text. Answer with the letter only.\n',
  );
  for (int i = 0; i < labels.length; i++) {
    question.writeln('(${letters[i]}) ${labels[i]}');
  }
  question.write('Text: $text');

  final LlamaChatTemplateResult template = await engine.chatTemplate([
    LlamaChatMessage.fromText(
      role: LlamaChatRole.user,
      text: question.toString(),
    ),
  ], enableThinking: false);
  final LlamaNextTokenScores scores = await engine.scoreNextToken(
    template.prompt,
    candidates: letterTokens,
  );
  final List<double> raw = [
    for (final LlamaTokenLogprob t in scores.candidates) math.exp(t.logprob),
  ];
  final double total = raw.fold(0, (double a, double b) => a + b);
  return [for (final double p in raw) p / total];
}
```

## More

- Decision models: https://llamadart.leehack.com/docs/guides/decision-models
- Next-token scores: https://llamadart.leehack.com/docs/guides/generation-and-streaming#next-token-scores
- Laya Tetris example: https://llamadart.leehack.com/docs/examples/laya-tetris
- Laya Command Bar example: https://llamadart.leehack.com/docs/examples/laya-command-bar
- Tetris head training: https://github.com/leehack/llamadart/blob/main/example/laya_tetris/training/README.md
- Command bar head training: https://github.com/leehack/llamadart/blob/main/example/laya_command_bar/training/README.md
