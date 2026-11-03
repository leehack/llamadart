import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../../core/exceptions.dart';
import '../../core/models/config/compute_device.dart';
import '../../core/models/inference/model_params.dart';
import 'litert_lm_last_error.dart';
import 'litert_lm_finish_reason.dart';
import 'litert_lm_native_settlement.dart';
import 'litert_lm_sampler_params.dart';

part 'litert_lm_v1_conversation.dart';
part 'litert_lm_v1_conversation_settings.dart';
part 'litert_lm_v1_engine_settings.dart';
part 'litert_lm_v1_turn_settings.dart';

typedef _VersionN = Int Function(Pointer<Int>, Pointer<Int>, Pointer<Int>);
typedef _VersionD = int Function(Pointer<Int>, Pointer<Int>, Pointer<Int>);
typedef _CreateN = Int Function(Pointer<Pointer<Void>>);
typedef _CreateD = int Function(Pointer<Pointer<Void>>);
typedef _CreateFromN = Int Function(Pointer<Void>, Pointer<Pointer<Void>>);
typedef _CreateFromD = int Function(Pointer<Void>, Pointer<Pointer<Void>>);
typedef _DeleteN = Void Function(Pointer<Void>);
typedef _DeleteD = void Function(Pointer<Void>);
typedef _SetIntN = Int Function(Pointer<Void>, Int);
typedef _SetIntD = int Function(Pointer<Void>, int);
typedef _SetPointerN = Int Function(Pointer<Void>, Pointer<Void>);
typedef _SetPointerD = int Function(Pointer<Void>, Pointer<Void>);
typedef _SetStringN = Int Function(Pointer<Void>, Pointer<Utf8>);
typedef _SetStringD = int Function(Pointer<Void>, Pointer<Utf8>);
typedef _SetBoolN = Int Function(Pointer<Void>, Bool);
typedef _SetBoolD = int Function(Pointer<Void>, bool);
typedef _SetFloatN = Int Function(Pointer<Void>, Float);
typedef _SetFloatD = int Function(Pointer<Void>, double);
typedef _SettingsN =
    Int Function(
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Pointer<Void>>,
    );
typedef _SettingsD =
    int Function(
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Pointer<Void>>,
    );
typedef _SessionN =
    Int Function(Pointer<Void>, Pointer<Void>, Pointer<Pointer<Void>>);
typedef _SessionD =
    int Function(Pointer<Void>, Pointer<Void>, Pointer<Pointer<Void>>);
typedef _SamplerN = Int Function(Int, Pointer<Pointer<Void>>);
typedef _SamplerD = int Function(int, Pointer<Pointer<Void>>);
typedef _InputN =
    Int Function(Int, Pointer<Void>, Size, Pointer<Pointer<Void>>);
typedef _InputD = int Function(int, Pointer<Void>, int, Pointer<Pointer<Void>>);
typedef _GenerateN =
    Int Function(
      Pointer<Void>,
      Pointer<Pointer<Void>>,
      Size,
      Pointer<Pointer<Void>>,
    );
typedef _GenerateD =
    int Function(
      Pointer<Void>,
      Pointer<Pointer<Void>>,
      int,
      Pointer<Pointer<Void>>,
    );
typedef _TextN = Int Function(Pointer<Void>, Size, Pointer<Pointer<Utf8>>);
typedef _TextD = int Function(Pointer<Void>, int, Pointer<Pointer<Utf8>>);

/// Internal C API 1.0 preparation adapter for CPU text operations.
///
/// This is not selected by the public runtime client. Its internal conversation
/// preparation is separate from raw sessions. ASR, embeddings and schemas remain
/// behind the public compatibility refusal until their separate migration is
/// complete. Handle operations run on the owning isolate; handles never escape it.
final class LiteRtLmV1Runtime {
  /// Opens a caller-supplied candidate library with exactly C API 1.0.x.
  LiteRtLmV1Runtime(DynamicLibrary library) : _library = library {
    if (!library.providesSymbol('litert_lm_get_api_version')) {
      throw LlamaUnsupportedException(
        'C API 1.0 adapter requires a versioned LiteRT-LM runtime; legacy libraries use the existing runtime client.',
      );
    }
    final parts = calloc<Int>(3);
    try {
      final status = library.lookupFunction<_VersionN, _VersionD>(
        'litert_lm_get_api_version',
      )(parts, parts + 1, parts + 2);
      if (status != 0 || parts[0] != 1 || parts[1] != 0 || parts[2] < 0) {
        throw LlamaUnsupportedException(
          'C API 1.0 adapter rejects version ${parts[0]}.${parts[1]}.${parts[2]} (probe status $status).',
        );
      }
    } finally {
      calloc.free(parts);
    }
    for (final symbol in _requiredSymbols) {
      if (!library.providesSymbol(symbol)) {
        throw LlamaUnsupportedException(
          'LiteRT-LM C API 1.0 runtime is missing required preparation export $symbol.',
        );
      }
    }
  }

