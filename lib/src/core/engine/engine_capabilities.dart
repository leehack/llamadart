import '../models/inference/generation_params.dart';
import 'engine_observer.dart';

/// What a `LlamaEngine` and its loaded model support, as the loaded model's
/// runtime reports it.
///
/// Read it with `LlamaEngine.capabilities` after a model loads. A request that
/// uses an input or option reported `false` throws
/// `LlamaUnsupportedException`, except where a field says otherwise. A
/// `false` reported from a native LiteRT-LM bundle's declaration is
/// best-effort: the request is still sent, and fails with
/// `LlamaUnsupportedException` only if the runtime cannot run it. The
/// snapshot does not change when the engine later loads or unloads a model
/// or multimodal projector.
class LlamaEngineCapabilities {
  /// Whether a model is loaded. When false, every other field is false, empty
  /// or null.
  final bool isSupported;

  /// Why [isSupported] is false, or null when it is true.
  final String? unsupportedReason;

  /// The active backend's name, as `LlamaEngine.getBackendName` reports it,
  /// or null when the backend could not report one.
  final String? backendName;

  /// The runtime that runs the loaded model, or null when no model is loaded
  /// or a custom backend does not report it.
  ///
  /// GGUF models run on [LlamaRuntime.llamaCpp], natively or through the
  /// WebGPU bridge on the web.
  final LlamaRuntime? runtime;

  /// Whether chat requests can include image parts.
  ///
  /// llama.cpp needs a loaded multimodal projector that reports vision.
  /// Native LiteRT-LM needs no projector and reports the encoders the bundle
  /// declares. That declaration can under-report: LiteRT-LM's reader matches
  /// section types case-sensitively and its runtime does not, so a bundle
  /// reported without an encoder may still take the media. LiteRT-LM web
  /// takes no media.
  final bool supportsVision;

  /// Whether chat requests can include audio parts, under the same rules as
  /// [supportsVision].
  final bool supportsAudio;

  /// Whether `LlamaEngine.embed` and `embedBatch` are available.
  ///
  /// True on llama.cpp, natively and on WebGPU, and false on LiteRT-LM. A
  /// rank-pooled or encoder-decoder model, or WebGPU bridge assets older than
  /// `v0.1.7`, still throw.
  final bool supportsEmbeddings;

  /// Whether `LlamaEngine.scoreNextToken` is available.
  final bool supportsNextTokenScoring;

  /// Whether the model sees the whole conversation passed to
  /// `LlamaEngine.create`.
  ///
  /// False on LiteRT-LM web, which passes only the latest message's text to
  /// the model; history, tools and the thinking switch do not reach it.
  final bool supportsMultiTurnChat;

  /// Whether tools passed to `LlamaEngine.create` reach the model and its
  /// output is parsed for tool calls.
  ///
  /// False on LiteRT-LM web, which ignores tools. How well a model calls
  /// tools still depends on its chat template. `ToolChoice.required` also
  /// needs [supportsGrammar] for Hermes-style templates, and
  /// [supportsLazyGrammar] for templates whose tool-call grammar waits for a
  /// trigger.
  final bool supportsToolCalling;

  /// Whether a strict `responseFormat` (`json_object` or `json_schema`) is
  /// enforced through grammar-constrained decoding.
  ///
  /// False on LiteRT-LM. WebGPU rejects a strict `responseFormat` combined
  /// with tools, since that needs [supportsLazyGrammar].
  final bool supportsStructuredOutput;

  /// Whether [GenerationParams.grammar], [GenerationParams.grammarTriggers]
  /// and [GenerationParams.preservedTokens] are applied.
  ///
  /// False on LiteRT-LM. WebGPU also rejects a [GenerationParams.grammarRoot]
  /// other than `root`.
  final bool supportsGrammar;

  /// Whether [GenerationParams.grammarLazy] is applied, so a grammar can wait
  /// for a trigger. False on LiteRT-LM and WebGPU.
  final bool supportsLazyGrammar;

  /// Whether a [GenerationParams.penalty] other than its default is applied.
  /// False on LiteRT-LM.
  final bool supportsPenalty;

  /// Whether a non-zero [GenerationParams.presencePenalty] is applied.
  final bool supportsPresencePenalty;

  /// Whether a non-zero [GenerationParams.minP] is applied.
  final bool supportsMinP;

  /// Whether [GenerationParams.thinkingBudget] is applied.
  ///
  /// A runtime that applies it can still reject it for generation with media
  /// parts or speculative decoding.
  final bool supportsThinkingBudget;

  /// Whether [GenerationParams.streamBatchTokenThreshold] and
  /// [GenerationParams.streamBatchByteThreshold] are applied.
  ///
  /// LiteRT-LM web rejects values other than the defaults; WebGPU ignores
  /// them.
  final bool supportsStreamBatching;

  /// The strategies that [GenerationParams.speculativeDecodingConfig] can use.
  ///
  /// [SpeculativeDecodingStrategy.backendDefault] also stands for the
  /// [GenerationParams.speculativeDecoding] flag. Native LiteRT-LM reports
  /// [SpeculativeDecodingStrategy.backendDefault] and
  /// [SpeculativeDecodingStrategy.mtp] unless the bundle declares no
  /// speculative drafter, a declaration that can under-report as for
  /// [supportsVision]. A runtime can still reject a
  /// request that uses only these strategies, such as one that combines
  /// strategies, sets a tuning field or draft model the runtime does not take,
  /// or has media parts, a grammar or a thinking budget.
  final Set<SpeculativeDecodingStrategy> speculativeDecodingStrategies;

  /// Creates a capability snapshot.
  const LlamaEngineCapabilities({
    required this.isSupported,
    this.unsupportedReason,
    this.backendName,
    this.runtime,
    this.supportsVision = false,
    this.supportsAudio = false,
    this.supportsEmbeddings = false,
    this.supportsNextTokenScoring = false,
    this.supportsMultiTurnChat = false,
    this.supportsToolCalling = false,
    this.supportsStructuredOutput = false,
    this.supportsGrammar = false,
    this.supportsLazyGrammar = false,
    this.supportsPenalty = false,
    this.supportsPresencePenalty = false,
    this.supportsMinP = false,
    this.supportsThinkingBudget = false,
    this.supportsStreamBatching = false,
    this.speculativeDecodingStrategies = const <SpeculativeDecodingStrategy>{},
  });
}
