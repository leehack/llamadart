import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as path;

const _litertLmVersion = '0.12.0';
const _litertLmLibDirEnv = 'LLAMADART_LITERT_LM_LIB_DIR';
const _liteRtLmIosNativeAsset = 'package:llamadart/litert_lm_LiteRtLm';
const _streamProxyIosNativeAsset = 'package:llamadart/litert_lm_StreamProxy';

/// Builds a diagnostic for LiteRT-LM engine creation failures.
///
/// This is public only for unit tests; production callers should receive the
/// message through [LiteRtLmRuntimeClient.initialize].
String liteRtLmEngineCreateFailureMessage({
  required String backend,
  required String modelPath,
}) {
  final modelName = path.basename(modelPath);
  final displayName = modelName.isEmpty ? modelPath : modelName;
  final normalizedBackend = backend.toLowerCase();
  final hint = switch (normalizedBackend) {
    'npu' =>
      'The Android NPU delegate may not support this device, OS, model, or '
          'bundle; try backend "gpu" or backend "cpu".',
    'gpu' =>
      'The GPU delegate may not support this device, OS, model, or bundle; '
          'try backend "cpu".',
    'cpu' => 'Verify the LiteRT-LM bundle and native runtime libraries.',
    _ =>
      'Verify the backend name, LiteRT-LM bundle, and native runtime '
          'libraries.',
  };
  return 'LiteRT-LM engine creation failed for backend "$backend" and model '
      '"$displayName". $hint';
}

/// Internal helper used by the LiteRT-LM runtime to locate extracted macOS
/// native-assets cache directories.
List<String> liteRtLmMacOsCacheDirectoryCandidatesForAbi(Abi abi) {
  final arch = switch (abi) {
    Abi.macosArm64 => 'arm64',
    Abi.macosX64 => 'x64',
    _ => null,
  };
  if (arch == null) {
    return const <String>[];
  }
  return <String>['macos_$arch', 'macos/$arch'];
}

/// Internal helper used by the LiteRT-LM runtime to validate extracted macOS
/// native-assets cache directories.
List<String> liteRtLmMacOsRequiredLibrariesForAbi(Abi abi) {
  return switch (abi) {
    Abi.macosArm64 => const <String>[
      'libGemmaModelConstraintProvider.dylib',
      'libLiteRt.dylib',
      'libLiteRtLm.dylib',
      'libLiteRtMetalAccelerator.dylib',
      'libLiteRtTopKMetalSampler.dylib',
      'libLiteRtTopKWebGpuSampler.dylib',
      'libLiteRtWebGpuAccelerator.dylib',
      'libStreamProxy.dylib',
    ],
    Abi.macosX64 => const <String>['libLiteRtLm.dylib', 'libStreamProxy.dylib'],
    _ => const <String>[],
  };
}

/// Internal helper used by the LiteRT-LM runtime to locate extracted
/// native-assets cache directories.
List<String> liteRtLmCacheDirectoryCandidatesForAbi(Abi abi) {
  return switch (abi) {
    Abi.macosArm64 => liteRtLmMacOsCacheDirectoryCandidatesForAbi(abi),
    Abi.macosX64 => liteRtLmMacOsCacheDirectoryCandidatesForAbi(abi),
    Abi.linuxArm64 => const <String>['linux/arm64', 'linux_arm64'],
    Abi.linuxX64 => const <String>['linux/x64', 'linux_x64'],
    Abi.windowsX64 => const <String>['windows/x64', 'windows_x64'],
    _ => const <String>[],
  };
}

/// Internal helper used by the LiteRT-LM runtime to locate iOS native assets.
List<String> liteRtLmIosLibraryCandidatesForAbi(Abi abi) {
  return switch (abi) {
    Abi.iosArm64 ||
    Abi.iosX64 => const <String>[_liteRtLmIosNativeAsset, 'libLiteRtLm.dylib'],
    _ => const <String>[],
  };
}

/// Internal helper used by the LiteRT-LM runtime to locate iOS StreamProxy.
List<String> liteRtLmIosStreamProxyCandidatesForAbi(Abi abi) {
  return switch (abi) {
    Abi.iosArm64 || Abi.iosX64 => const <String>[
      _streamProxyIosNativeAsset,
      'libStreamProxy.dylib',
    ],
    _ => const <String>[],
  };
}

/// Internal helper used by the LiteRT-LM runtime to validate extracted
/// native-assets cache directories.
List<String> liteRtLmRequiredLibrariesForAbi(Abi abi) {
  return switch (abi) {
    Abi.macosArm64 => liteRtLmMacOsRequiredLibrariesForAbi(abi),
    Abi.macosX64 => liteRtLmMacOsRequiredLibrariesForAbi(abi),
    Abi.linuxArm64 => const <String>[
      'libGemmaModelConstraintProvider.so',
      'libLiteRt.so',
      'libLiteRtLm.so',
      'libLiteRtTopKWebGpuSampler.so',
      'libLiteRtWebGpuAccelerator.so',
      'libStreamProxy.so',
    ],
    Abi.linuxX64 => const <String>[
      'libGemmaModelConstraintProvider.so',
      'libLiteRt.so',
      'libLiteRtLm.so',
      'libLiteRtTopKWebGpuSampler.so',
      'libLiteRtWebGpuAccelerator.so',
      'libStreamProxy.so',
    ],
    Abi.windowsX64 => const <String>[
      'LiteRtLm.dll',
      'StreamProxy.dll',
      'libGemmaModelConstraintProvider.dll',
      'libLiteRt.dll',
      'libLiteRtTopKWebGpuSampler.dll',
      'libLiteRtWebGpuAccelerator.dll',
    ],
    _ => const <String>[],
  };
}

/// Internal helper used by the LiteRT-LM runtime to validate macOS app
/// framework directories.
List<String> liteRtLmMacOsRequiredFrameworksForAbi(Abi abi) {
  return switch (abi) {
    Abi.macosArm64 => const <String>[
      'GemmaModelConstraintProvider.framework/Versions/A/'
          'GemmaModelConstraintProvider',
      'LiteRt.framework/Versions/A/LiteRt',
      'LiteRtLm.framework/Versions/A/LiteRtLm',
      'LiteRtMetalAccelerator.framework/Versions/A/'
          'LiteRtMetalAccelerator',
      'LiteRtTopKMetalSampler.framework/Versions/A/'
          'LiteRtTopKMetalSampler',
      'LiteRtTopKWebGpuSampler.framework/Versions/A/'
          'LiteRtTopKWebGpuSampler',
      'LiteRtWebGpuAccelerator.framework/Versions/A/'
          'LiteRtWebGpuAccelerator',
      'StreamProxy.framework/Versions/A/StreamProxy',
    ],
    Abi.macosX64 => const <String>[
      'LiteRtLm.framework/Versions/A/LiteRtLm',
      'StreamProxy.framework/Versions/A/StreamProxy',
    ],
    _ => const <String>[],
  };
}

/// Internal helper used by the LiteRT-LM runtime to validate extracted macOS
/// native-assets cache directories.
bool liteRtLmIsMacOsCacheDirectoryForAbi(Directory dir, Abi abi) {
  final requiredLibraries = liteRtLmMacOsRequiredLibrariesForAbi(abi);
  return requiredLibraries.isNotEmpty &&
      requiredLibraries.every(
        (library) => File('${dir.path}/$library').existsSync(),
      );
}

/// Internal helper used by the LiteRT-LM runtime to validate extracted
/// native-assets cache directories.
bool liteRtLmIsCacheDirectoryForAbi(Directory dir, Abi abi) {
  final requiredLibraries = liteRtLmRequiredLibrariesForAbi(abi);
  return requiredLibraries.isNotEmpty &&
      requiredLibraries.every(
        (library) => File('${dir.path}/$library').existsSync(),
      );
}