  static const _requiredSymbols = <String>[
    'litert_lm_get_last_error_message',
    'litert_lm_engine_settings_create',
    'litert_lm_engine_settings_delete',
    'litert_lm_engine_settings_set_num_threads',
    'litert_lm_engine_settings_set_max_num_tokens',
    'litert_lm_engine_settings_set_cache_dir',
    ..._engineSettingsSymbols,
    'litert_lm_engine_create',
    'litert_lm_engine_delete',
    'litert_lm_session_config_create',
    'litert_lm_session_config_delete',
    'litert_lm_session_config_set_max_output_tokens',
    'litert_lm_session_config_set_apply_prompt_template',
    'litert_lm_session_config_set_sampler_params',
    'litert_lm_sampler_params_create',
    'litert_lm_sampler_params_set_top_k',
    'litert_lm_sampler_params_set_top_p',
    'litert_lm_sampler_params_set_temperature',
    'litert_lm_sampler_params_delete',
    'litert_lm_engine_create_session',
    'litert_lm_session_delete',
    'litert_lm_input_data_create',
    'litert_lm_input_data_delete',
    'litert_lm_session_generate_content',
    'litert_lm_responses_get_response_text_at',
    'litert_lm_responses_delete',
  ];

  final DynamicLibrary _library;
  Pointer<Void> _engine = nullptr;
  ComputeDevice? _engineBackend;
  bool _engineSpeculativeDecoding = false;
  bool _disposed = false;
  LiteRtLmV1Conversation? _conversation;
  List<String> _diagnosticPaths = const [];

  /// Native lifetime, independent of whether a turn's done future rejected.
  LiteRtLmNativeSettlement get nativeSettlement =>
      _conversation?.nativeSettlement ?? LiteRtLmNativeSettlement.settled;

  late final _message = _library
      .lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>(
        'litert_lm_get_last_error_message',
      );
  late final _settingsCreate = _library.lookupFunction<_SettingsN, _SettingsD>(
    'litert_lm_engine_settings_create',
  );
  late final _settingsDelete = _library.lookupFunction<_DeleteN, _DeleteD>(
    'litert_lm_engine_settings_delete',
  );
  late final _setThreads = _library.lookupFunction<_SetIntN, _SetIntD>(
    'litert_lm_engine_settings_set_num_threads',
  );
  late final _setContext = _library.lookupFunction<_SetIntN, _SetIntD>(
    'litert_lm_engine_settings_set_max_num_tokens',
  );
  late final _setCache = _library.lookupFunction<_SetStringN, _SetStringD>(
    'litert_lm_engine_settings_set_cache_dir',
  );
  late final _engineCreate = _library
      .lookupFunction<_CreateFromN, _CreateFromD>('litert_lm_engine_create');
  late final _engineDelete = _library.lookupFunction<_DeleteN, _DeleteD>(
    'litert_lm_engine_delete',
  );
  late final _configCreate = _library.lookupFunction<_CreateN, _CreateD>(
    'litert_lm_session_config_create',
  );
  late final _configDelete = _library.lookupFunction<_DeleteN, _DeleteD>(
    'litert_lm_session_config_delete',
  );
  late final _setOutputTokens = _library.lookupFunction<_SetIntN, _SetIntD>(
    'litert_lm_session_config_set_max_output_tokens',
  );
  late final _setApplyTemplate = _library.lookupFunction<_SetBoolN, _SetBoolD>(
    'litert_lm_session_config_set_apply_prompt_template',
  );
  late final _setSampler = _library.lookupFunction<_SetPointerN, _SetPointerD>(
    'litert_lm_session_config_set_sampler_params',
  );
  late final _samplerCreate = _library.lookupFunction<_SamplerN, _SamplerD>(
    'litert_lm_sampler_params_create',
  );
  late final _samplerTopK = _library.lookupFunction<_SetIntN, _SetIntD>(
    'litert_lm_sampler_params_set_top_k',
  );
  late final _samplerTopP = _library.lookupFunction<_SetFloatN, _SetFloatD>(
    'litert_lm_sampler_params_set_top_p',
  );
  late final _samplerTemperature = _library
      .lookupFunction<_SetFloatN, _SetFloatD>(
        'litert_lm_sampler_params_set_temperature',
      );
  late final _samplerDelete = _library.lookupFunction<_DeleteN, _DeleteD>(
    'litert_lm_sampler_params_delete',
  );
  late final _sessionCreate = _library.lookupFunction<_SessionN, _SessionD>(
    'litert_lm_engine_create_session',
  );
  late final _sessionDelete = _library.lookupFunction<_DeleteN, _DeleteD>(
    'litert_lm_session_delete',
  );
  late final _inputCreate = _library.lookupFunction<_InputN, _InputD>(
    'litert_lm_input_data_create',
  );
  late final _inputDelete = _library.lookupFunction<_DeleteN, _DeleteD>(
    'litert_lm_input_data_delete',
  );
  late final _generate = _library.lookupFunction<_GenerateN, _GenerateD>(
    'litert_lm_session_generate_content',
  );
  late final _getText = _library.lookupFunction<_TextN, _TextD>(
    'litert_lm_responses_get_response_text_at',
  );
  late final _responsesDelete = _library.lookupFunction<_DeleteN, _DeleteD>(
    'litert_lm_responses_delete',
  );

