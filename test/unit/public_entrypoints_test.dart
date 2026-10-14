@TestOn('vm')
library;

import 'dart:mirrors';

import 'package:llamadart/backend.dart';
import 'package:llamadart/llamadart.dart';
import 'package:test/test.dart';

const _appUri = 'package:llamadart/llamadart.dart';
const _backendUri = 'package:llamadart/backend.dart';
const _bindingsUri = 'package:llamadart/llama_cpp_bindings.dart';

const _engineHooks = <String>{
  'backendDecisionCapabilities',
  'backendTextToSpeechCapabilities',
  'cancelTextToSpeechBackend',
  'contextHandle',
  'freeDecisionHeadBackend',
  'loadDecisionHeadBackend',
  'modelHandle',
  'runDecisionBackend',
  'synthesizeTextToSpeechBackend',
};

/// Every top-level name `package:llamadart/llamadart.dart` exports. Adding or
/// removing an app-facing name is a public API change; update this list on
/// purpose.
const _appNames = <String>{
  'BackendPerfContextData',
  'BackendTextToSpeechModel',
  'ChatFormat',
  'ChatParseResult',
  'ChatSession',
  'ChatSessionCompletionExtension',
  'ChatSessionToolLoopExtension',
  'ChatTemplateEngine',
  'ChatTemplateHandler',
  'ChoiceAnswer',
  'ChoiceKey',
  'ChoiceOf',
  'ChoiceQuestion',
  'ComputeDevice',
  'DecisionAnswer',
  'DecisionCapabilities',
  'DecisionEngine',
  'DecisionKey',
  'DecisionModel',
  'DecisionModelInfo',
  'DecisionModelParams',
  'DecisionQuestion',
  'DecisionQuestionType',
  'DecisionRequest',
  'DecisionResult',
  'DecisionResultKeys',
  'DecisionUsage',
  'DefaultModelDownloadManager',
  'DefaultModelResolver',
  'EngineCapabilities',
  'FlashAttention',
  'GeneratedImage',
  'GenerationGrammarTrigger',
  'GenerationParams',
  'GpuBackend',
  'GpuDeviceInfo',
  'GpuDeviceType',
  'GrammarTrigger',
  'GrammarTriggerType',
  'ImageGenerationCapabilities',
  'ImageGenerationCompletion',
  'ImageGenerationCompletionState',
  'ImageGenerationEngine',
  'ImageGenerationEvent',
  'ImageGenerationFinalEvent',
  'ImageGenerationModel',
  'ImageGenerationPhase',
  'ImageGenerationProgressEvent',
  'ImageGenerationRequest',
  'ImageGenerationResult',
  'ImageGenerationSampler',
  'ImageGenerationScheduler',
  'ImageGenerationTask',
  'ImageModelComponent',
  'ImageModelParams',
  'ImageModelRole',
  'KvCacheType',
  'LiteRtLmActivationDataType',
  'LiteRtLmAsrAdapter',
  'LiteRtLmAsrBackend',
  'LiteRtLmAsrModelPreset',
  'LiteRtLmAsrRuntimeConfig',
  'LiteRtLmBackendPreference',
  'LlamaArgumentException',
  'LlamaAudioContent',
  'LlamaAudioFormatException',
  'LlamaBackend',
  'LlamaBackendInitializationException',
  'LlamaChatMessage',
  'LlamaChatOperation',
  'LlamaChatRole',
  'LlamaChatTemplateResult',
  'LlamaCompletion',
  'LlamaCompletionChunk',
  'LlamaCompletionChunkChoice',
  'LlamaCompletionChunkDelta',
  'LlamaCompletionChunkExtension',
  'LlamaCompletionChunkFunction',
  'LlamaCompletionChunkToolCall',
  'LlamaCompletionStreamExtension',
  'LlamaContentPart',
  'LlamaContextException',
  'LlamaDecisionException',
  'LlamaEmbeddingsOperation',
  'LlamaEngine',
  'LlamaEngineCapabilities',
  'LlamaEngineCompletionExtension',
  'LlamaEngineObserver',
  'LlamaException',
  'LlamaFinishReason',
  'LlamaGenerationUsage',
  'LlamaImageContent',
  'LlamaImageGenerationException',
  'LlamaInferenceException',
  'LlamaLogLevel',
  'LlamaLogRecord',
  'LlamaLogger',
  'LlamaLogging',
  'LlamaModel',
  'LlamaModelException',
  'LlamaModelFormatException',
  'LlamaModelLoadOperation',
  'LlamaNextTokenScores',
  'LlamaOperation',
  'LlamaOperationObserver',
  'LlamaOperationResult',
  'LlamaRuntime',
  'LlamaSpeechException',
  'LlamaSpeechTranscriptLimit',
  'LlamaSpeechTranscriptTruncatedException',
  'LlamaStateException',
  'LlamaStructuredOutput',
  'LlamaStructuredOutputStreamExtension',
  'LlamaTextCompletionOperation',
  'LlamaTextContent',
  'LlamaTextToSpeechException',
  'LlamaThinkingContent',
  'LlamaTokenLogprob',
  'LlamaToolCallContent',
  'LlamaToolLoopResult',
  'LlamaToolLoopStopReason',
  'LlamaToolResultContent',
  'LlamaUnsupportedException',
  'LlamaVideoContent',
  'LocalModelFile',
  'LoraAdapterConfig',
  'ModelCacheEntry',
  'ModelCachePlatform',
  'ModelCachePolicy',
  'ModelDownloadCancelToken',
  'ModelDownloadController',
  'ModelDownloadManager',
  'ModelDownloadProgress',
  'ModelDownloadTaskSnapshot',
  'ModelDownloadTaskStage',
  'ModelFileStore',
  'ModelFileType',
  'ModelFormat',
  'ModelLoadOptions',
  'ModelLoadTarget',
  'ModelParams',
  'ModelResolveRequest',
  'ModelResolver',
  'ModelSource',
  'ModelSourceKind',
  'ModelSplitMode',
  'NoulAnswer',
  'NoulKey',
  'NoulQuestion',
  'Qwen3AsrAdapter',
  'Qwen3TtsAdapter',
  'RemoteModelUrl',
  'ScoreAnswer',
  'ScoreKey',
  'ScoreQuestion',
  'SpeculativeDecodingConfig',
  'SpeculativeDecodingStrategy',
  'SpeechAudioBytesInput',
  'SpeechAudioFileInput',
  'SpeechAudioFormat',
  'SpeechAudioInput',
  'SpeechAudioInputKind',
  'SpeechAudioPcmInput',
  'SpeechToTextAdapter',
  'SpeechToTextCapabilities',
  'SpeechToTextCompletion',
  'SpeechToTextCompletionState',
  'SpeechToTextEngine',
  'SpeechToTextEvent',
  'SpeechToTextFinalEvent',
  'SpeechToTextImplementation',
  'SpeechToTextModel',
  'SpeechToTextModelProfile',
  'SpeechToTextPartialEvent',
  'SpeechToTextPromptAdapter',
  'SpeechToTextRequest',
  'SpeechToTextResult',
  'SpeechToTextStreamingSession',
  'SpeechToTextTask',
  'SpeechToTextTranscript',
  'StateLoadResult',
  'TemplateToolCallSerialization',
  'TextToSpeechAdapter',
  'TextToSpeechCapabilities',
  'TextToSpeechCompletion',
  'TextToSpeechCompletionState',
  'TextToSpeechEngine',
  'TextToSpeechEvent',
  'TextToSpeechFinalEvent',
  'TextToSpeechImplementation',
  'TextToSpeechModel',
  'TextToSpeechModelProfile',
  'TextToSpeechProgressEvent',
  'TextToSpeechProgressPhase',
  'TextToSpeechRequest',
  'TextToSpeechResult',
  'TextToSpeechTask',
  'ThinkingBudget',
  'ThrowingModelDownloadManager',
  'ToolChoice',
  'ToolDefinition',
  'ToolParam',
  'ToolParams',
  'TranscriptSegment',
  'TranscriptWord',
  'hasPersistentCacheSensitiveUrlParts',
  'resolveModelContextBatchSizes',
};