typedef _StreamCallbackNative =
    Void Function(
      Pointer<Void> callbackData,
      Pointer<Char> chunk,
      Bool isFinal,
      Pointer<Char> errorMessage,
    );

typedef _ProxyCreateNative =
    Pointer<Void> Function(
      Pointer<NativeFunction<_StreamCallbackNative>> dartCallback,
      Pointer<Void> dartData,
      Pointer<Pointer<NativeFunction<_StreamCallbackNative>>> outProxyFn,
    );
typedef _ProxyCreateDart =
    Pointer<Void> Function(
      Pointer<NativeFunction<_StreamCallbackNative>> dartCallback,
      Pointer<Void> dartData,
      Pointer<Pointer<NativeFunction<_StreamCallbackNative>>> outProxyFn,
    );

typedef _ProxyFreeStringNative = Void Function(Pointer<Char> value);
typedef _ProxyFreeStringDart = void Function(Pointer<Char> value);

typedef _ProxyDeleteNative = Void Function(Pointer<Void> callbackData);
typedef _ProxyDeleteDart = void Function(Pointer<Void> callbackData);

typedef _LoadGlobalNative = Pointer<Void> Function(Pointer<Utf8> path);
typedef _LoadGlobalDart = Pointer<Void> Function(Pointer<Utf8> path);

final class _LiteRtLmEngine extends Opaque {}

final class _LiteRtLmEngineSettings extends Opaque {}

final class _LiteRtLmSessionConfig extends Opaque {}

final class _LiteRtLmConversationConfig extends Opaque {}

final class _LiteRtLmConversationOptionalArgs extends Opaque {}

final class _LiteRtLmConversation extends Opaque {}

final class _LiteRtLmJsonResponse extends Opaque {}

final class _LiteRtLmBenchmarkInfo extends Opaque {}

final class _LiteRtLmTokenizeResult extends Opaque {}

final class _LiteRtLmDetokenizeResult extends Opaque {}

final class _LiteRtLmTokenUnion extends Opaque {}

final class _LiteRtLmSamplerParams extends Struct {
  @Int32()
  external int type;

  @Int32()
  external int topK;

  @Float()
  external double topP;

  @Float()
  external double temperature;

  @Int32()
  external int seed;
}

/// Runtime metrics reported by LiteRT-LM for a completed generation.
class LiteRtLmRuntimeMetrics {
  /// Number of prompt/input tokens.
  final int inputTokens;

  /// Number of generated/output tokens.
  final int outputTokens;

  /// Time to first token in seconds, when reported by LiteRT-LM.
  final double? timeToFirstTokenSeconds;

  /// Engine initialization time in seconds, when reported by LiteRT-LM.
  final double? initSeconds;

  /// Prompt prefill throughput in tokens per second.
  final double? prefillTokensPerSecond;

  /// Decode throughput in tokens per second.
  final double? decodeTokensPerSecond;

  /// Wall-clock runtime measured by Dart.
  final int wallMilliseconds;

  /// Creates runtime metrics.
  const LiteRtLmRuntimeMetrics({
    required this.inputTokens,
    required this.outputTokens,
    required this.timeToFirstTokenSeconds,
    required this.initSeconds,
    required this.prefillTokensPerSecond,
    required this.decodeTokensPerSecond,
    required this.wallMilliseconds,
  });

  /// Converts metrics to JSON-compatible values.
  Map<String, Object?> toJson() => {
    'inputTokens': inputTokens,
    'outputTokens': outputTokens,
    'timeToFirstTokenSeconds': timeToFirstTokenSeconds,
    'initSeconds': initSeconds,
    'prefillTokensPerSecond': prefillTokensPerSecond,
    'decodeTokensPerSecond': decodeTokensPerSecond,
    'wallMilliseconds': wallMilliseconds,
  };
}

/// Generated text and runtime metrics from a LiteRT-LM run.
class LiteRtLmRuntimeResult {
  /// Generated text.
  final String text;

  /// Runtime metrics.
  final LiteRtLmRuntimeMetrics metrics;

  /// Creates a runtime result.
  const LiteRtLmRuntimeResult({required this.text, required this.metrics});
}

// coverage:ignore-start
// Native FFI boundary: exercised by LiteRT-LM smoke tests with real libraries.
final class _BlockingSendMessageRequest {
  const _BlockingSendMessageRequest({
    required this.libraryPath,
    required this.conversationAddress,
    required this.prompt,
  });

  final String libraryPath;
  final int conversationAddress;
  final String prompt;
}

/// Low-level native LiteRT-LM runtime client.
///
/// Most callers should use [LiteRtLmBackend] through the high-level
/// `LlamaEngine` API. This client is exported for benchmark tools and advanced
/// native integrations that need direct access to LiteRT-LM bundles.
class LiteRtLmRuntimeClient {
  _LiteRtLmBindings? _bindings;
  // Keep a strong reference while callbacks/function pointers may be active.
  // ignore: unused_field
  DynamicLibrary? _proxyLibrary;
  _ProxyCreateDart? _proxyCreate;
  _ProxyFreeStringDart? _proxyFreeString;
  _ProxyDeleteDart? _proxyDelete;
  String? _liteRtLmLibraryPath;
  Pointer<_LiteRtLmEngine>? _engine;
  Pointer<_LiteRtLmConversation>? _conversation;

  /// Initializes the native LiteRT-LM engine for a `.litertlm` model bundle.
  Future<void> initialize({
    required String modelPath,
    String backend = 'gpu',
    int maxTokens = 4096,
    int outputTokens = 256,
    int? prefillTokens,
    String? cacheDir,
    bool speculativeDecoding = true,
    int minLogLevel = 3,
  }) async {
    if (maxTokens <= 0) {
      throw ArgumentError.value(maxTokens, 'maxTokens', 'must be positive');
    }
    if (outputTokens <= 0) {
      throw ArgumentError.value(
        outputTokens,
        'outputTokens',
        'must be positive',
      );
    }
    if (prefillTokens != null && prefillTokens <= 0) {
      throw ArgumentError.value(
        prefillTokens,
        'prefillTokens',
        'must be positive when provided',
      );
    }
    final resolvedBackend = _normalizeLiteRtLmRuntimeBackend(backend);

    _ensureLibrariesLoaded();
    final bindings = _bindings!;
    bindings.setMinLogLevel(minLogLevel);
    if (_engine != null || _conversation != null) {
      dispose();
    }

    final modelPathPtr = modelPath.toNativeUtf8();
    final backendPtr = resolvedBackend.toNativeUtf8();
    final cacheDirPtr = cacheDir?.toNativeUtf8();
    Pointer<_LiteRtLmEngineSettings> settings = nullptr;

    try {
      settings = bindings.engineSettingsCreate(
        modelPathPtr.cast(),
        backendPtr.cast(),
        nullptr,
        nullptr,
      );
      if (settings == nullptr) {
        throw StateError('litert_lm_engine_settings_create returned null');
      }
      bindings.engineSettingsSetMaxNumTokens(settings, maxTokens);
      bindings.engineSettingsEnableBenchmark(settings);
      bindings.engineSettingsSetNumDecodeTokens(settings, outputTokens);
      bindings.engineSettingsSetEnableSpeculativeDecoding(
        settings,
        speculativeDecoding,
      );
      if (prefillTokens != null) {
        bindings.engineSettingsSetNumPrefillTokens(settings, prefillTokens);
      }
      if (cacheDirPtr != null) {
        bindings.engineSettingsSetCacheDir(settings, cacheDirPtr.cast());
      }

      final settingsAddress = settings.address;
      final liteRtLmLibraryPath = _liteRtLmLibraryPath!;
      final engineAddress = await Isolate.run(() {
        final lib = DynamicLibrary.open(liteRtLmLibraryPath);
        final create = lib
            .lookupFunction<
              Pointer<_LiteRtLmEngine> Function(
                Pointer<_LiteRtLmEngineSettings>,
              ),
              Pointer<_LiteRtLmEngine> Function(
                Pointer<_LiteRtLmEngineSettings>,
              )
            >('litert_lm_engine_create');
        return create(
          Pointer<_LiteRtLmEngineSettings>.fromAddress(settingsAddress),
        ).address;
      });
      if (engineAddress == 0) {
        throw StateError(
          liteRtLmEngineCreateFailureMessage(
            backend: resolvedBackend,
            modelPath: modelPath,
          ),
        );
      }
      _engine = Pointer<_LiteRtLmEngine>.fromAddress(engineAddress);
    } finally {
      if (settings != nullptr) {
        bindings.engineSettingsDelete(settings);
      }
      calloc.free(modelPathPtr);
      calloc.free(backendPtr);
      if (cacheDirPtr != null) {
        calloc.free(cacheDirPtr);
      }
    }
  }