  void _check(int status, String operation) {
    if (status == 0) return;
    final message = _message();
    throw LlamaModelException(
      '$operation failed: ${liteRtLmNativeErrorDetail(code: status, message: message == nullptr ? '' : message.toDartString(), paths: _diagnosticPaths)}',
    );
  }

  Pointer<Void> _create(
    String operation,
    int Function(Pointer<Pointer<Void>>) call,
  ) {
    final output = calloc<Pointer<Void>>();
    try {
      _check(call(output), operation);
      if (output.value == nullptr) {
        throw LlamaStateException(
          '$operation reported success without an owned handle.',
        );
      }
      return output.value;
    } finally {
      calloc.free(output);
    }
  }

  void _requireLive() {
    if (_disposed) throw LlamaStateException('C API 1.0 adapter is disposed.');
  }

  void _requireNoConversation() {
    if (_conversation != null) {
      throw LlamaStateException(
        'Close the C API 1.0 conversation before changing or using its engine directly.',
      );
    }
  }

  /// Creates a CPU candidate with explicit context, cache and thread settings.
  ///
  /// Use [loadConfigured] for nullable threads (runtime selection) and the other
  /// internal engine settings. This wrapper preserves four explicit CPU threads.
  void load(
    String modelPath, {
    required String cacheDir,
    int contextSize = 4096,
    int numberOfThreads = 4,
  }) {
    _requireLive();
    _requireNoConversation();
    if (cacheDir.isEmpty) {
      throw LlamaArgumentException(
        'C API 1.0 load requires a nonempty cache path.',
      );
    }
    loadConfigured(
      modelPath,
      LiteRtLmV1EngineSettings(
        cacheDir: cacheDir,
        contextSize: contextSize,
        numberOfThreads: numberOfThreads,
      ),
    );
  }

  /// Loads internal v1 settings without device fallback or public selection.
  ///
  /// Native status failures preserve the previous engine. Backend strings are
  /// transported, not qualified for the current platform/model. Every optional
  /// unset setting remains the runtime default. No single-threaded execution is
  /// enabled: listener callbacks require independent native progress.
  void loadConfigured(String modelPath, LiteRtLmV1EngineSettings options) {
    _requireLive();
    _requireNoConversation();
    options._validate(modelPath);
    final oldDiagnosticPaths = _diagnosticPaths;
    final diagnosticPaths = [
      modelPath,
      ?options.cacheDir,
      ?options.dispatchLibDir,
    ];
    _diagnosticPaths = [...oldDiagnosticPaths, ...diagnosticPaths];
    final strings = <Pointer<Utf8>>[];
    Pointer<Utf8> owned(String? value) {
      if (value == null) return nullptr;
      final pointer = value.toNativeUtf8(allocator: calloc);
      strings.add(pointer);
      return pointer;
    }

    Pointer<Void> settings = nullptr;
    try {
      final model = owned(modelPath);
      final backend = owned(options.backend.name);
      final vision = owned(options.visionBackend?.name);
      final audio = owned(options.audioBackend?.name);
      settings = _create(
        'engine_settings_create',
        (out) => _settingsCreate(model, backend, vision, audio, out),
      );
      _check(_setContext(settings, options.contextSize), 'set_max_num_tokens');
      if (options.numberOfThreads case final threads?) {
        _check(_setThreads(settings, threads), 'set_num_threads');
      }
      if (options.cacheDir case final cache?) {
        _check(_setCache(settings, owned(cache)), 'set_cache_dir');
      }
      _applyEngineSettings(settings, options, owned);
      final engine = _create(
        'engine_create',
        (out) => _engineCreate(settings, out),
      );
      if (_engine != nullptr) _engineDelete(_engine);
      _engine = engine;
      _engineBackend = options.backend;
      _engineSpeculativeDecoding = options.speculativeDecoding;
      _diagnosticPaths = diagnosticPaths;
    } on Object {
      _diagnosticPaths = oldDiagnosticPaths;
      rethrow;
    } finally {
      if (settings != nullptr) _settingsDelete(settings);
      for (final pointer in strings) {
        calloc.free(pointer);
      }
    }
  }

