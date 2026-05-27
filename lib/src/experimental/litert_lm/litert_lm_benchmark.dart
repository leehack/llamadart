// ignore_for_file: public_member_api_docs

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as path;

const _litertLmVersion = '0.12.0';
const _litertLmLibDirEnv = 'LLAMADART_LITERT_LM_LIB_DIR';

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

class LiteRtLmBenchmarkMetrics {
  final int inputTokens;
  final int outputTokens;
  final double? timeToFirstTokenSeconds;
  final double? initSeconds;
  final double? prefillTokensPerSecond;
  final double? decodeTokensPerSecond;
  final int wallMilliseconds;

  const LiteRtLmBenchmarkMetrics({
    required this.inputTokens,
    required this.outputTokens,
    required this.timeToFirstTokenSeconds,
    required this.initSeconds,
    required this.prefillTokensPerSecond,
    required this.decodeTokensPerSecond,
    required this.wallMilliseconds,
  });

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

class LiteRtLmBenchmarkResult {
  final String text;
  final LiteRtLmBenchmarkMetrics metrics;

  const LiteRtLmBenchmarkResult({required this.text, required this.metrics});
}

class LiteRtLmBenchmarkClient {
  _LiteRtLmBindings? _bindings;
  // Keep a strong reference while callbacks/function pointers may be active.
  // ignore: unused_field
  DynamicLibrary? _proxyLibrary;
  _ProxyCreateDart? _proxyCreate;
  _ProxyFreeStringDart? _proxyFreeString;
  String? _liteRtLmLibraryPath;
  Pointer<_LiteRtLmEngine>? _engine;
  Pointer<_LiteRtLmConversation>? _conversation;