  /// Creates a new LiteRT-LM conversation for generation and token operations.
  void createConversation({
    String? systemMessage,
    double temperature = 0.8,
    int topK = 40,
    double topP = 0.95,
    int seed = 1,
    bool npuBackend = false,
  }) {
    final bindings = _requireBindings();
    final engine = _requireEngine();
    _deleteConversation();

    final sessionConfig = bindings.sessionConfigCreate();
    if (sessionConfig == nullptr) {
      throw StateError('litert_lm_session_config_create returned null');
    }
    if (!npuBackend) {
      final sampler = calloc<_LiteRtLmSamplerParams>();
      sampler.ref
        ..type = 2
        ..topK = topK
        ..topP = topP
        ..temperature = temperature
        ..seed = seed;
      bindings.sessionConfigSetSamplerParams(sessionConfig, sampler);
      calloc.free(sampler);
    }

    final systemPtr = systemMessage == null
        ? nullptr
        : systemMessage.toNativeUtf8();
    Pointer<_LiteRtLmConversationConfig> config = nullptr;
    try {
      config = bindings.conversationConfigCreate();
      if (config == nullptr) {
        throw StateError('litert_lm_conversation_config_create returned null');
      }
      bindings.conversationConfigSetSessionConfig(config, sessionConfig);
      if (systemPtr != nullptr) {
        bindings.conversationConfigSetSystemMessage(config, systemPtr.cast());
      }
      bindings.conversationConfigSetEnableConstrainedDecoding(config, false);
      final conversation = bindings.conversationCreate(engine, config);
      if (conversation == nullptr) {
        throw StateError('litert_lm_conversation_create returned null');
      }
      _conversation = conversation;
    } finally {
      if (config != nullptr) {
        bindings.conversationConfigDelete(config);
      }
      bindings.sessionConfigDelete(sessionConfig);
      if (systemPtr != nullptr) {
        calloc.free(systemPtr);
      }
    }
  }

  /// Updates the native LiteRT-LM log level.
  void setMinLogLevel(int level) {
    _ensureLibrariesLoaded();
    _bindings!.setMinLogLevel(level);
  }

  /// Tokenizes text with the native LiteRT-LM tokenizer.
  List<int> tokenize(String text, {bool addSpecial = true}) {
    final tokens = _tokenizeRaw(text);
    if (!addSpecial) {
      return tokens;
    }
    final startToken = _readStartToken();
    if (startToken.isEmpty) {
      return tokens;
    }
    return <int>[...startToken, ...tokens];
  }

  /// Converts native LiteRT-LM token ids back to text.
  String detokenize(List<int> tokens) {
    final bindings = _requireBindings();
    final engine = _requireEngine();
    if (tokens.isEmpty) {
      return '';
    }

    final tokenPtr = calloc<Int>(tokens.length);
    Pointer<_LiteRtLmDetokenizeResult> result = nullptr;
    try {
      for (var i = 0; i < tokens.length; i++) {
        tokenPtr[i] = tokens[i];
      }
      result = bindings.engineDetokenize(engine, tokenPtr, tokens.length);
      if (result == nullptr) {
        throw StateError('litert_lm_engine_detokenize returned null');
      }
      final textPtr = bindings.detokenizeResultGetString(result);
      if (textPtr == nullptr) {
        throw StateError(
          'litert_lm_detokenize_result_get_string returned null',
        );
      }
      return textPtr.cast<Utf8>().toDartString();
    } finally {
      if (result != nullptr) {
        bindings.detokenizeResultDelete(result);
      }
      calloc.free(tokenPtr);
    }
  }

  /// Streams generated text from the active conversation.
  Stream<String> generate(String prompt) {
    // Upstream stream callback strings are only valid during the native call.
    // Dart listener callbacks run later, so streaming requires StreamProxy to
    // copy those strings across the thread/isolate boundary.
    if (_proxyCreate == null) {
      return _generateBlocking(prompt);
    }
    return _generateStreaming(prompt);
  }

  Stream<String> _generateBlocking(String prompt) {
    final conversation = _requireConversation();
    final liteRtLmLibraryPath = _liteRtLmLibraryPath!;
    final controller = StreamController<String>(onCancel: cancel);
    final request = _BlockingSendMessageRequest(
      libraryPath: liteRtLmLibraryPath,
      conversationAddress: conversation.address,
      prompt: prompt,
    );

    unawaited(() async {
      try {
        final raw = await _runBlockingSendMessageInIsolate(request);
        if (!controller.isClosed) {
          final text = _extractText(raw);
          if (text.isNotEmpty) {
            controller.add(text);
          }
        }
      } catch (error, stackTrace) {
        if (!controller.isClosed) {
          controller.addError(error, stackTrace);
        }
      } finally {
        if (!controller.isClosed) {
          await controller.close();
        }
      }
    }());

    return controller.stream;
  }

  Stream<String> _generateStreaming(String prompt) {
    final bindings = _requireBindings();
    final conversation = _requireConversation();
    final controller = StreamController<String>(onCancel: cancel);
    final messagePtr = _messageJson(prompt).toNativeUtf8();
    Pointer<Void> callbackData = nullptr;
    var cleanedUp = false;

    late final NativeCallable<_StreamCallbackNative> callable;
    void cleanup() {
      if (cleanedUp) {
        return;
      }
      cleanedUp = true;
      if (callbackData != nullptr) {
        _proxyDelete?.call(callbackData);
        callbackData = nullptr;
      }
      callable.close();
      calloc.free(messagePtr);
    }

    callable = NativeCallable<_StreamCallbackNative>.listener((
      Pointer<Void> data,
      Pointer<Char> chunk,
      bool isFinal,
      Pointer<Char> errorMessage,
    ) {
      if (errorMessage != nullptr) {
        final error = errorMessage.cast<Utf8>().toDartString();
        _proxyFreeString?.call(errorMessage);
        if (error.startsWith('CANCELLED')) {
          unawaited(controller.close());
        } else {
          controller.addError(StateError(error));
          unawaited(controller.close());
        }
        cleanup();
        return;
      }

      if (chunk != nullptr) {
        final raw = chunk.cast<Utf8>().toDartString();
        _proxyFreeString?.call(chunk);
        final text = _extractText(raw);
        if (text.isNotEmpty) {
          controller.add(text);
        }
      }

      if (isFinal) {
        unawaited(controller.close());
        cleanup();
      }
    });

    var callbackFn = callable.nativeFunction;
    final proxyCreate = _proxyCreate;
    if (proxyCreate != null) {
      final outProxyFn =
          calloc<Pointer<NativeFunction<_StreamCallbackNative>>>();
      try {
        callbackData = proxyCreate(
          callable.nativeFunction,
          nullptr,
          outProxyFn,
        );
        callbackFn = outProxyFn.value;
        if (callbackData == nullptr || callbackFn == nullptr) {
          throw StateError('stream_proxy_create returned null');
        }
      } catch (_) {
        cleanup();
        rethrow;
      } finally {
        calloc.free(outProxyFn);
      }
    }

    Pointer<_LiteRtLmConversationOptionalArgs> optionalArgs = nullptr;
    try {
      optionalArgs = bindings.conversationOptionalArgsCreate();
      if (optionalArgs == nullptr) {
        throw StateError(
          'litert_lm_conversation_optional_args_create returned null',
        );
      }

      final rc = bindings.conversationSendMessageStream(
        conversation,
        messagePtr.cast(),
        nullptr,
        optionalArgs,
        callbackFn.cast(),
        callbackData,
      );
      if (rc != 0) {
        throw StateError('litert_lm_conversation_send_message_stream rc=$rc');
      }
    } catch (_) {
      cleanup();
      rethrow;
    } finally {
      if (optionalArgs != nullptr) {
        bindings.conversationOptionalArgsDelete(optionalArgs);
      }
    }

    return controller.stream;
  }

