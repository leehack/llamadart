import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:llamadart/backend.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/llama_cpp/bindings.dart';
import 'package:test/test.dart';

import '../studio_test_fakes.dart';

/// Captures the real adapter's rendered prompts and generation constraints.
/// Scripted replies qualify adapter behavior; they are never model inference.
class StructuredRecordingBackend
    implements LlamaBackend, BackendGrammarConstraintsSupport {
  StructuredRecordingBackend(this.delegate);

  final LlamaBackend delegate;
  final List<String> prompts = [];
  final List<GenerationParams> requests = [];
  final List<List<String>> scriptedReplies = [];

  @override
  bool get supportsGrammarConstraints =>
      delegate is BackendGrammarConstraintsSupport
      ? (delegate as BackendGrammarConstraintsSupport)
            .supportsGrammarConstraints
      : true;
  @override
  bool get isReady => delegate.isReady;
  @override
  bool get supportsUrlLoading => delegate.supportsUrlLoading;
  @override
  Future<int> modelLoad(String path, ModelParams params) =>
      delegate.modelLoad(path, params);
  @override
  Future<int> modelLoadFromUrl(
    String url,
    ModelParams params, {
    void Function(double)? onProgress,
  }) => delegate.modelLoadFromUrl(url, params, onProgress: onProgress);
  @override
  Future<void> modelFree(int handle) => delegate.modelFree(handle);
  @override
  Future<int> contextCreate(int handle, ModelParams params) =>
      delegate.contextCreate(handle, params);
  @override
  Future<void> contextFree(int handle) => delegate.contextFree(handle);
  @override
  Future<int> getContextSize(int handle) => delegate.getContextSize(handle);
  @override
  Stream<List<int>> generate(
    int handle,
    String prompt,
    GenerationParams params, {
    List<LlamaContentPart>? parts,
  }) async* {
    prompts.add(prompt);
    requests.add(params);
    if (scriptedReplies.isEmpty) {
      yield* delegate.generate(handle, prompt, params, parts: parts);
    } else {
      for (final chunk in scriptedReplies.removeAt(0)) {
        yield utf8.encode(chunk);
      }
    }
  }

  @override
  void cancelGeneration() => delegate.cancelGeneration();
  @override
  Future<List<int>> tokenize(
    int handle,
    String text, {
    bool addSpecial = true,
  }) => delegate.tokenize(handle, text, addSpecial: addSpecial);
  @override
  Future<String> detokenize(
    int handle,
    List<int> tokens, {
    bool special = false,
  }) => delegate.detokenize(handle, tokens, special: special);
  @override
  Future<Map<String, String>> modelMetadata(int handle) =>
      delegate.modelMetadata(handle);
  @override
  Future<String> getBackendName() => delegate.getBackendName();
  @override
  Future<bool> isGpuSupported() => delegate.isGpuSupported();
  @override
  Future<void> setLogLevel(LlamaLogLevel level) => delegate.setLogLevel(level);
  @override
  Future<void> dispose() => delegate.dispose();
  @override
  Future<({int total, int free})> getVramInfo() => delegate.getVramInfo();
  @override
  Future<String> applyChatTemplate(
    int handle,
    List<Map<String, dynamic>> messages, {
    String? customTemplate,
    bool addAssistant = true,
  }) => delegate.applyChatTemplate(
    handle,
    messages,
    customTemplate: customTemplate,
    addAssistant: addAssistant,
  );
}

/// Production Qwen3.5 Jinja input with deterministic byte-stream emissions.
class StructuredFixtureBackend extends FakeSpeculativeFallbackBackend {
  @override
  Future<Map<String, String>> modelMetadata(int handle) async => {
    'general.architecture': 'qwen35',
    'tokenizer.chat_template': File(
      '../../test/fixtures/templates/Qwen3_5-0_8B.jinja',
    ).readAsStringSync(),
  };
}

final _libc = DynamicLibrary.process();
final _malloc = _libc
    .lookupFunction<
      Pointer<Void> Function(UintPtr),
      Pointer<Void> Function(int)
    >('malloc');
final _free = _libc
    .lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
      'free',
    );
Pointer<T> _allocate<T extends NativeType>(int bytes) {
  final value = _malloc(bytes);
  if (value == nullptr) throw StateError('Native test allocation failed.');
  return value.cast<T>();
}

Pointer<Char> _text(String value) {
  final bytes = utf8.encode(value);
  final result = _allocate<Uint8>(bytes.length + 1);
  result.asTypedList(bytes.length + 1).setAll(0, [...bytes, 0]);
  return result.cast<Char>();
}

void _release(Pointer<NativeType> value) => _free(value.cast<Void>());

/// Checks the actual Studio-generated eager grammar with the native sampler.
/// A vocabulary-only load is model-backed grammar evidence, not generation.
void validateStudioCompiledGrammar(
  String modelPath,
  String grammar,
  Map<String, bool> candidates,
) {
  final path = _text(modelPath);
  final model = llama_model_load_from_file(
    path,
    llama_model_default_params()..vocab_only = true,
  );
  _release(path);
  expect(model, isNot(nullptr));
  try {
    final vocab = llama_model_get_vocab(model);
    expect(llama_vocab_is_eog(vocab, llama_vocab_eos(vocab)), isTrue);
    for (final candidate in candidates.entries) {
      final source = _text(grammar);
      final root = _text('root');
      final sampler = llama_sampler_init_grammar(vocab, source, root);
      _release(source);
      _release(root);
      expect(sampler, isNot(nullptr));
      try {
        final prefix = _tokenize(vocab, '\n');
        final tokens = _tokenize(vocab, '\n${candidate.key}');
        expect(tokens.take(prefix.length), orderedEquals(prefix));
        final data = _allocate<llama_token_data>(sizeOf<llama_token_data>());
        final array = _allocate<llama_token_data_array>(
          sizeOf<llama_token_data_array>(),
        );
        try {
          array.ref
            ..data = data
            ..size = 1
            ..selected = -1
            ..sorted = false;
          var accepted = true;
          for (final token in [
            ...tokens.skip(prefix.length),
            llama_vocab_eos(vocab),
          ]) {
            data.ref
              ..id = token
              ..logit = 0
              ..p = 0;
            llama_sampler_apply(sampler, array);
            if (!data.ref.logit.isFinite) {
              accepted = false;
              break;
            }
            llama_sampler_accept(sampler, token);
          }
          expect(accepted, candidate.value, reason: candidate.key);
        } finally {
          _release(data);
          _release(array);
        }
      } finally {
        llama_sampler_free(sampler);
      }
    }
  } finally {
    llama_model_free(model);
  }
}

List<int> _tokenize(Pointer<llama_vocab> vocab, String value) {
  final text = _text(value);
  final bytes = utf8.encode(value).length;
  try {
    final size = -llama_tokenize(vocab, text, bytes, nullptr, 0, false, false);
    expect(size, greaterThan(0));
    final tokens = _allocate<llama_token>(size * sizeOf<llama_token>());
    try {
      expect(
        llama_tokenize(vocab, text, bytes, tokens, size, false, false),
        size,
      );
      return [for (var i = 0; i < size; i++) tokens[i]];
    } finally {
      _release(tokens);
    }
  } finally {
    _release(text);
  }
}