void main() {
  late LibraryMirror backendLibrary;
  late Set<String> app;
  late Set<String> backend;
  late Set<String> ffi;

  setUpAll(() async {
    backendLibrary = await _load(_backendUri);
    app = _exportedNames(await _load(_appUri));
    backend = _exportedNames(backendLibrary);
    ffi = _exportedNames(await _load(_bindingsUri));
  });

  test('the app entrypoint exports exactly the pinned names', () {
    expect(app, _appNames);
  });

  test('the app entrypoint exports no ffigen bindings', () {
    expect(ffi, containsAll(['llama_decode', 'llama_batch', 'ggml_type']));
    expect(app.intersection(ffi), isEmpty);
  });

  test('the app entrypoint keeps only the app-facing backend types', () {
    expect(app.where((name) => name.startsWith('Backend')).toSet(), {
      'BackendPerfContextData',
      'BackendTextToSpeechModel',
    });
    expect(app, containsAll(['LlamaBackend', 'StateLoadResult']));
    expect(
      app,
      containsAll([
        'LiteRtLmAsrBackend',
        'LiteRtLmAsrModelPreset',
        'LiteRtLmAsrRuntimeConfig',
        'TemplateToolCallSerialization',
      ]),
    );
    expect(app.where((name) => name.startsWith('LiteRtLmBenchmark')), isEmpty);
    expect(app.intersection(backend), {
      'LlamaBackend',
      'BackendPerfContextData',
      'BackendTextToSpeechModel',
      'StateLoadResult',
    });
  });

  test('the backend entrypoint exports the backend SPI', () {
    expect(backend, {
      'LlamaBackend',
      'BackendAvailability',
      'BackendBatchEmbeddings',
      'BackendChatPromptGeneration',
      'BackendDartLogLevel',
      'BackendDecision',
      'BackendDecisionCapabilities',
      'BackendDecisionHeadInfo',
      'BackendDecisionOutput',
      'BackendDecisionSequence',
      'BackendEmbeddings',
      'BackendEmbeddingsSupport',
      'BackendGenerationCapabilities',
      'BackendGenerationCapabilitiesSupport',
      'BackendGenerationLimitSupport',
      'BackendGpuEnumeration',
      'BackendGrammarConstraintsSupport',
      'BackendLazyGrammarSupport',
      'BackendModelFileTypeDiagnostics',
      'BackendNativeChatGeneration',
      'BackendNextTokenScoring',
      'BackendNextTokenScoringSupport',
      'BackendPerfContextData',
      'BackendPerformanceDiagnostics',
      'BackendPromptSpeechToTextSupport',
      'BackendRuntimeDiagnostics',
      'BackendStatePersistence',
      'BackendStatePersistenceSupport',
      'BackendTextToSpeech',
      'BackendTextToSpeechCapabilities',
      'BackendTextToSpeechModel',
      'BackendTextToSpeechPhase',
      'BackendTextToSpeechProgress',
      'BackendTextToSpeechRequest',
      'BackendTextToSpeechResult',
      'StateLoadResult',
      'LlamaEngineBackendHooks',
      'LiteRtLmBackend',
      'LiteRtLmRuntimeClient',
      'LiteRtLmRuntimeMetrics',
      'LiteRtLmRuntimeResult',
      'LiteRtLmAsrProcessResult',
      'LiteRtLmAsrProcessState',
      'LiteRtLmAsrPushResult',
      'LiteRtLmAsrRuntimeSession',
    });
  });

  test('the engine hooks are extension members a subclass cannot override', () {
    final instanceMembers = reflectClass(
      LlamaEngine,
    ).instanceMembers.keys.map(MirrorSystem.getName).toSet();
    final hookMembers = _exportedMembers(
      backendLibrary,
      'LlamaEngineBackendHooks',
    );

    expect(hookMembers, _engineHooks);
    expect(instanceMembers.intersection(_engineHooks), isEmpty);
  });

  test('LiteRtLmRuntimeClient no longer has the removed members', () {
    final members = reflectClass(
      LiteRtLmRuntimeClient,
    ).instanceMembers.keys.map(MirrorSystem.getName).toSet();

    expect(members, contains('createConversation'));
    expect(
      members.intersection({
        'conversationTokenCount',
        'replaceConversationWithClone',
      }),
      isEmpty,
    );
  });
}