  List<int> _tokenizeRaw(String text) {
    final bindings = _requireBindings();
    final engine = _requireEngine();
    final textPtr = text.toNativeUtf8();
    Pointer<_LiteRtLmTokenizeResult> result = nullptr;
    try {
      result = bindings.engineTokenize(engine, textPtr.cast());
      if (result == nullptr) {
        throw StateError('litert_lm_engine_tokenize returned null');
      }
      final count = bindings.tokenizeResultGetNumTokens(result);
      final tokenPtr = bindings.tokenizeResultGetTokens(result);
      if (count > 0 && tokenPtr == nullptr) {
        throw StateError('litert_lm_tokenize_result_get_tokens returned null');
      }
      return List<int>.generate(count, (index) => tokenPtr[index]);
    } finally {
      if (result != nullptr) {
        bindings.tokenizeResultDelete(result);
      }
      calloc.free(textPtr);
    }
  }

  List<int> _readStartToken() {
    final bindings = _requireBindings();
    final engine = _requireEngine();
    final tokenUnion = bindings.engineGetStartToken(engine);
    if (tokenUnion == nullptr) {
      return const <int>[];
    }
    try {
      final type = bindings.tokenUnionGetType(tokenUnion);
      if (type == 1) {
        final tokensOut = calloc<Pointer<Int>>();
        final countOut = calloc<Size>();
        try {
          final rc = bindings.tokenUnionGetIds(tokenUnion, tokensOut, countOut);
          final tokenPtr = tokensOut.value;
          final count = countOut.value;
          if (rc != 0 || count == 0 || tokenPtr == nullptr) {
            return const <int>[];
          }
          return List<int>.generate(count, (index) => tokenPtr[index]);
        } finally {
          calloc.free(tokensOut);
          calloc.free(countOut);
        }
      }

      if (type == 0) {
        final textPtr = bindings.tokenUnionGetString(tokenUnion);
        if (textPtr == nullptr) {
          return const <int>[];
        }
        final text = textPtr.cast<Utf8>().toDartString();
        return text.isEmpty ? const <int>[] : _tokenizeRaw(text);
      }

      return const <int>[];
    } finally {
      bindings.tokenUnionDelete(tokenUnion);
    }
  }

  /// Runs a benchmark-style prompt loop and returns runtime metrics.
  Future<LiteRtLmRuntimeResult> run({
    required String prompt,
    int warmupRuns = 1,
    int measuredRuns = 3,
  }) async {
    if (warmupRuns < 0) {
      throw ArgumentError.value(warmupRuns, 'warmupRuns', 'must be >= 0');
    }
    if (measuredRuns <= 0) {
      throw ArgumentError.value(measuredRuns, 'measuredRuns', 'must be > 0');
    }

    for (var i = 0; i < warmupRuns; i++) {
      createConversation();
      await generate(prompt).drain<void>();
    }

    var lastText = '';
    late LiteRtLmRuntimeMetrics metrics;
    for (var i = 0; i < measuredRuns; i++) {
      createConversation();
      final buffer = StringBuffer();
      final sw = Stopwatch()..start();
      await for (final chunk in generate(prompt)) {
        buffer.write(chunk);
      }
      sw.stop();
      lastText = buffer.toString();
      metrics = _readMetrics(sw.elapsedMilliseconds);
    }

    return LiteRtLmRuntimeResult(text: lastText, metrics: metrics);
  }

  /// Reads runtime metrics for the active conversation.
  LiteRtLmRuntimeMetrics readMetrics({required int wallMilliseconds}) {
    return _readMetrics(wallMilliseconds);
  }

  /// Cancels active native generation.
  void cancel() {
    final conversation = _conversation;
    final bindings = _bindings;
    if (conversation != null && conversation != nullptr && bindings != null) {
      bindings.conversationCancelProcess(conversation);
    }
  }

  /// Releases native LiteRT-LM resources.
  void dispose() {
    _deleteConversation();
    final engine = _engine;
    final bindings = _bindings;
    if (engine != null && engine != nullptr && bindings != null) {
      bindings.engineDelete(engine);
    }
    _engine = null;
  }

  void _ensureLibrariesLoaded() {
    if (_bindings != null) {
      return;
    }
    final libraries = _librariesForCurrentPlatform();
    if (libraries == null) {
      throw UnsupportedError('LiteRT-LM does not support ${Abi.current()}.');
    }

    for (final companion in libraries.companions) {
      if (File(companion).existsSync() || !path.isAbsolute(companion)) {
        DynamicLibrary.open(companion);
      }
    }

    if (libraries.proxyCandidates.isNotEmpty) {
      try {
        final proxyLibrary = _openFirstAvailable(libraries.proxyCandidates);
        final loadGlobal = proxyLibrary
            .lookupFunction<_LoadGlobalNative, _LoadGlobalDart>(
              'stream_proxy_load_global',
            );
        final liteRtLmLoadTarget = libraries.liteRtLmCandidates.first;
        final liteRtLmName = liteRtLmLoadTarget.toNativeUtf8();
        try {
          final handle = loadGlobal(liteRtLmName);
          if (handle == nullptr) {
            throw StateError(
              'Failed to load $liteRtLmLoadTarget with RTLD_GLOBAL',
            );
          }
        } finally {
          calloc.free(liteRtLmName);
        }

        _proxyCreate = proxyLibrary
            .lookupFunction<_ProxyCreateNative, _ProxyCreateDart>(
              'stream_proxy_create',
            );
        _proxyFreeString = proxyLibrary
            .lookupFunction<_ProxyFreeStringNative, _ProxyFreeStringDart>(
              'stream_proxy_free_string',
            );
        _proxyDelete = proxyLibrary
            .lookupFunction<_ProxyDeleteNative, _ProxyDeleteDart>(
              'stream_proxy_delete',
            );
        _proxyLibrary = proxyLibrary;
      } catch (error) {
        if (!libraries.directCallbackSupported) {
          rethrow;
        }
      }
    }

    final liteRtLm = _openFirstAvailableWithPath(libraries.liteRtLmCandidates);
    _liteRtLmLibraryPath = liteRtLm.path;
    _bindings = _LiteRtLmBindings(liteRtLm.library);
  }

