import 'dart:async';
import 'llama_backend_interface.dart';
import 'models/llama_chat_message.dart';
import 'models/llama_chat_template_result.dart';

/// Specialized class for processing chat templates and detecting stop sequences.
class ChatTemplateProcessor {
  final LlamaBackend _backend;
  final int _modelHandle;

  /// Creates a new [ChatTemplateProcessor] for the given model.
  ChatTemplateProcessor(this._backend, this._modelHandle);

  /// Applies the model's chat template to a list of messages.
  Future<LlamaChatTemplateResult> apply(
    List<LlamaChatMessage> messages, {
    bool addAssistant = true,
  }) {
    return _backend.applyChatTemplate(
      _modelHandle,
      messages,
      addAssistant: addAssistant,
    );
  }

  /// Automatically identifies stop sequences for the current model.
  Future<List<String>> detectStopSequences() async {
    final result = await apply([]);
    return result.stopSequences;
  }
}