  Future<void> initialize({
    required String modelPath,
    String backend = 'gpu',
    int maxTokens = 4096,
    int outputTokens = 256,
    int? prefillTokens,
    String? cacheDir,
    bool speculativeDecoding = true,
  }) async {
    _ensureLibrariesLoaded();
    final bindings = _bindings!;
    final modelPathPtr = modelPath.toNativeUtf8();
    final backendPtr = backend.toNativeUtf8();
    final cacheDirPtr = cacheDir?.toNativeUtf8();

    try {
      final settings = bindings.engineSettingsCreate(
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
      bindings.engineSettingsDelete(settings);
      if (engineAddress == 0) {
        throw StateError('litert_lm_engine_create returned null');
      }
      _engine = Pointer<_LiteRtLmEngine>.fromAddress(engineAddress);
    } finally {
      calloc.free(modelPathPtr);
      calloc.free(backendPtr);
      if (cacheDirPtr != null) {
        calloc.free(cacheDirPtr);
      }
    }
  }

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
    final bindings = _requireBindings();
    final conversation = _requireConversation();
    final controller = StreamController<String>();

    Future<void>(() {
      final messagePtr = _messageJson(prompt).toNativeUtf8();
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
            throw StateError(
              'litert_lm_json_response_get_string returned null',
            );
          }
          final text = _extractText(rawPtr.cast<Utf8>().toDartString());
          if (text.isNotEmpty) {
            controller.add(text);
          }
        } finally {
          bindings.jsonResponseDelete(response);
        }
      } catch (error, stackTrace) {
        controller.addError(error, stackTrace);
      } finally {
        if (optionalArgs != nullptr) {
          bindings.conversationOptionalArgsDelete(optionalArgs);
        }
        calloc.free(messagePtr);
        unawaited(controller.close());
      }
    });

    return controller.stream;
  }

  Stream<String> _generateStreaming(String prompt) {
    final bindings = _requireBindings();
    final conversation = _requireConversation();
    final controller = StreamController<String>();
    final messagePtr = _messageJson(prompt).toNativeUtf8();

    late final NativeCallable<_StreamCallbackNative> callable;
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
        callable.close();
        calloc.free(messagePtr);
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
        callable.close();
        calloc.free(messagePtr);
      }
    });

    var callbackFn = callable.nativeFunction;
    Pointer<Void> callbackData = nullptr;
    final proxyCreate = _proxyCreate;
    if (proxyCreate != null) {
      final outProxyFn =
          calloc<Pointer<NativeFunction<_StreamCallbackNative>>>();
      callbackData = proxyCreate(callable.nativeFunction, nullptr, outProxyFn);
      callbackFn = outProxyFn.value;
      calloc.free(outProxyFn);
    }

    final optionalArgs = bindings.conversationOptionalArgsCreate();
    if (optionalArgs == nullptr) {
      callable.close();
      calloc.free(messagePtr);
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
    bindings.conversationOptionalArgsDelete(optionalArgs);
    if (rc != 0) {
      callable.close();
      calloc.free(messagePtr);
      throw StateError('litert_lm_conversation_send_message_stream rc=$rc');
    }

    return controller.stream;
  }

  Future<LiteRtLmBenchmarkResult> run({
    required String prompt,
    int warmupRuns = 1,
    int measuredRuns = 3,
  }) async {
    for (var i = 0; i < warmupRuns; i++) {
      createConversation();
      await generate(prompt).drain<void>();
    }

    var lastText = '';
    late LiteRtLmBenchmarkMetrics metrics;
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

    return LiteRtLmBenchmarkResult(text: lastText, metrics: metrics);
  }

  LiteRtLmBenchmarkMetrics readMetrics({required int wallMilliseconds}) {
    return _readMetrics(wallMilliseconds);
  }

  void cancel() {
    final conversation = _conversation;
    final bindings = _bindings;
    if (conversation != null && conversation != nullptr && bindings != null) {
      bindings.conversationCancelProcess(conversation);
    }
  }

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
        final liteRtLmName = libraries.liteRtLm.toNativeUtf8();
        try {
          final handle = loadGlobal(liteRtLmName);
          if (handle == nullptr) {
            throw StateError(
              'Failed to load ${libraries.liteRtLm} with RTLD_GLOBAL',
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
        _proxyLibrary = proxyLibrary;
      } catch (error) {
        if (!libraries.directCallbackSupported) {
          rethrow;
        }
      }
    }

    _liteRtLmLibraryPath = libraries.liteRtLm;
    _bindings = _LiteRtLmBindings(DynamicLibrary.open(libraries.liteRtLm));
  }

  ({
    List<String> proxyCandidates,
    String liteRtLm,
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
        liteRtLm: 'libLiteRtLm.so',
        companions: const [],
        directCallbackSupported: true,
      );
    }
    if (Platform.isMacOS && (abi == Abi.macosArm64 || abi == Abi.macosX64)) {
      final frameworksDir = _findMacOsAppFrameworksDir();
      if (frameworksDir != null) {
        return (
          proxyCandidates: [
            '${frameworksDir.path}/StreamProxy.framework/Versions/A/StreamProxy',
            'package:llamadart/litert_lm_StreamProxy',
            'libStreamProxy.dylib',
          ],
          liteRtLm:
              '${frameworksDir.path}/LiteRtLm.framework/Versions/A/LiteRtLm',
          companions: [
            '${frameworksDir.path}/LiteRt.framework/LiteRt',
            '${frameworksDir.path}/GemmaModelConstraintProvider.framework/'
                'GemmaModelConstraintProvider',
            '${frameworksDir.path}/LiteRtMetalAccelerator.framework/'
                'LiteRtMetalAccelerator',
            '${frameworksDir.path}/LiteRtTopKMetalSampler.framework/'
                'LiteRtTopKMetalSampler',
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
          liteRtLm: '${cacheDir.path}/libLiteRtLm.dylib',
          companions: [
            '${cacheDir.path}/libLiteRt.dylib',
            '${cacheDir.path}/libGemmaModelConstraintProvider.dylib',
            '${cacheDir.path}/libLiteRtMetalAccelerator.dylib',
            '${cacheDir.path}/libLiteRtTopKMetalSampler.dylib',
          ],
          directCallbackSupported: true,
        );
      }
      return (
        proxyCandidates: const [
          'package:llamadart/litert_lm_StreamProxy',
          'libStreamProxy.dylib',
        ],
        liteRtLm: 'libLiteRtLm.dylib',
        companions: const [
          'libGemmaModelConstraintProvider.dylib',
          'libLiteRtMetalAccelerator.dylib',
        ],
        directCallbackSupported: true,
      );
    }
    if (Platform.isLinux && (abi == Abi.linuxX64 || abi == Abi.linuxArm64)) {
      return (
        proxyCandidates: const [],
        liteRtLm: 'libLiteRtLm.so',
        companions: const [],
        directCallbackSupported: true,
      );
    }
    if (Platform.isWindows && abi == Abi.windowsX64) {
      return (
        proxyCandidates: const [],
        liteRtLm: 'LiteRtLm.dll',
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

  Directory? _findMacOsAppFrameworksDir() {
    final executable = File(Platform.resolvedExecutable);
    final contentsDir = executable.parent.parent;
    final frameworksDir = Directory('${contentsDir.path}/Frameworks');
    if (!frameworksDir.existsSync()) {
      return null;
    }
    final requiredFiles = [
      '${frameworksDir.path}/LiteRtLm.framework/Versions/A/LiteRtLm',
      '${frameworksDir.path}/StreamProxy.framework/Versions/A/StreamProxy',
      '${frameworksDir.path}/GemmaModelConstraintProvider.framework/'
          'GemmaModelConstraintProvider',
      '${frameworksDir.path}/LiteRtMetalAccelerator.framework/'
          'LiteRtMetalAccelerator',
    ];
    if (requiredFiles.every((file) => File(file).existsSync())) {
      return frameworksDir;
    }
    return null;
  }

  Directory? _findMacOsLiteRtLmCacheDir() {
    final envPath = Platform.environment[_litertLmLibDirEnv];
    if (envPath != null && envPath.isNotEmpty) {
      final dir = Directory(envPath);
      if (_isMacOsLiteRtLmDir(dir)) {
        return dir;
      }
    }

    for (final root in _candidateSearchRoots()) {
      Directory? current = root;
      while (current != null) {
        final candidate = Directory(
          '${current.path}/.dart_tool/llamadart/litert_lm/'
          '$_litertLmVersion/macos_arm64',
        );
        if (_isMacOsLiteRtLmDir(candidate)) {
          return candidate;
        }
        final nativeCandidate = Directory(
          '${current.path}/.dart_tool/llamadart/litert_lm/'
          '$_litertLmVersion/macos/arm64',
        );
        if (_isMacOsLiteRtLmDir(nativeCandidate)) {
          return nativeCandidate;
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

  bool _isMacOsLiteRtLmDir(Directory dir) {
    return File('${dir.path}/libLiteRtLm.dylib').existsSync();
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

  LiteRtLmBenchmarkMetrics _readMetrics(int wallMilliseconds) {
    final bindings = _requireBindings();
    final conversation = _requireConversation();
    final info = bindings.conversationGetBenchmarkInfo(conversation);
    if (info == nullptr) {
      return LiteRtLmBenchmarkMetrics(
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
      return LiteRtLmBenchmarkMetrics(
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

String _messageJson(String text) {
  return jsonEncode({
    'role': 'user',
    'content': [
      {'type': 'text', 'text': text},
    ],
  });
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