  ({
    List<String> proxyCandidates,
    List<String> liteRtLmCandidates,
    List<String> companions,
    bool directCallbackSupported,
  })?
  _librariesForCurrentPlatform() {
    final abi = Abi.current();
    if (Platform.isAndroid &&
        (abi == Abi.androidArm64 || abi == Abi.androidX64)) {
      return (
        proxyCandidates: const [
          'package:llamadart/litert_lm_StreamProxy',
          'libStreamProxy.so',
        ],
        liteRtLmCandidates: const ['libLiteRtLm.so'],
        companions: const [],
        directCallbackSupported: true,
      );
    }
    if (Platform.isIOS && (abi == Abi.iosArm64 || abi == Abi.iosX64)) {
      return (
        proxyCandidates: liteRtLmIosStreamProxyCandidatesForAbi(abi),
        liteRtLmCandidates: liteRtLmIosLibraryCandidatesForAbi(abi),
        companions: const [],
        directCallbackSupported: true,
      );
    }
    if (Platform.isMacOS && (abi == Abi.macosArm64 || abi == Abi.macosX64)) {
      final companions = _macOsCompanionLibrariesForAbi(abi);
      final frameworksDir = _findMacOsAppFrameworksDir();
      if (frameworksDir != null) {
        return (
          proxyCandidates: [
            '${frameworksDir.path}/StreamProxy.framework/Versions/A/StreamProxy',
            'package:llamadart/litert_lm_StreamProxy',
            'libStreamProxy.dylib',
          ],
          liteRtLmCandidates: [
            '${frameworksDir.path}/LiteRtLm.framework/Versions/A/LiteRtLm',
          ],
          companions: [
            for (final library in companions)
              _macOsFrameworkBinaryPath(frameworksDir, library),
          ],
          directCallbackSupported: true,
        );
      }
      final cacheDir = _findMacOsLiteRtLmCacheDir();
      if (cacheDir != null) {
        return (
          proxyCandidates: [
            '${cacheDir.path}/libStreamProxy.dylib',
            'package:llamadart/litert_lm_StreamProxy',
            'libStreamProxy.dylib',
          ],
          liteRtLmCandidates: ['${cacheDir.path}/libLiteRtLm.dylib'],
          companions: [
            for (final library in companions) '${cacheDir.path}/$library',
          ],
          directCallbackSupported: true,
        );
      }
      return (
        proxyCandidates: const [
          'package:llamadart/litert_lm_StreamProxy',
          'libStreamProxy.dylib',
        ],
        liteRtLmCandidates: const ['libLiteRtLm.dylib'],
        companions: [for (final library in companions) library],
        directCallbackSupported: true,
      );
    }
    if (Platform.isLinux && (abi == Abi.linuxX64 || abi == Abi.linuxArm64)) {
      final cacheDir = _findLiteRtLmCacheDirForAbi(abi);
      if (cacheDir != null) {
        return (
          proxyCandidates: [
            '${cacheDir.path}/libStreamProxy.so',
            'package:llamadart/litert_lm_StreamProxy',
            'libStreamProxy.so',
          ],
          liteRtLmCandidates: ['${cacheDir.path}/libLiteRtLm.so'],
          companions: _companionLibrariesForAbi(abi, cacheDir),
          directCallbackSupported: true,
        );
      }
      return (
        proxyCandidates: const [
          'package:llamadart/litert_lm_StreamProxy',
          'libStreamProxy.so',
        ],
        liteRtLmCandidates: const ['package:llamadart/litert_lm_LiteRtLm'],
        companions: const [],
        directCallbackSupported: true,
      );
    }
    if (Platform.isWindows && abi == Abi.windowsX64) {
      final cacheDir = _findLiteRtLmCacheDirForAbi(abi);
      if (cacheDir != null) {
        return (
          proxyCandidates: [
            '${cacheDir.path}/StreamProxy.dll',
            'package:llamadart/litert_lm_StreamProxy',
            'StreamProxy.dll',
          ],
          liteRtLmCandidates: ['${cacheDir.path}/LiteRtLm.dll'],
          companions: _companionLibrariesForAbi(abi, cacheDir),
          directCallbackSupported: true,
        );
      }
      return (
        proxyCandidates: const [
          'package:llamadart/litert_lm_StreamProxy',
          'StreamProxy.dll',
        ],
        liteRtLmCandidates: const ['package:llamadart/litert_lm_LiteRtLm'],
        companions: const [],
        directCallbackSupported: true,
      );
    }
    return null;
  }

  DynamicLibrary _openFirstAvailable(List<String> candidates) {
    Object? lastError;
    for (final candidate in candidates) {
      try {
        return DynamicLibrary.open(candidate);
      } catch (error) {
        lastError = error;
      }
    }
    throw ArgumentError('Failed to load any of $candidates: $lastError');
  }

  ({String path, DynamicLibrary library}) _openFirstAvailableWithPath(
    List<String> candidates,
  ) {
    Object? lastError;
    for (final candidate in candidates) {
      try {
        return (path: candidate, library: DynamicLibrary.open(candidate));
      } catch (error) {
        lastError = error;
      }
    }
    throw ArgumentError('Failed to load any of $candidates: $lastError');
  }

  Directory? _findMacOsAppFrameworksDir() {
    final executable = File(Platform.resolvedExecutable);
    final contentsDir = executable.parent.parent;
    final frameworksDir = Directory('${contentsDir.path}/Frameworks');
    if (!frameworksDir.existsSync()) {
      return null;
    }
    final requiredFrameworks = liteRtLmMacOsRequiredFrameworksForAbi(
      Abi.current(),
    );
    if (requiredFrameworks.isEmpty) {
      return null;
    }
    final requiredFiles = [
      for (final framework in requiredFrameworks)
        '${frameworksDir.path}/$framework',
    ];
    if (requiredFiles.every((file) => File(file).existsSync())) {
      return frameworksDir;
    }
    return null;
  }

  Directory? _findMacOsLiteRtLmCacheDir() {
    return _findLiteRtLmCacheDirForAbi(Abi.current());
  }

  Directory? _findLiteRtLmCacheDirForAbi(Abi abi) {
    final envPath = Platform.environment[_litertLmLibDirEnv];
    if (envPath != null && envPath.isNotEmpty) {
      final dir = Directory(envPath);
      if (liteRtLmIsCacheDirectoryForAbi(dir, abi)) {
        return dir.absolute;
      }
    }

    final cacheDirectoryCandidates = liteRtLmCacheDirectoryCandidatesForAbi(
      abi,
    );

    for (final root in _candidateSearchRoots()) {
      Directory? current = root;
      while (current != null) {
        for (final cacheDirectoryCandidate in cacheDirectoryCandidates) {
          final candidate = Directory(
            '${current.path}/.dart_tool/llamadart/litert_lm/'
            '$_litertLmVersion/$cacheDirectoryCandidate',
          );
          if (liteRtLmIsCacheDirectoryForAbi(candidate, abi)) {
            return candidate;
          }
        }
        current = current.parent.path == current.path ? null : current.parent;
      }
    }
    return null;
  }

  List<Directory> _candidateSearchRoots() {
    final roots = <String>{Directory.current.path};
    final scriptPath = Platform.script.toFilePath();
    if (scriptPath.isNotEmpty) {
      roots.add(File(scriptPath).parent.path);
    }
    roots.add(File(Platform.resolvedExecutable).parent.path);
    return roots.map(Directory.new).toList();
  }

  List<String> _macOsCompanionLibrariesForAbi(Abi abi) {
    return liteRtLmMacOsRequiredLibrariesForAbi(abi)
        .where(
          (library) =>
              library != 'libLiteRtLm.dylib' &&
              library != 'libStreamProxy.dylib',
        )
        .toList(growable: false);
  }

