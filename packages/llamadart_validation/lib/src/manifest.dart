import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:llamadart/llamadart.dart';

import 'case_catalog.dart';

/// Canonical encoding for stable experiment identity.
String canonicalJson(Object? value) {
  Object? ordered(Object? value) {
    if (value is Map) {
      final keys = value.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: ordered(value[key])};
    }
    if (value is List) return value.map(ordered).toList();
    return value;
  }

  return jsonEncode(ordered(value));
}

/// SHA256 identity of a JSON-compatible value.
Object? freezeJson(Object? value) => value is Map
    ? Map<String, dynamic>.unmodifiable(
        value.map((key, item) => MapEntry(key as String, freezeJson(item))),
      )
    : value is List
    ? List<dynamic>.unmodifiable(value.map(freezeJson))
    : value;

/// SHA256 identity of a JSON-compatible value.
String jsonHash(Object? value) =>
    sha256.convert(utf8.encode(canonicalJson(value))).toString();

/// Locked model and inference selection shared by every host adapter.
class ValidationProfile {
  /// Validates an immutable model/profile manifest before use.
  ValidationProfile.fromJson(Map<String, dynamic> input)
    : data = freezeJson(jsonDecode(jsonEncode(input))) as Map<String, dynamic> {
    if (data['schema_version'] != 1) {
      throw const FormatException('Unsupported validation schema_version');
    }
    if (!RegExp(r'^[a-z][a-z0-9-]{0,63}$').hasMatch(id)) {
      throw const FormatException('Invalid profile id');
    }
    if (!const ['gguf', 'litert'].contains(runtime)) {
      throw const FormatException('runtime must be gguf or litert');
    }
    final validBackends = runtime == 'litert'
        ? ['cpu', 'gpu', 'npu', 'auto']
        : GpuBackend.values.map((value) => value.name).toList();
    if (!validBackends.contains(backend)) {
      throw FormatException('Invalid $runtime backend: $backend');
    }
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(modelHash) ||
        !RegExp(
          r'^[0-9a-f]{40}$',
        ).hasMatch(model['revision'] as String? ?? '')) {
      throw const FormatException(
        'Model requires SHA256 and immutable revision',
      );
    }
    final uri = Uri.parse(model['url'] as String);
    if (uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        !uri.path.contains('/${model['revision']}/')) {
      throw const FormatException('Use a public, immutable HTTPS model URL');
    }
    if (!filename.endsWith(runtime == 'gguf' ? '.gguf' : '.litertlm') ||
        !RegExp(r'^[a-zA-Z0-9_.-]+$').hasMatch(filename) ||
        (model['bytes'] as int) <= 0) {
      throw const FormatException('Invalid model filename, format or size');
    }
    if (!const ['raw', 'chat'].contains(model['kind'])) {
      throw const FormatException('Model kind must be raw or chat');
    }
    if (contextSize < 128 ||
        contextSize > 8192 ||
        maxTokens < 1 ||
        maxTokens > 512 ||
        threads < 1 ||
        threads > 32) {
      throw const FormatException('Profile exceeds bounded core limits');
    }
    if (!const ['quick', 'focused', 'release'].contains(selection)) {
      throw const FormatException(
        'selection must be quick, focused or release',
      );
    }
    final focus = data['focus_features'] ?? const [];
    if (focus is! List ||
        focus.any((feature) => !validationFeatures.containsKey(feature)) ||
        focus.toSet().length != focus.length ||
        (selection != 'focused' && data.containsKey('focus_features')) ||
        (selection == 'focused') != focus.isNotEmpty) {
      throw const FormatException(
        'Only focused selection requires a nonempty unique focus_features list '
        'of catalog feature IDs',
      );
    }
    final overrides = data['fixtures'];
    if (overrides != null &&
        (overrides is! Map ||
            overrides.entries.any(
              (entry) =>
                  !validationFixtures.containsKey(entry.key) ||
                  entry.value is! Map ||
                  (entry.value as Map).entries.any(
                    (field) =>
                        !validationFixtures[entry.key]!.containsKey(
                          field.key,
                        ) ||
                        // Core overrides are synthetic text/predicate fixtures;
                        // tool/media schemas need their own qualified pack.
                        field.value is! String ||
                        validationFixtures[entry.key]![field.key] is! String,
                  ),
            ))) {
      throw const FormatException('Invalid core fixture override');
    }
    for (final key in ['enable_thinking', 'history_controls']) {
      if (data.containsKey(key) && data[key] is! bool) {
        throw FormatException('$key must be a boolean');
      }
    }
    if (data['history_controls'] == true &&
        (runtime != 'litert' || backend != 'cpu' || !isChat)) {
      throw const FormatException(
        'Optional history controls require a LiteRT CPU chat profile',
      );
    }
    if (!const [
          'public_api',
          'native_c_api',
        ].contains(data['execution_path'] ?? 'public_api') ||
        (nativeReference && backend != 'npu')) {
      throw const FormatException(
        'Native C API controls require an explicit NPU profile',
      );
    }
    if (nativeReference && !enableThinking) {
      throw const FormatException(
        'Native C API controls currently require thinking enabled',
      );
    }
  }

  /// JSON definition; callers receive a defensive copy through [toJson].
  final Map<String, dynamic> data;

  /// Stable profile identifier.
  String get id => data['id'] as String;

  /// Model format/runtime identity.
  String get runtime => data['runtime'] as String;

  /// Explicit runtime selector.
  String get backend => data['backend'] as String;

  /// Immutable model definition.
  Map<String, dynamic> get model => data['model'] as Map<String, dynamic>;

  /// Expected bytes SHA256.
  String get modelHash => model['sha256'] as String;

  /// Safe local model basename.
  String get filename => model['filename'] as String;

  /// Whether semantic chat cases apply.
  bool get isChat => model['kind'] == 'chat';

  /// Context token budget.
  int get contextSize => data['context_size'] as int? ?? 1024;

  /// Maximum generation length.
  int get maxTokens => data['max_tokens'] as int? ?? 32;

  /// Native inference threads.
  int get threads => data['threads'] as int? ?? 4;

  /// Catalog selection; release includes explicit uncovered obligations.
  String get selection => data['selection'] as String? ?? 'quick';

  /// Canonical feature set used only by focused runs.
  List<String> get focusFeatures =>
      List<String>.from(data['focus_features'] as List? ?? const [])..sort();

  /// Separate direct-C-API controls from public-package qualification.
  bool get nativeReference => data['execution_path'] == 'native_c_api';

  /// Explicit model setting; preserves existing NPU and Qwen pilot defaults.
  bool get enableThinking =>
      data['enable_thinking'] as bool? ?? backend == 'npu';

  /// Adds the same seeded, literal-system, no-system and combined diagnostics.
  bool get historyControls =>
      nativeReference || data['history_controls'] == true;

  List<String> get _quickCaseIds => [
    'C01.load',
    if (!nativeReference) ...['C02.unicode', 'C03.raw'],
    if (isChat) ...['C04.hello', 'C04.arithmetic'],
    if (isChat) 'C06.history',
    if (historyControls && isChat) ...[
      'C06.history.public_system_wire',
      'C06.history.no_system',
      'C06.history.combined',
    ],
    if (!nativeReference) 'C08.cancel',
    'C09.reload',
    if (!nativeReference) ...['C10.limit', 'C12.recovery'],
    'B01.warmup',
    'B01.1',
    'B01.2',
    'B01.3',
  ];

  /// Original journal-v1 obligations, retained for existing report imports.
  List<String> get legacyCaseIds => [
    ..._quickCaseIds,
    if (selection == 'release') ...[
      'C05.thinking',
      'C07.tools',
      'C10.stop',
      'C11.batching',
      'C12.guards',
    ],
  ];

  /// Expanded obligations; a focused run adds relevant cases to the quick core.
  List<String> get caseIds {
    final quick = _quickCaseIds;
    return [
      ...quick,
      for (final definition in extendedValidationCases)
        if (selection == 'release' ||
            (selection == 'focused' &&
                definition.features.any(focusFeatures.contains)))
          definition.id,
    ];
  }

  /// Resolved synthetic fixtures, including explicit model-specific overrides.
  Map<String, dynamic> get fixtures {
    final overrides = data['fixtures'] as Map? ?? const {};
    return {
      for (final entry in validationFixtures.entries)
        entry.key: {...entry.value, ...?overrides[entry.key] as Map?},
    };
  }

  /// Text read by the runner and included in the replay catalog.
  String fixtureText(String fixture, String field) =>
      (fixtures[fixture] as Map)[field] as String;

  /// The resolved fixtures whose identity is bound to one case record.
  Map<String, dynamic> caseFixtures(String id) => {
    for (final key in validationCase(id).fixtures) key: fixtures[key],
  };

  /// Versioned selected/omitted inventory with reproducible fixture contents.
  Map<String, dynamic> get catalog => {
    'version': 1,
    'features': validationFeatures,
    'selection': selection,
    'focus_features': focusFeatures,
    'fixtures': fixtures,
    'cases': [
      for (final definition in validationCaseCatalog)
        {
          ...definition.toJson(),
          'selected': caseIds.contains(definition.id),
          if (!caseIds.contains(definition.id))
            'omission_reason': _omissionReason(definition.id),
        },
    ],
  };

  String _omissionReason(String id) {
    if (id.startsWith('C06.history.') && !historyControls) {
      return 'history_controls_disabled';
    }
    if (!isChat && (id.startsWith('C04.') || id.startsWith('C06.'))) {
      return 'raw_model_has_no_chat_oracle';
    }
    if (nativeReference &&
        const [
          'C02.unicode',
          'C03.raw',
          'C08.cancel',
          'C10.limit',
          'C12.recovery',
        ].contains(id)) {
      return 'outside_native_reference_scope';
    }
    return 'outside_selected_features';
  }

  /// Accelerator evidence is mandatory for an explicit accelerator selection.
  bool get requiresAcceleratorProof =>
      !['cpu', 'auto', 'blas'].contains(backend);

  /// NPU candidates require the installed Android host to verify the kit first.
  void requireRunnable({bool verifiedAndroidNpuHost = false}) {
    if (backend == 'npu' && !verifiedAndroidNpuHost) {
      throw LlamaUnsupportedException(
        'NPU validation needs installed-app vendor packaging, SoC checks and '
        'per-generation execution proof. Use validation.dart npu-preflight '
        'to inspect the locked inputs without downloading or loading a model.',
      );
    }
  }

  /// Configuration actually passed to the public model loader.
  ModelParams get loadParams => ModelParams(
    contextSize: contextSize,
    gpuLayers: backend == 'cpu' ? 0 : ModelParams.maxGpuLayers,
    preferredBackend: runtime == 'gguf'
        ? GpuBackend.values.byName(backend)
        : GpuBackend.cpu,
    liteRtLmBackend: runtime == 'litert'
        ? LiteRtLmBackendPreference.values.byName(backend)
        : LiteRtLmBackendPreference.auto,
    numberOfThreads: threads,
    numberOfThreadsBatch: runtime == 'litert' ? 0 : threads,
  );

  /// Requested sampler; NPU retains compiled runtime defaults instead.
  GenerationParams get generationParams => GenerationParams(
    maxTokens: maxTokens,
    temp: 0,
    seed: 1,
    topK: 40,
    topP: 0.9,
    minP: 0,
    penalty: 1.1,
    presencePenalty: 0,
    reusePromptPrefix: false,
  );

  /// Expanded options and explicit defaults for replay and cohort matching.
  Map<String, Object?> get effectiveConfig => {
    'context_size': contextSize,
    'threads': threads,
    'batch_threads': runtime == 'litert' ? 0 : threads,
    'backend': backend,
    'gpu_layers_hint': loadParams.gpuLayers,
    'max_tokens': maxTokens,
    'sampling_application': backend == 'npu'
        ? 'runtime_defaults_requested_sampler_not_applied'
        : 'requested_sampler',
    'effective_npu_sampler': null,
    'temperature': 0,
    'seed': 1,
    'top_k': 40,
    'top_p': 0.9,
    'min_p': 0,
    'repeat_penalty': 1.1,
    'presence_penalty': 0,
    'stop_sequences': <String>[],
    'enable_thinking': enableThinking,
    'execution_path': nativeReference ? 'native_c_api' : 'public_api',
    'reuse_prompt_prefix': false,
    'stream_batch_tokens': generationParams.streamBatchTokenThreshold,
    'stream_batch_bytes': generationParams.streamBatchByteThreshold,
    'speculative_decoding': false,
    'grammar': null,
    'thinking_budget': null,
    'activation_type': null,
    'prefill_chunk_size': null,
    'dispatch_dir': backend == 'npu' ? 'android.nativeLibraryDir' : null,
    'batch_size': 0,
    'micro_batch_size': 0,
    'flash_attention': 'auto',
    'cache_type_k': 'f16',
    'cache_type_v': 'f16',
    'kv_unified': null,
    'use_mmap': true,
    'use_mlock': false,
    'load_mtp': false,
    'split_mode': 'layer',
    'main_gpu': 0,
    'loras': <String>[],
    'max_parallel_sequences': 1,
    'speculative_rollback_token_max': 0,
    'rope_frequency_base': null,
    'rope_frequency_scale': null,
    'prefer_memory64': null,
    'parallel_file_section_loading': null,
    'runtime_defaults': 'resolved by the recorded runtime artifact',
    'native_log_level': 'info',
    'cache_behavior': 'fresh request; runtime cache unknown',
  };

  /// Detached serialized definition.
  Map<String, dynamic> toJson() =>
      jsonDecode(jsonEncode(data)) as Map<String, dynamic>;
}