  /// Generates synchronously with a new greedy text session for every request.
  ///
  /// No stream callback, tool loop, media or cancellation is exposed by this
  /// preparation adapter. The session and every temporary handle are deleted
  /// before returning, including on a native status failure.
  String generateText(String prompt, {int maxOutputTokens = 32}) {
    _requireLive();
    _requireNoConversation();
    if (_engine == nullptr) {
      throw LlamaStateException('Load a C API 1.0 engine before generation.');
    }
    if (maxOutputTokens <= 0 ||
        maxOutputTokens > 0x7fffffff ||
        prompt.contains('\u0000')) {
      throw LlamaArgumentException(
        'Text must not contain NUL and maxOutputTokens must be positive.',
      );
    }
    Pointer<Void> config = nullptr,
        sampler = nullptr,
        session = nullptr,
        input = nullptr,
        responses = nullptr;
    final text = prompt.toNativeUtf8(allocator: calloc);
    final inputs = calloc<Pointer<Void>>();
    final outputText = calloc<Pointer<Utf8>>();
    try {
      config = _create('session_config_create', _configCreate);
      _check(_setApplyTemplate(config, false), 'set_apply_prompt_template');
      _check(
        _setOutputTokens(config, maxOutputTokens),
        'set_max_output_tokens',
      );
      sampler = _create(
        'sampler_params_create',
        (out) => _samplerCreate(2, out),
      );
      // The declared Greedy enum is unimplemented in the candidate runtime.
      // TopP with top-k 1 and temperature 0 selects deterministic decoding.
      _check(_samplerTopK(sampler, 1), 'sampler_set_top_k');
      _check(_samplerTopP(sampler, 0.95), 'sampler_set_top_p');
      _check(_samplerTemperature(sampler, 0), 'sampler_set_temperature');
      _check(_setSampler(config, sampler), 'set_sampler_params');
      session = _create(
        'engine_create_session',
        (out) => _sessionCreate(_engine, config, out),
      );
      input = _create(
        'input_data_create',
        (out) => _inputCreate(0, text.cast(), text.length, out),
      );
      inputs.value = input;
      responses = _create(
        'session_generate_content',
        (out) => _generate(session, inputs, 1, out),
      );
      _check(
        _getText(responses, 0, outputText),
        'responses_get_response_text_at',
      );
      if (outputText.value == nullptr) {
        throw LlamaStateException('Response has no text pointer.');
      }
      return outputText.value.toDartString();
    } finally {
      if (responses != nullptr) _responsesDelete(responses);
      if (input != nullptr) _inputDelete(input);
      if (session != nullptr) _sessionDelete(session);
      if (sampler != nullptr) _samplerDelete(sampler);
      if (config != nullptr) _configDelete(config);
      calloc.free(text);
      calloc.free(inputs);
      calloc.free(outputText);
    }
  }

  /// Opens one internal text conversation on the loaded CPU engine.
  ///
  /// The owner bridge must copy callback strings with stream-chunk ABI 2.
  /// Close the conversation before engine reload, raw generation or disposal.
  LiteRtLmV1Conversation openConversation({int maxOutputTokens = 32}) {
    _requireLive();
    _requireNoConversation();
    return openConfiguredConversation(
      LiteRtLmV1ConversationSettings(
        maxOutputTokens: maxOutputTokens,
        sampler: const LiteRtLmV1SamplerSettings(
          temperature: 0,
          topK: 1,
          topP: 0.95,
          seed: 0,
        ),
      ),
    );
  }

  /// Opens a snapshotted text/tool-history configuration without public routing.
  /// Null sampler preserves native inheritance; explicit NPU sampling is refused.
  LiteRtLmV1Conversation openConfiguredConversation(
    LiteRtLmV1ConversationSettings options,
  ) {
    _requireLive();
    _requireNoConversation();
    if (_engine == nullptr) {
      throw LlamaStateException('Load a C API 1.0 engine first.');
    }
    options._validate(_engineBackend!);
    return _conversation = LiteRtLmV1Conversation._(this, options);
  }

  /// Releases the owned engine exactly once. Disposal is final.
  void dispose() {
    if (_disposed) return;
    _requireNoConversation();
    _disposed = true;
    if (_engine != nullptr) _engineDelete(_engine);
    _engine = nullptr;
  }
}