  List<String> _companionLibrariesForAbi(Abi abi, Directory dir) {
    final liteRtLm = _liteRtLmLibraryFileNameForAbi(abi);
    final streamProxy = _streamProxyLibraryFileNameForAbi(abi);
    if (liteRtLm == null || streamProxy == null) {
      return const <String>[];
    }
    return liteRtLmRequiredLibrariesForAbi(abi)
        .where((library) => library != liteRtLm && library != streamProxy)
        .map((library) => '${dir.path}/$library')
        .toList(growable: false);
  }

  String? _liteRtLmLibraryFileNameForAbi(Abi abi) {
    return switch (abi) {
      Abi.macosArm64 => 'libLiteRtLm.dylib',
      Abi.macosX64 => 'libLiteRtLm.dylib',
      Abi.linuxArm64 => 'libLiteRtLm.so',
      Abi.linuxX64 => 'libLiteRtLm.so',
      Abi.windowsX64 => 'LiteRtLm.dll',
      _ => null,
    };
  }

  String? _streamProxyLibraryFileNameForAbi(Abi abi) {
    return switch (abi) {
      Abi.macosArm64 => 'libStreamProxy.dylib',
      Abi.macosX64 => 'libStreamProxy.dylib',
      Abi.linuxArm64 => 'libStreamProxy.so',
      Abi.linuxX64 => 'libStreamProxy.so',
      Abi.windowsX64 => 'StreamProxy.dll',
      _ => null,
    };
  }

  String _macOsFrameworkBinaryPath(Directory frameworksDir, String library) {
    final frameworkName = _macOsFrameworkNameForLibrary(library);
    return '${frameworksDir.path}/$frameworkName.framework/Versions/A/'
        '$frameworkName';
  }

  String _macOsFrameworkNameForLibrary(String library) {
    final basename = path.basenameWithoutExtension(library);
    return basename.startsWith('lib') ? basename.substring(3) : basename;
  }

  _LiteRtLmBindings _requireBindings() {
    final bindings = _bindings;
    if (bindings == null) {
      throw StateError('LiteRT-LM bindings are not initialized.');
    }
    return bindings;
  }

  Pointer<_LiteRtLmEngine> _requireEngine() {
    final engine = _engine;
    if (engine == null || engine == nullptr) {
      throw StateError('LiteRT-LM engine is not initialized.');
    }
    return engine;
  }

  Pointer<_LiteRtLmConversation> _requireConversation() {
    final conversation = _conversation;
    if (conversation == null || conversation == nullptr) {
      throw StateError('LiteRT-LM conversation is not initialized.');
    }
    return conversation;
  }

  void _deleteConversation() {
    final conversation = _conversation;
    final bindings = _bindings;
    if (conversation != null && conversation != nullptr && bindings != null) {
      bindings.conversationDelete(conversation);
    }
    _conversation = null;
  }

  LiteRtLmRuntimeMetrics _readMetrics(int wallMilliseconds) {
    final bindings = _requireBindings();
    final conversation = _requireConversation();
    final info = bindings.conversationGetBenchmarkInfo(conversation);
    if (info == nullptr) {
      return LiteRtLmRuntimeMetrics(
        inputTokens: 0,
        outputTokens: 0,
        timeToFirstTokenSeconds: null,
        initSeconds: null,
        prefillTokensPerSecond: null,
        decodeTokensPerSecond: null,
        wallMilliseconds: wallMilliseconds,
      );
    }
    try {
      final prefillTurns = bindings.benchmarkInfoGetNumPrefillTurns(info);
      final decodeTurns = bindings.benchmarkInfoGetNumDecodeTurns(info);
      var inputTokens = 0;
      var outputTokens = 0;
      for (var i = 0; i < prefillTurns; i++) {
        inputTokens += bindings.benchmarkInfoGetPrefillTokenCountAt(info, i);
      }
      for (var i = 0; i < decodeTurns; i++) {
        outputTokens += bindings.benchmarkInfoGetDecodeTokenCountAt(info, i);
      }
      final prefillTps = prefillTurns == 0
          ? null
          : bindings.benchmarkInfoGetPrefillTokensPerSecAt(
              info,
              prefillTurns - 1,
            );
      final decodeTps = decodeTurns == 0
          ? null
          : bindings.benchmarkInfoGetDecodeTokensPerSecAt(
              info,
              decodeTurns - 1,
            );
      return LiteRtLmRuntimeMetrics(
        inputTokens: inputTokens,
        outputTokens: outputTokens,
        timeToFirstTokenSeconds: bindings.benchmarkInfoGetTimeToFirstToken(
          info,
        ),
        initSeconds: bindings.benchmarkInfoGetTotalInitTimeInSecond(info),
        prefillTokensPerSecond: prefillTps,
        decodeTokensPerSecond: decodeTps,
        wallMilliseconds: wallMilliseconds,
      );
    } finally {
      bindings.benchmarkInfoDelete(info);
    }
  }
}

String _normalizeLiteRtLmRuntimeBackend(String backend) {
  final normalized = backend.trim().toLowerCase();
  if (normalized == 'cpu' || normalized == 'gpu' || normalized == 'npu') {
    return normalized;
  }
  throw ArgumentError.value(backend, 'backend', 'must be cpu, gpu, or npu');
}

String _messageJson(String text) {
  return jsonEncode({
    'role': 'user',
    'content': [
      {'type': 'text', 'text': text},
    ],
  });
}

Future<String> _runBlockingSendMessageInIsolate(
  _BlockingSendMessageRequest request,
) {
  return Isolate.run(() => _runBlockingSendMessage(request));
}

String _runBlockingSendMessage(_BlockingSendMessageRequest request) {
  final bindings = _LiteRtLmBindings(DynamicLibrary.open(request.libraryPath));
  final conversation = Pointer<_LiteRtLmConversation>.fromAddress(
    request.conversationAddress,
  );
  final messagePtr = _messageJson(request.prompt).toNativeUtf8();
  Pointer<_LiteRtLmConversationOptionalArgs> optionalArgs = nullptr;
  try {
    optionalArgs = bindings.conversationOptionalArgsCreate();
    if (optionalArgs == nullptr) {
      throw StateError(
        'litert_lm_conversation_optional_args_create returned null',
      );
    }

    final response = bindings.conversationSendMessage(
      conversation,
      messagePtr.cast(),
      nullptr,
      optionalArgs,
    );
    if (response == nullptr) {
      throw StateError('litert_lm_conversation_send_message returned null');
    }

    try {
      final rawPtr = bindings.jsonResponseGetString(response);
      if (rawPtr == nullptr) {
        throw StateError('litert_lm_json_response_get_string returned null');
      }
      return rawPtr.cast<Utf8>().toDartString();
    } finally {
      bindings.jsonResponseDelete(response);
    }
  } finally {
    if (optionalArgs != nullptr) {
      bindings.conversationOptionalArgsDelete(optionalArgs);
    }
    calloc.free(messagePtr);
  }
}

String _extractText(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      return raw;
    }
    final content = decoded['content'];
    if (content is! List) {
      return raw;
    }
    final buffer = StringBuffer();
    for (final item in content) {
      if (item is Map<String, dynamic> && item['type'] == 'text') {
        buffer.write(item['text'] as String? ?? '');
      }
    }
    return buffer.toString();
  } on FormatException {
    return raw;
  }
}

class _LiteRtLmBindings {
  final DynamicLibrary _library;

  _LiteRtLmBindings(this._library);

  late final setMinLogLevel = _library
      .lookupFunction<Void Function(Int), void Function(int)>(
        'litert_lm_set_min_log_level',
      );

