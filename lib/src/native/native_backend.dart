import 'dart:async';
import 'dart:isolate';
import '../llama_backend_interface.dart';
import '../models/model_params.dart';
import '../models/generation_params.dart';
import '../models/llama_chat_message.dart';
import '../models/llama_chat_template_result.dart';
import 'worker.dart';

/// Native implementation of [LlamaBackend] using FFI and Isolates.
///
/// This backend spawns a separate worker isolate to run the llama.cpp engine,
/// ensuring that heavyweight computation does not block the main UI thread.
class NativeLlamaBackend implements LlamaBackend {
  Isolate? _isolate;
  SendPort? _sendPort;
  bool _isReady = false;

  @override
  bool get isReady => _isReady;

  Future<void> _ensureIsolate() async {
    if (_isolate != null) return;
    final receivePort = ReceivePort();
    _isolate = await Isolate.spawn(llamaWorkerEntry, receivePort.sendPort);
    _sendPort = await receivePort.first as SendPort;
    _isReady = true;
  }

  @override
  Future<int> modelLoad(String path, ModelParams params) async {
    await _ensureIsolate();
    final rp = ReceivePort();
    _sendPort!.send(ModelLoadRequest(path, params, rp.sendPort));
    final res = await rp.first;
    if (res is HandleResponse) return res.handle;
    if (res is ErrorResponse) throw Exception(res.message);
    throw Exception("Unknown response during model load");
  }

  @override
  Future<int> modelLoadFromUrl(String url, ModelParams params) async {
    throw UnimplementedError("Use modelLoad with a local path for now");
  }

  @override
  Future<void> modelFree(int modelHandle) async {
    if (_sendPort == null) return;
    final rp = ReceivePort();
    _sendPort!.send(ModelFreeRequest(modelHandle, rp.sendPort));
    await rp.first;
  }

  @override
  Future<int> contextCreate(int modelHandle, ModelParams params) async {
    await _ensureIsolate();
    final rp = ReceivePort();
    _sendPort!.send(ContextCreateRequest(modelHandle, params, rp.sendPort));
    final res = await rp.first;
    if (res is HandleResponse) return res.handle;
    if (res is ErrorResponse) throw Exception(res.message);
    throw Exception("Unknown response during context creation");
  }

  @override
  Future<void> contextFree(int contextHandle) async {
    if (_sendPort == null) return;
    final rp = ReceivePort();
    _sendPort!.send(ContextFreeRequest(contextHandle, rp.sendPort));
    await rp.first;
  }

  @override
  Stream<List<int>> generate(
    int contextHandle,
    String prompt,
    GenerationParams params,
    int cancelTokenAddress,
  ) {
    final controller = StreamController<List<int>>();
    final rp = ReceivePort();

    _sendPort!.send(
      GenerateRequest(
        contextHandle,
        prompt,
        params,
        cancelTokenAddress,
        rp.sendPort,
      ),
    );

    rp.listen((msg) {
      if (msg is TokenResponse) {
        controller.add(msg.bytes);
      } else if (msg is DoneResponse) {
        controller.close();
        rp.close();
      } else if (msg is ErrorResponse) {
        controller.addError(Exception(msg.message));
        controller.close();
        rp.close();
      }
    });

    return controller.stream;
  }

  @override
  Future<List<int>> tokenize(
    int modelHandle,
    String text, {
    bool addSpecial = true,
  }) async {
    final rp = ReceivePort();
    _sendPort!.send(
      TokenizeRequest(modelHandle, text, addSpecial, rp.sendPort),
    );
    final res = await rp.first;
    if (res is TokenizeResponse) return res.tokens;
    throw Exception("Tokenization failed");
  }

  @override
  Future<String> detokenize(
    int modelHandle,
    List<int> tokens, {
    bool special = false,
  }) async {
    final rp = ReceivePort();
    _sendPort!.send(
      DetokenizeRequest(modelHandle, tokens, special, rp.sendPort),
    );
    final res = await rp.first;
    if (res is DetokenizeResponse) return res.text;
    throw Exception("Detokenization failed");
  }

  @override
  Future<Map<String, String>> modelMetadata(int modelHandle) async {
    final rp = ReceivePort();
    _sendPort!.send(MetadataRequest(modelHandle, rp.sendPort));
    final res = await rp.first;
    if (res is MetadataResponse) return res.metadata;
    return {};
  }

  @override
  Future<LlamaChatTemplateResult> applyChatTemplate(
    int modelHandle,
    List<LlamaChatMessage> messages, {
    bool addAssistant = true,
  }) async {
    final rp = ReceivePort();
    _sendPort!.send(
      ApplyTemplateRequest(modelHandle, messages, addAssistant, rp.sendPort),
    );
    final res = await rp.first;
    if (res is ApplyTemplateResponse) {
      return LlamaChatTemplateResult(
        prompt: res.prompt,
        stopSequences: res.stopSequences,
      );
    }
    throw Exception("Failed to apply chat template");
  }

  @override
  Future<void> setLoraAdapter(
    int contextHandle,
    String path,
    double scale,
  ) async {
    final rp = ReceivePort();
    _sendPort!.send(
      LoraRequest(
        contextHandle,
        LoraOp.set,
        path: path,
        scale: scale,
        sendPort: rp.sendPort,
      ),
    );
    final res = await rp.first;
    if (res is ErrorResponse) throw Exception(res.message);
  }

  @override
  Future<void> removeLoraAdapter(int contextHandle, String path) async {
    final rp = ReceivePort();
    _sendPort!.send(
      LoraRequest(
        contextHandle,
        LoraOp.remove,
        path: path,
        sendPort: rp.sendPort,
      ),
    );
    final res = await rp.first;
    if (res is ErrorResponse) throw Exception(res.message);
  }

  @override
  Future<void> clearLoraAdapters(int contextHandle) async {
    final rp = ReceivePort();
    _sendPort!.send(
      LoraRequest(contextHandle, LoraOp.clear, sendPort: rp.sendPort),
    );
    final res = await rp.first;
    if (res is ErrorResponse) throw Exception(res.message);
  }

  @override
  Future<String> getBackendName() async {
    await _ensureIsolate();
    final rp = ReceivePort();
    _sendPort!.send(BackendInfoRequest(rp.sendPort));
    final res = await rp.first;
    return (res as BackendInfoResponse).name;
  }

  @override
  Future<bool> isGpuSupported() async {
    await _ensureIsolate();
    final rp = ReceivePort();
    _sendPort!.send(GpuSupportRequest(rp.sendPort));
    final res = await rp.first;
    return (res as GpuSupportResponse).support;
  }

  @override
  Future<void> dispose() async {
    if (_sendPort != null) {
      final rp = ReceivePort();
      _sendPort!.send(DisposeRequest(rp.sendPort));
      await rp.first;
    }
    _isolate?.kill();
    _isReady = false;
  }
}