Future<LibraryMirror> _load(String uri) =>
    currentMirrorSystem().isolate.loadUri(Uri.parse(uri));

/// The top-level names [library] exports. The VM mirror system lists an
/// extension as one `Extension.member` entry per member, so those collapse to
/// the extension's name.
Set<String> _exportedNames(LibraryMirror library) =>
    _exportedEntries(library).map((name) => name.split('.').first).toSet();

Set<String> _exportedMembers(LibraryMirror library, String extension) => {
  for (final name in _exportedEntries(library))
    if (name.startsWith('$extension.')) name.substring(extension.length + 1),
};

/// Follows export directives. The VM splits `show A, B` into one combinator
/// per name, so the shown and hidden names of a directive are unioned.
Set<String> _exportedEntries(LibraryMirror library) {
  final names = <String>{
    for (final MapEntry(:key, :value) in library.declarations.entries)
      if (!value.isPrivate) MirrorSystem.getName(key),
  };
  for (final dependency in library.libraryDependencies) {
    if (!dependency.isExport) continue;
    final shown = <String>{};
    final hidden = <String>{};
    for (final combinator in dependency.combinators) {
      (combinator.isShow ? shown : hidden).addAll(
        combinator.identifiers.map(MirrorSystem.getName),
      );
    }
    for (final name in _exportedEntries(dependency.targetLibrary!)) {
      final topLevel = name.split('.').first;
      if ((shown.isEmpty || shown.contains(topLevel)) &&
          !hidden.contains(topLevel)) {
        names.add(name);
      }
    }
  }
  return names;
}