  late final engineSettingsCreate = _library
      .lookupFunction<
        Pointer<_LiteRtLmEngineSettings> Function(
          Pointer<Char>,
          Pointer<Char>,
          Pointer<Char>,
          Pointer<Char>,
        ),
        Pointer<_LiteRtLmEngineSettings> Function(
          Pointer<Char>,
          Pointer<Char>,
          Pointer<Char>,
          Pointer<Char>,
        )
      >('litert_lm_engine_settings_create');

  late final engineSettingsDelete = _library
      .lookupFunction<
        Void Function(Pointer<_LiteRtLmEngineSettings>),
        void Function(Pointer<_LiteRtLmEngineSettings>)
      >('litert_lm_engine_settings_delete');

  late final engineSettingsSetMaxNumTokens = _library
      .lookupFunction<
        Void Function(Pointer<_LiteRtLmEngineSettings>, Int),
        void Function(Pointer<_LiteRtLmEngineSettings>, int)
      >('litert_lm_engine_settings_set_max_num_tokens');

  late final engineSettingsEnableBenchmark = _library
      .lookupFunction<
        Void Function(Pointer<_LiteRtLmEngineSettings>),
        void Function(Pointer<_LiteRtLmEngineSettings>)
      >('litert_lm_engine_settings_enable_benchmark');

  late final engineSettingsSetNumPrefillTokens = _library
      .lookupFunction<
        Void Function(Pointer<_LiteRtLmEngineSettings>, Int),
        void Function(Pointer<_LiteRtLmEngineSettings>, int)
      >('litert_lm_engine_settings_set_num_prefill_tokens');

  late final engineSettingsSetNumDecodeTokens = _library
      .lookupFunction<
        Void Function(Pointer<_LiteRtLmEngineSettings>, Int),
        void Function(Pointer<_LiteRtLmEngineSettings>, int)
      >('litert_lm_engine_settings_set_num_decode_tokens');

  late final engineSettingsSetEnableSpeculativeDecoding = _library
      .lookupFunction<
        Void Function(Pointer<_LiteRtLmEngineSettings>, Bool),
        void Function(Pointer<_LiteRtLmEngineSettings>, bool)
      >('litert_lm_engine_settings_set_enable_speculative_decoding');

  late final engineSettingsSetCacheDir = _library
      .lookupFunction<
        Void Function(Pointer<_LiteRtLmEngineSettings>, Pointer<Char>),
        void Function(Pointer<_LiteRtLmEngineSettings>, Pointer<Char>)
      >('litert_lm_engine_settings_set_cache_dir');

  late final engineDelete = _library
      .lookupFunction<
        Void Function(Pointer<_LiteRtLmEngine>),
        void Function(Pointer<_LiteRtLmEngine>)
      >('litert_lm_engine_delete');

  late final engineTokenize = _library
      .lookupFunction<
        Pointer<_LiteRtLmTokenizeResult> Function(
          Pointer<_LiteRtLmEngine>,
          Pointer<Char>,
        ),
        Pointer<_LiteRtLmTokenizeResult> Function(
          Pointer<_LiteRtLmEngine>,
          Pointer<Char>,
        )
      >('litert_lm_engine_tokenize');

  late final tokenizeResultDelete = _library
      .lookupFunction<
        Void Function(Pointer<_LiteRtLmTokenizeResult>),
        void Function(Pointer<_LiteRtLmTokenizeResult>)
      >('litert_lm_tokenize_result_delete');

  late final tokenizeResultGetTokens = _library
      .lookupFunction<
        Pointer<Int> Function(Pointer<_LiteRtLmTokenizeResult>),
        Pointer<Int> Function(Pointer<_LiteRtLmTokenizeResult>)
      >('litert_lm_tokenize_result_get_tokens');

  late final tokenizeResultGetNumTokens = _library
      .lookupFunction<
        Size Function(Pointer<_LiteRtLmTokenizeResult>),
        int Function(Pointer<_LiteRtLmTokenizeResult>)
      >('litert_lm_tokenize_result_get_num_tokens');

  late final engineDetokenize = _library
      .lookupFunction<
        Pointer<_LiteRtLmDetokenizeResult> Function(
          Pointer<_LiteRtLmEngine>,
          Pointer<Int>,
          Size,
        ),
        Pointer<_LiteRtLmDetokenizeResult> Function(
          Pointer<_LiteRtLmEngine>,
          Pointer<Int>,
          int,
        )
      >('litert_lm_engine_detokenize');

  late final detokenizeResultDelete = _library
      .lookupFunction<
        Void Function(Pointer<_LiteRtLmDetokenizeResult>),
        void Function(Pointer<_LiteRtLmDetokenizeResult>)
      >('litert_lm_detokenize_result_delete');

  late final detokenizeResultGetString = _library
      .lookupFunction<
        Pointer<Char> Function(Pointer<_LiteRtLmDetokenizeResult>),
        Pointer<Char> Function(Pointer<_LiteRtLmDetokenizeResult>)
      >('litert_lm_detokenize_result_get_string');

  late final engineGetStartToken = _library
      .lookupFunction<
        Pointer<_LiteRtLmTokenUnion> Function(Pointer<_LiteRtLmEngine>),
        Pointer<_LiteRtLmTokenUnion> Function(Pointer<_LiteRtLmEngine>)
      >('litert_lm_engine_get_start_token');

  late final tokenUnionDelete = _library
      .lookupFunction<
        Void Function(Pointer<_LiteRtLmTokenUnion>),
        void Function(Pointer<_LiteRtLmTokenUnion>)
      >('litert_lm_token_union_delete');

  late final tokenUnionGetType = _library
      .lookupFunction<
        Int Function(Pointer<_LiteRtLmTokenUnion>),
        int Function(Pointer<_LiteRtLmTokenUnion>)
      >('litert_lm_token_union_get_type');

  late final tokenUnionGetString = _library
      .lookupFunction<
        Pointer<Char> Function(Pointer<_LiteRtLmTokenUnion>),
        Pointer<Char> Function(Pointer<_LiteRtLmTokenUnion>)
      >('litert_lm_token_union_get_string');

  late final tokenUnionGetIds = _library
      .lookupFunction<
        Int Function(
          Pointer<_LiteRtLmTokenUnion>,
          Pointer<Pointer<Int>>,
          Pointer<Size>,
        ),
        int Function(
          Pointer<_LiteRtLmTokenUnion>,
          Pointer<Pointer<Int>>,
          Pointer<Size>,
        )
      >('litert_lm_token_union_get_ids');

  late final sessionConfigCreate = _library
      .lookupFunction<
        Pointer<_LiteRtLmSessionConfig> Function(),
        Pointer<_LiteRtLmSessionConfig> Function()
      >('litert_lm_session_config_create');

  late final sessionConfigDelete = _library
      .lookupFunction<
        Void Function(Pointer<_LiteRtLmSessionConfig>),
        void Function(Pointer<_LiteRtLmSessionConfig>)
      >('litert_lm_session_config_delete');

  late final sessionConfigSetSamplerParams = _library
      .lookupFunction<
        Void Function(
          Pointer<_LiteRtLmSessionConfig>,
          Pointer<_LiteRtLmSamplerParams>,
        ),
        void Function(
          Pointer<_LiteRtLmSessionConfig>,
          Pointer<_LiteRtLmSamplerParams>,
        )
      >('litert_lm_session_config_set_sampler_params');

  late final conversationConfigCreate = _library
      .lookupFunction<
        Pointer<_LiteRtLmConversationConfig> Function(),
        Pointer<_LiteRtLmConversationConfig> Function()
      >('litert_lm_conversation_config_create');

