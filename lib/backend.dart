/// The service-provider interface for custom llamadart backends.
///
/// Import this library next to `package:llamadart/llamadart.dart` to:
///
/// * implement a custom [LlamaBackend], or fake one in tests, through the
///   optional `Backend*` interfaces such as [BackendTextToSpeech] and
///   [BackendDecision];
/// * drive the LiteRT-LM runtime directly through [LiteRtLmBackend] and
///   [LiteRtLmRuntimeClient];
/// * call the low-level [LlamaEngineBackendHooks] that `TextToSpeechEngine`
///   and `DecisionEngine` build on.
///
/// Apps that only load models and generate need just
/// `package:llamadart/llamadart.dart`. This library follows the package's
/// semantic versioning.
///
/// ```dart
/// import 'package:llamadart/backend.dart';
/// import 'package:llamadart/llamadart.dart';
///
/// final class FakeSpeechBackend implements LlamaBackend, BackendTextToSpeech {
///   // ...
/// }
/// ```
library;

export 'src/backends/backend.dart'
    show
        LlamaBackend,
        BackendAvailability,
        BackendBatchEmbeddings,
        BackendChatPromptGeneration,
        BackendDartLogLevel,
        BackendDecision,
        BackendDecisionCapabilities,
        BackendDecisionHeadInfo,
        BackendDecisionOutput,
        BackendDecisionSequence,
        BackendEmbeddings,
        BackendEmbeddingsSupport,
        BackendGenerationCapabilities,
        BackendGenerationCapabilitiesSupport,
        BackendGenerationLimitSupport,
        BackendGpuEnumeration,
        BackendGrammarConstraintsSupport,
        BackendLazyGrammarSupport,
        BackendModelFileTypeDiagnostics,
        BackendNativeChatGeneration,
        BackendNextTokenScoring,
        BackendNextTokenScoringSupport,
        BackendPerfContextData,
        BackendPerformanceDiagnostics,
        BackendPromptSpeechToTextSupport,
        BackendRuntimeDiagnostics,
        BackendStatePersistence,
        BackendStatePersistenceSupport,
        BackendTextToSpeech,
        BackendTextToSpeechCapabilities,
        BackendTextToSpeechModel,
        BackendTextToSpeechPhase,
        BackendTextToSpeechProgress,
        BackendTextToSpeechRequest,
        BackendTextToSpeechResult,
        StateLoadResult;
export 'src/core/engine/engine.dart' show LlamaEngineBackendHooks;

// LiteRT-LM runtime
export 'src/backends/litert_lm/litert_lm_backend_stub.dart'
    if (dart.library.js_interop) 'src/backends/litert_lm/litert_lm_backend_web.dart'
    if (dart.library.io) 'src/backends/litert_lm/litert_lm_backend.dart'
    show LiteRtLmBackend;
export 'src/backends/litert_lm/litert_lm_runtime_stub.dart'
    if (dart.library.io) 'src/backends/litert_lm/litert_lm_runtime.dart'
    show
        LiteRtLmRuntimeClient,
        LiteRtLmRuntimeMetrics,
        LiteRtLmRuntimeResult,
        LiteRtLmAsrProcessResult,
        LiteRtLmAsrProcessState,
        LiteRtLmAsrPushResult,
        LiteRtLmAsrRuntimeSession;
