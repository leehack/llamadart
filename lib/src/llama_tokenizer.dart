import 'dart:async';
import 'llama_backend_interface.dart';

/// Specialized class for encoding and decoding text into tokens.
class LlamaTokenizer {
  final LlamaBackend _backend;
  final int _modelHandle;

  /// Creates a new [LlamaTokenizer] for the given model.
  LlamaTokenizer(this._backend, this._modelHandle);

  /// Encodes the given [text] into a list of token IDs.
  Future<List<int>> encode(String text, {bool addSpecial = true}) {
    return _backend.tokenize(_modelHandle, text, addSpecial: addSpecial);
  }

  /// Decodes the given [tokens] back into a string.
  Future<String> decode(List<int> tokens, {bool special = false}) {
    return _backend.detokenize(_modelHandle, tokens, special: special);
  }

  /// Returns the number of tokens in the given [text].
  Future<int> count(String text) async {
    final tokens = await encode(text);
    return tokens.length;
  }
}