  late final conversationConfigSetSessionConfig = _library
      .lookupFunction<
        Void Function(
          Pointer<_LiteRtLmConversationConfig>,
          Pointer<_LiteRtLmSessionConfig>,
        ),
        void Function(
          Pointer<_LiteRtLmConversationConfig>,
          Pointer<_LiteRtLmSessionConfig>,
        )
      >('litert_lm_conversation_config_set_session_config');

  late final conversationConfigSetSystemMessage = _library
      .lookupFunction<
        Void Function(Pointer<_LiteRtLmConversationConfig>, Pointer<Char>),
        void Function(Pointer<_LiteRtLmConversationConfig>, Pointer<Char>)
      >('litert_lm_conversation_config_set_system_message');

  late final conversationConfigSetEnableConstrainedDecoding = _library
      .lookupFunction<
        Void Function(Pointer<_LiteRtLmConversationConfig>, Bool),
        void Function(Pointer<_LiteRtLmConversationConfig>, bool)
      >('litert_lm_conversation_config_set_enable_constrained_decoding');

  late final conversationConfigDelete = _library
      .lookupFunction<
        Void Function(Pointer<_LiteRtLmConversationConfig>),
        void Function(Pointer<_LiteRtLmConversationConfig>)
      >('litert_lm_conversation_config_delete');

  late final conversationCreate = _library
      .lookupFunction<
        Pointer<_LiteRtLmConversation> Function(
          Pointer<_LiteRtLmEngine>,
          Pointer<_LiteRtLmConversationConfig>,
        ),
        Pointer<_LiteRtLmConversation> Function(
          Pointer<_LiteRtLmEngine>,
          Pointer<_LiteRtLmConversationConfig>,
        )
      >('litert_lm_conversation_create');

  late final conversationDelete = _library
      .lookupFunction<
        Void Function(Pointer<_LiteRtLmConversation>),
        void Function(Pointer<_LiteRtLmConversation>)
      >('litert_lm_conversation_delete');

  late final conversationOptionalArgsCreate = _library
      .lookupFunction<
        Pointer<_LiteRtLmConversationOptionalArgs> Function(),
        Pointer<_LiteRtLmConversationOptionalArgs> Function()
      >('litert_lm_conversation_optional_args_create');

  late final conversationOptionalArgsDelete = _library
      .lookupFunction<
        Void Function(Pointer<_LiteRtLmConversationOptionalArgs>),
        void Function(Pointer<_LiteRtLmConversationOptionalArgs>)
      >('litert_lm_conversation_optional_args_delete');

  late final conversationSendMessage = _library
      .lookupFunction<
        Pointer<_LiteRtLmJsonResponse> Function(
          Pointer<_LiteRtLmConversation>,
          Pointer<Char>,
          Pointer<Char>,
          Pointer<_LiteRtLmConversationOptionalArgs>,
        ),
        Pointer<_LiteRtLmJsonResponse> Function(
          Pointer<_LiteRtLmConversation>,
          Pointer<Char>,
          Pointer<Char>,
          Pointer<_LiteRtLmConversationOptionalArgs>,
        )
      >('litert_lm_conversation_send_message');

  late final jsonResponseDelete = _library
      .lookupFunction<
        Void Function(Pointer<_LiteRtLmJsonResponse>),
        void Function(Pointer<_LiteRtLmJsonResponse>)
      >('litert_lm_json_response_delete');

  late final jsonResponseGetString = _library
      .lookupFunction<
        Pointer<Char> Function(Pointer<_LiteRtLmJsonResponse>),
        Pointer<Char> Function(Pointer<_LiteRtLmJsonResponse>)
      >('litert_lm_json_response_get_string');

  late final conversationSendMessageStream = _library
      .lookupFunction<
        Int Function(
          Pointer<_LiteRtLmConversation>,
          Pointer<Char>,
          Pointer<Char>,
          Pointer<_LiteRtLmConversationOptionalArgs>,
          Pointer<NativeFunction<_StreamCallbackNative>>,
          Pointer<Void>,
        ),
        int Function(
          Pointer<_LiteRtLmConversation>,
          Pointer<Char>,
          Pointer<Char>,
          Pointer<_LiteRtLmConversationOptionalArgs>,
          Pointer<NativeFunction<_StreamCallbackNative>>,
          Pointer<Void>,
        )
      >('litert_lm_conversation_send_message_stream');

  late final conversationCancelProcess = _library
      .lookupFunction<
        Void Function(Pointer<_LiteRtLmConversation>),
        void Function(Pointer<_LiteRtLmConversation>)
      >('litert_lm_conversation_cancel_process');

  late final conversationGetBenchmarkInfo = _library
      .lookupFunction<
        Pointer<_LiteRtLmBenchmarkInfo> Function(
          Pointer<_LiteRtLmConversation>,
        ),
        Pointer<_LiteRtLmBenchmarkInfo> Function(Pointer<_LiteRtLmConversation>)
      >('litert_lm_conversation_get_benchmark_info');

  late final benchmarkInfoDelete = _library
      .lookupFunction<
        Void Function(Pointer<_LiteRtLmBenchmarkInfo>),
        void Function(Pointer<_LiteRtLmBenchmarkInfo>)
      >('litert_lm_benchmark_info_delete');

  late final benchmarkInfoGetTimeToFirstToken = _library
      .lookupFunction<
        Double Function(Pointer<_LiteRtLmBenchmarkInfo>),
        double Function(Pointer<_LiteRtLmBenchmarkInfo>)
      >('litert_lm_benchmark_info_get_time_to_first_token');

  late final benchmarkInfoGetTotalInitTimeInSecond = _library
      .lookupFunction<
        Double Function(Pointer<_LiteRtLmBenchmarkInfo>),
        double Function(Pointer<_LiteRtLmBenchmarkInfo>)
      >('litert_lm_benchmark_info_get_total_init_time_in_second');

  late final benchmarkInfoGetNumPrefillTurns = _library
      .lookupFunction<
        Int Function(Pointer<_LiteRtLmBenchmarkInfo>),
        int Function(Pointer<_LiteRtLmBenchmarkInfo>)
      >('litert_lm_benchmark_info_get_num_prefill_turns');

  late final benchmarkInfoGetNumDecodeTurns = _library
      .lookupFunction<
        Int Function(Pointer<_LiteRtLmBenchmarkInfo>),
        int Function(Pointer<_LiteRtLmBenchmarkInfo>)
      >('litert_lm_benchmark_info_get_num_decode_turns');

  late final benchmarkInfoGetPrefillTokenCountAt = _library
      .lookupFunction<
        Int Function(Pointer<_LiteRtLmBenchmarkInfo>, Int),
        int Function(Pointer<_LiteRtLmBenchmarkInfo>, int)
      >('litert_lm_benchmark_info_get_prefill_token_count_at');

  late final benchmarkInfoGetDecodeTokenCountAt = _library
      .lookupFunction<
        Int Function(Pointer<_LiteRtLmBenchmarkInfo>, Int),
        int Function(Pointer<_LiteRtLmBenchmarkInfo>, int)
      >('litert_lm_benchmark_info_get_decode_token_count_at');

  late final benchmarkInfoGetPrefillTokensPerSecAt = _library
      .lookupFunction<
        Double Function(Pointer<_LiteRtLmBenchmarkInfo>, Int),
        double Function(Pointer<_LiteRtLmBenchmarkInfo>, int)
      >('litert_lm_benchmark_info_get_prefill_tokens_per_sec_at');

  late final benchmarkInfoGetDecodeTokensPerSecAt = _library
      .lookupFunction<
        Double Function(Pointer<_LiteRtLmBenchmarkInfo>, Int),
        double Function(Pointer<_LiteRtLmBenchmarkInfo>, int)
      >('litert_lm_benchmark_info_get_decode_tokens_per_sec_at');
}

// coverage:ignore-end
