import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'package:ffi/ffi.dart';
import 'package:llamadart/src/loader.dart';
import 'package:llamadart/src/models/model_params.dart';
import 'package:llamadart/src/models/generation_params.dart';
import 'package:llamadart/src/models/llama_chat_message.dart';
import 'package:llamadart/src/models/gpu_backend.dart';
import 'package:llamadart/src/models/llama_log_level.dart';
import 'package:llamadart/src/native_helpers.dart';

// --- Internal State ---

class _LlamaWorkerState {
  int _nextHandle = 1;
  final Map<int, _LlamaModelWrapper> models = {};
  final Map<int, _LlamaContextWrapper> contexts = {};

  // Track context dependencies: contextHandle -> modelHandle
  final Map<int, int> contextToModel = {};

  // Per-context state
  final Map<int, Pointer<llama_sampler>> samplers = {};
  final Map<int, llama_batch> batches = {};

  // LoRA tracking
  final Map<int, Map<String, _LlamaLoraWrapper>> loraAdapters =
      {}; // modelHandle -> Map
  final Map<int, Map<String, double>> activeLoras = {}; // contextHandle -> Map

  int _getHandle() => _nextHandle++;
}

// --- Native Wrappers with Finalizers ---

class _LlamaLoraWrapper implements Finalizable {
  final Pointer<llama_adapter_lora> pointer;
  static final _finalizer = llamaLib != null
      ? NativeFinalizer(
          llamaLib!.lookup<NativeFunction<Void Function(Pointer<Void>)>>(
            'llama_adapter_lora_free',
          ),
        )
      : null;

  _LlamaLoraWrapper(this.pointer) {
    _finalizer?.attach(this, pointer.cast(), detach: this);
  }

  void dispose() {
    _finalizer?.detach(this);
    llama_adapter_lora_free(pointer);
  }
}

class _LlamaModelWrapper implements Finalizable {
  final Pointer<llama_model> pointer;
  static final _finalizer = llamaLib != null
      ? NativeFinalizer(
          llamaLib!.lookup<NativeFunction<Void Function(Pointer<Void>)>>(
            'llama_model_free',
          ),
        )
      : null;

  _LlamaModelWrapper(this.pointer) {
    _finalizer?.attach(this, pointer.cast(), detach: this);
  }

  void dispose() {
    _finalizer?.detach(this);
    llama_model_free(pointer);
  }
}

class _LlamaContextWrapper implements Finalizable {
  final Pointer<llama_context> pointer;
  final _LlamaModelWrapper? _modelKeepAlive;

  static final _finalizer = llamaLib != null
      ? NativeFinalizer(
          llamaLib!.lookup<NativeFunction<Void Function(Pointer<Void>)>>(
            'llama_free',
          ),
        )
      : null;

  _LlamaContextWrapper(this.pointer, this._modelKeepAlive) {
    _finalizer?.attach(this, pointer.cast(), detach: this);
  }

  void dispose() {
    // ignore: unused_local_variable
    final _ = _modelKeepAlive;
    _finalizer?.detach(this);
    llama_free(pointer);
  }
}

// --- Messages ---

/// Base class for all worker requests.
abstract class WorkerRequest {
  /// The port to send the response to.
  final SendPort sendPort;

  /// Creates a new [WorkerRequest].
  WorkerRequest(this.sendPort);
}

/// Request to load a model.
class ModelLoadRequest extends WorkerRequest {
  /// The path to the model file.
  final String modelPath;

  /// Parameters for loading the model.
  final ModelParams modelParams;

  /// Creates a new [ModelLoadRequest].
  ModelLoadRequest(this.modelPath, this.modelParams, super.sendPort);
}

/// Request to free a model.
class ModelFreeRequest extends WorkerRequest {
  /// The handle of the model to free.
  final int modelHandle;

  /// Creates a new [ModelFreeRequest].
  ModelFreeRequest(this.modelHandle, super.sendPort);
}

/// Request to create an inference context.
class ContextCreateRequest extends WorkerRequest {
  /// The handle of the model to create the context for.
  final int modelHandle;

  /// Parameters for creating the context.
  final ModelParams params;

  /// Creates a new [ContextCreateRequest].
  ContextCreateRequest(this.modelHandle, this.params, super.sendPort);
}

/// Request to free an inference context.
class ContextFreeRequest extends WorkerRequest {
  /// The handle of the context to free.
  final int contextHandle;

  /// Creates a new [ContextFreeRequest].
  ContextFreeRequest(this.contextHandle, super.sendPort);
}

/// Request to generate text.
class GenerateRequest extends WorkerRequest {
  /// The handle of the context to use for generation.
  final int contextHandle;

  /// The input prompt.
  final String prompt;

  /// Parameters for text generation.
  final GenerationParams params;

  /// The memory address of the cancellation token.
  final int cancelTokenAddress;

  /// Creates a new [GenerateRequest].
  GenerateRequest(
    this.contextHandle,
    this.prompt,
    this.params,
    this.cancelTokenAddress,
    super.sendPort,
  );
}

/// Request to tokenize text.
class TokenizeRequest extends WorkerRequest {
  /// The handle of the model to use for tokenization.
  final int modelHandle;

  /// The text to tokenize.
  final String text;

  /// Whether to add special tokens (like BOS).
  final bool addSpecial;

  /// Creates a new [TokenizeRequest].
  TokenizeRequest(this.modelHandle, this.text, this.addSpecial, super.sendPort);
}

/// Request to detokenize tokens.
class DetokenizeRequest extends WorkerRequest {
  /// The handle of the model to use for detokenization.
  final int modelHandle;

  /// The list of token IDs to detokenize.
  final List<int> tokens;

  /// Whether to show special tokens in the output string.
  final bool special;

  /// Creates a new [DetokenizeRequest].
  DetokenizeRequest(
    this.modelHandle,
    this.tokens,
    this.special,
    super.sendPort,
  );
}

/// Request to get model metadata.
class MetadataRequest extends WorkerRequest {
  /// The handle of the model.
  final int modelHandle;

  /// Creates a new [MetadataRequest].
  MetadataRequest(this.modelHandle, super.sendPort);
}

/// Request to apply a chat template.
class ApplyTemplateRequest extends WorkerRequest {
  /// The handle of the model.
  final int modelHandle;

  /// The list of messages in the conversation history.
  final List<LlamaChatMessage> messages;

  /// Whether to add the assistant's response prefix.
  final bool addAssistant;

  /// Creates a new [ApplyTemplateRequest].
  ApplyTemplateRequest(
    this.modelHandle,
    this.messages,
    this.addAssistant,
    super.sendPort,
  );
}

/// Request for LoRA operations.
class LoraRequest extends WorkerRequest {
  /// The handle of the context.
  final int contextHandle;

  /// The path to the LoRA adapter file.
  final String? path;

  /// The scale/strength of the adapter.
  final double? scale;

  /// The operation to perform.
  final LoraOp op;

  /// Creates a new [LoraRequest].
  LoraRequest(
    this.contextHandle,
    this.op, {
    this.path,
    this.scale,
    required SendPort sendPort,
  }) : super(sendPort);
}

/// Operations for LoRA adapters.
enum LoraOp {
  /// Set or update an adapter.
  set,

  /// Remove an adapter.
  remove,

  /// Clear all adapters.
  clear,
}

/// Request for backend information.
class BackendInfoRequest extends WorkerRequest {
  /// Creates a new [BackendInfoRequest].
  BackendInfoRequest(super.sendPort);
}

/// Request to check for GPU support.
class GpuSupportRequest extends WorkerRequest {
  /// Creates a new [GpuSupportRequest].
  GpuSupportRequest(super.sendPort);
}

/// Request to dispose the worker.
class DisposeRequest extends WorkerRequest {
  /// Creates a new [DisposeRequest].
  DisposeRequest(super.sendPort);
}

// --- Responses ---

/// Response containing a resource handle.
class HandleResponse {
  /// The unique handle ID.
  final int handle;

  /// Creates a new [HandleResponse].
  HandleResponse(this.handle);
}

/// Response containing token bytes.
class TokenResponse {
  /// The generated token bytes.
  final List<int> bytes;

  /// Creates a new [TokenResponse].
  TokenResponse(this.bytes);
}

/// Response containing a list of token IDs.
class TokenizeResponse {
  /// The tokenized results.
  final List<int> tokens;

  /// Creates a new [TokenizeResponse].
  TokenizeResponse(this.tokens);
}

/// Response containing detokenized text.
class DetokenizeResponse {
  /// The resulting text.
  final String text;

  /// Creates a new [DetokenizeResponse].
  DetokenizeResponse(this.text);
}

/// Response containing model metadata.
class MetadataResponse {
  /// The metadata map.
  final Map<String, String> metadata;

  /// Creates a new [MetadataResponse].
  MetadataResponse(this.metadata);
}

/// Response containing a formatted chat prompt.
class ApplyTemplateResponse {
  /// The formatted prompt string.
  final String prompt;

  /// Detected stop sequences.
  final List<String> stopSequences;

  /// Creates a new [ApplyTemplateResponse].
  ApplyTemplateResponse(this.prompt, this.stopSequences);
}

/// Response containing an error message.
class ErrorResponse {
  /// The human-readable error message.
  final String message;

  /// Creates a new [ErrorResponse].
  ErrorResponse(this.message);
}

/// Response containing backend name.
class BackendInfoResponse {
  /// The name of the backend.
  final String name;

  /// Creates a new [BackendInfoResponse].
  BackendInfoResponse(this.name);
}

/// Response containing GPU support status.
class GpuSupportResponse {
  /// Whether GPU is supported.
  final bool support;

  /// Creates a new [GpuSupportResponse].
  GpuSupportResponse(this.support);
}

/// Response indicating an operation has completed.
class DoneResponse {}

// --- Isolate Entry ---

void _logCallback(int level, Pointer<Char> text, Pointer<Void> userData) {
  final textPtr = text.cast<Utf8>();
  if (textPtr == nullptr) return;
  try {
    final msg = textPtr.toDartString();
    stdout.write(msg);
  } catch (_) {}
}

/// Entry point for the llama worker isolate.
void llamaWorkerEntry(SendPort initialSendPort) {
  final receivePort = ReceivePort();
  initialSendPort.send(receivePort.sendPort);

  final state = _LlamaWorkerState();
  LlamaLogLevel currentLogLevel = LlamaLogLevel.warn;

  void log(String message, {LlamaLogLevel level = LlamaLogLevel.info}) {
    if (currentLogLevel == LlamaLogLevel.none) return;
    if (level.index >= currentLogLevel.index) {
      print(message);
    }
  }

  final logCallbackPtr = Pointer.fromFunction<ggml_log_callbackFunction>(
    _logCallback,
  );
  llama_log_set(logCallbackPtr, nullptr);
  ggml_log_set(logCallbackPtr, nullptr);

  // Metal Residency Hack
  if (Platform.isMacOS) {
    try {
      final libc = DynamicLibrary.open('libc.dylib');
      final setenv = libc
          .lookupFunction<
            Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Int32),
            int Function(Pointer<Utf8>, Pointer<Utf8>, int)
          >('setenv');
      final name = "GGML_METAL_RESIDENCY_DISABLE".toNativeUtf8();
      final value = "1".toNativeUtf8();
      setenv(name, value, 1);
      malloc.free(name);
      malloc.free(value);
    } catch (_) {}
  }

  ggml_backend_load_all();
  llama_backend_init();

  receivePort.listen((message) {
    if (message is ModelLoadRequest) {
      _handleModelLoad(message, state, (l) => currentLogLevel = l);
    } else if (message is ModelFreeRequest) {
      _handleModelFree(message, state);
    } else if (message is ContextCreateRequest) {
      _handleContextCreate(message, state);
    } else if (message is ContextFreeRequest) {
      _handleContextFree(message, state);
    } else if (message is GenerateRequest) {
      _handleGenerate(message, state, log);
    } else if (message is TokenizeRequest) {
      _handleTokenize(message, state);
    } else if (message is DetokenizeRequest) {
      _handleDetokenize(message, state);
    } else if (message is MetadataRequest) {
      _handleMetadata(message, state);
    } else if (message is ApplyTemplateRequest) {
      _handleApplyTemplate(message, state, log);
    } else if (message is LoraRequest) {
      _handleLora(message, state, log);
    } else if (message is BackendInfoRequest) {
      _handleBackendInfo(message);
    } else if (message is GpuSupportRequest) {
      _handleGpuSupport(message);
    } else if (message is DisposeRequest) {
      _handleDispose(message, state, receivePort);
    }
  });
}

// --- Message Handlers ---

void _handleModelLoad(
  ModelLoadRequest request,
  _LlamaWorkerState state,
  Function(LlamaLogLevel) setLogLevel,
) {
  try {
    setLogLevel(request.modelParams.logLevel);
    if (!File(request.modelPath).existsSync()) {
      request.sendPort.send(
        ErrorResponse("File not found: ${request.modelPath}"),
      );
      return;
    }

    final modelPathPtr = request.modelPath.toNativeUtf8();
    final mparams = llama_model_default_params();
    mparams.n_gpu_layers = request.modelParams.gpuLayers;
    mparams.use_mmap = true;

    // --- Backend Selection Logic ---
    if (request.modelParams.preferredBackend != GpuBackend.auto) {
      final count = ggml_backend_dev_count();
      Pointer<ggml_backend_device>? foundDev;
      for (int i = 0; i < count; i++) {
        final dev = ggml_backend_dev_get(i);
        final name = ggml_backend_dev_name(
          dev,
        ).cast<Utf8>().toDartString().toLowerCase();

        bool match = false;
        final preferred = request.modelParams.preferredBackend;
        if (preferred == GpuBackend.vulkan && name.contains("vulkan")) {
          match = true;
        }
        if (preferred == GpuBackend.metal && name.contains("metal")) {
          match = true;
        }
        if (preferred == GpuBackend.cuda && name.contains("cuda")) {
          match = true;
        }
        if (preferred == GpuBackend.cpu && name.contains("cpu")) match = true;

        if (match) {
          foundDev = dev;
          break;
        }
      }

      if (foundDev != null) {
        final devicesPtr = calloc<Pointer<Void>>(2);
        devicesPtr[0] = foundDev.cast();
        devicesPtr[1] = nullptr;
        mparams.devices = devicesPtr.cast();
      }
    }

    final modelPtr = llama_model_load_from_file(modelPathPtr.cast(), mparams);
    malloc.free(modelPathPtr);
    if (mparams.devices != nullptr) calloc.free(mparams.devices.cast());

    if (modelPtr == nullptr) {
      request.sendPort.send(ErrorResponse("Failed to load model"));
      return;
    }

    final handle = state._getHandle();
    state.models[handle] = _LlamaModelWrapper(modelPtr);
    state.loraAdapters[handle] = {};

    request.sendPort.send(HandleResponse(handle));
  } catch (e) {
    request.sendPort.send(ErrorResponse(e.toString()));
  }
}

void _handleModelFree(ModelFreeRequest request, _LlamaWorkerState state) {
  final model = state.models.remove(request.modelHandle);
  if (model != null) {
    final contextsToRemove = state.contextToModel.entries
        .where((e) => e.value == request.modelHandle)
        .map((e) => e.key)
        .toList();

    for (final ctxHandle in contextsToRemove) {
      _freeContext(ctxHandle, state);
    }

    final adapters = state.loraAdapters.remove(request.modelHandle);
    adapters?.values.forEach((a) => a.dispose());

    model.dispose();
  }
  request.sendPort.send(DoneResponse());
}

void _handleContextCreate(
  ContextCreateRequest request,
  _LlamaWorkerState state,
) {
  final model = state.models[request.modelHandle];
  if (model == null) {
    request.sendPort.send(ErrorResponse("Invalid model handle"));
    return;
  }

  try {
    final ctxParams = llama_context_default_params();
    int nCtx = request.params.contextSize;
    if (nCtx <= 0) {
      nCtx = llama_model_n_ctx_train(model.pointer);
      if (nCtx > 4096) nCtx = 4096;
    }
    ctxParams.n_ctx = nCtx;
    ctxParams.n_batch = nCtx;
    ctxParams.n_ubatch = nCtx;

    final ctxPtr = llama_init_from_model(model.pointer, ctxParams);
    if (ctxPtr == nullptr) {
      request.sendPort.send(ErrorResponse("Failed to create context"));
      return;
    }

    final handle = state._getHandle();
    state.contexts[handle] = _LlamaContextWrapper(ctxPtr, model);
    state.contextToModel[handle] = request.modelHandle;
    state.activeLoras[handle] = {};

    // Init Sampler placeholder (will be configured in generate)
    final samplerChainParams = llama_sampler_chain_default_params();
    state.samplers[handle] = llama_sampler_chain_init(samplerChainParams);
    state.batches[handle] = llama_batch_init(nCtx, 0, 1);

    request.sendPort.send(HandleResponse(handle));
  } catch (e) {
    request.sendPort.send(ErrorResponse(e.toString()));
  }
}

void _handleContextFree(ContextFreeRequest request, _LlamaWorkerState state) {
  _freeContext(request.contextHandle, state);
  request.sendPort.send(DoneResponse());
}

void _freeContext(int handle, _LlamaWorkerState state) {
  state.contextToModel.remove(handle);
  state.activeLoras.remove(handle);

  final sampler = state.samplers.remove(handle);
  if (sampler != null) llama_sampler_free(sampler);

  final batch = state.batches.remove(handle);
  if (batch != null) llama_batch_free(batch);

  final ctx = state.contexts.remove(handle);
  ctx?.dispose();
}

void _handleGenerate(
  GenerateRequest request,
  _LlamaWorkerState state,
  Function log,
) {
  final ctx = state.contexts[request.contextHandle];
  if (ctx == null) {
    request.sendPort.send(ErrorResponse("Invalid context handle"));
    return;
  }

  final vocab = llama_model_get_vocab(llama_get_model(ctx.pointer));
  final oldSampler = state.samplers[request.contextHandle]!;
  final b = state.batches[request.contextHandle]!;
  final nCtx = llama_n_ctx(ctx.pointer);

  // Clear KV
  final memory = llama_get_memory(ctx.pointer);
  llama_memory_seq_rm(memory, -1, -1, -1);

  // Configure Sampler
  llama_sampler_free(oldSampler);
  final samplerChainParams = llama_sampler_chain_default_params();
  final sampler = llama_sampler_chain_init(samplerChainParams);
  state.samplers[request.contextHandle] = sampler;

  llama_sampler_chain_add(
    sampler,
    llama_sampler_init_penalties(64, request.params.penalty, 0.0, 0.0),
  );
  llama_sampler_chain_add(
    sampler,
    llama_sampler_init_top_k(request.params.topK),
  );
  llama_sampler_chain_add(
    sampler,
    llama_sampler_init_top_p(request.params.topP, 1),
  );
  llama_sampler_chain_add(
    sampler,
    llama_sampler_init_temp(request.params.temp),
  );
  llama_sampler_chain_add(
    sampler,
    llama_sampler_init_dist(
      request.params.seed ?? DateTime.now().millisecondsSinceEpoch,
    ),
  );

  final tokensPtr = malloc<Int32>(nCtx);
  final pieceBuf = malloc<Uint8>(256);
  final cancelToken = Pointer<Int8>.fromAddress(request.cancelTokenAddress);

  try {
    final promptPtr = request.prompt.toNativeUtf8();
    final nTokens = llama_tokenize(
      vocab,
      promptPtr.cast(),
      promptPtr.length,
      tokensPtr,
      nCtx,
      true,
      true,
    );
    malloc.free(promptPtr);

    if (nTokens < 0 || nTokens > nCtx) {
      request.sendPort.send(
        ErrorResponse("Tokenization failed or prompt too long"),
      );
      return;
    }

    b.n_tokens = nTokens;
    for (int i = 0; i < nTokens; i++) {
      b.token[i] = tokensPtr[i];
      b.pos[i] = i;
      b.n_seq_id[i] = 1;
      b.seq_id[i][0] = 0;
      b.logits[i] = (i == nTokens - 1) ? 1 : 0;
    }

    if (llama_decode(ctx.pointer, b) != 0) {
      request.sendPort.send(ErrorResponse("Initial decode failed"));
      return;
    }

    int currentPos = nTokens;
    String fullText = "";

    for (int i = 0; i < request.params.maxTokens; i++) {
      if (cancelToken.value == 1) {
        log("Isolate: Cancel token triggered at step $i");
        break;
      }
      if (currentPos >= nCtx) break;

      final tokenId = llama_sampler_sample(
        sampler,
        ctx.pointer,
        b.n_tokens - 1,
      );
      if (llama_vocab_is_eog(vocab, tokenId)) break;

      final n = llama_token_to_piece(
        vocab,
        tokenId,
        pieceBuf.cast(),
        256,
        0,
        false,
      );
      if (n > 0) {
        final bytes = pieceBuf.asTypedList(n).toList();
        request.sendPort.send(TokenResponse(bytes));

        if (request.params.stopSequences.isNotEmpty) {
          fullText += utf8.decode(bytes, allowMalformed: true);
          if (request.params.stopSequences.any((s) => fullText.endsWith(s))) {
            break;
          }
        }
      }

      b.n_tokens = 1;
      b.token[0] = tokenId;
      b.pos[0] = currentPos++;
      b.n_seq_id[0] = 1;
      b.seq_id[0][0] = 0;
      b.logits[0] = 1;

      if (llama_decode(ctx.pointer, b) != 0) break;
    }
    request.sendPort.send(DoneResponse());
  } catch (e) {
    request.sendPort.send(ErrorResponse(e.toString()));
  } finally {
    malloc.free(tokensPtr);
    malloc.free(pieceBuf);
  }
}

void _handleTokenize(TokenizeRequest request, _LlamaWorkerState state) {
  final model = state.models[request.modelHandle];
  if (model == null) {
    request.sendPort.send(ErrorResponse("Invalid model handle"));
    return;
  }

  final vocab = llama_model_get_vocab(model.pointer);
  final textPtr = request.text.toNativeUtf8();
  final n = -llama_tokenize(
    vocab,
    textPtr.cast(),
    textPtr.length,
    nullptr,
    0,
    request.addSpecial,
    true,
  );
  final tokensPtr = malloc<Int32>(n);
  final actual = llama_tokenize(
    vocab,
    textPtr.cast(),
    textPtr.length,
    tokensPtr,
    n,
    request.addSpecial,
    true,
  );

  final result = <int>[];
  for (int i = 0; i < actual; i++) {
    result.add(tokensPtr[i]);
  }

  malloc.free(textPtr);
  malloc.free(tokensPtr);
  request.sendPort.send(TokenizeResponse(result));
}

void _handleDetokenize(DetokenizeRequest request, _LlamaWorkerState state) {
  final model = state.models[request.modelHandle];
  if (model == null) {
    request.sendPort.send(ErrorResponse("Invalid model handle"));
    return;
  }

  final vocab = llama_model_get_vocab(model.pointer);
  final buffer = malloc<Int8>(256);
  final bytes = <int>[];

  for (final t in request.tokens) {
    final n = llama_token_to_piece(
      vocab,
      t,
      buffer.cast(),
      256,
      0,
      request.special,
    );
    if (n > 0) bytes.addAll(buffer.asTypedList(n));
  }

  malloc.free(buffer);
  request.sendPort.send(
    DetokenizeResponse(utf8.decode(bytes, allowMalformed: true)),
  );
}

void _handleMetadata(MetadataRequest request, _LlamaWorkerState state) {
  final model = state.models[request.modelHandle];
  if (model == null) {
    request.sendPort.send(ErrorResponse("Invalid model handle"));
    return;
  }

  final metadata = <String, String>{};
  final keyBuf = malloc<Int8>(1024);
  final valBuf = malloc<Int8>(1024 * 64);

  final n = llama_model_meta_count(model.pointer);
  for (int i = 0; i < n; i++) {
    llama_model_meta_key_by_index(model.pointer, i, keyBuf.cast(), 1024);
    llama_model_meta_val_str_by_index(
      model.pointer,
      i,
      valBuf.cast(),
      1024 * 64,
    );
    metadata[keyBuf.cast<Utf8>().toDartString()] = valBuf
        .cast<Utf8>()
        .toDartString();
  }

  malloc.free(keyBuf);
  malloc.free(valBuf);
  request.sendPort.send(MetadataResponse(metadata));
}

void _handleApplyTemplate(
  ApplyTemplateRequest request,
  _LlamaWorkerState state,
  Function log,
) {
  final model = state.models[request.modelHandle];
  if (model == null) {
    request.sendPort.send(ErrorResponse("Invalid model handle"));
    return;
  }

  final nMsgs = request.messages.length;
  final chatMsgs = malloc<llama_chat_message>(nMsgs);
  final allocated = <Pointer<Char>>[];

  try {
    for (int i = 0; i < nMsgs; i++) {
      final m = request.messages[i];
      allocated.add(chatMsgs[i].role = m.role.toNativeUtf8().cast());
      allocated.add(chatMsgs[i].content = m.content.toNativeUtf8().cast());
    }

    final tmplBuf = malloc<Char>(1024 * 64);
    final tmplRes = llama_model_meta_val_str(
      model.pointer,
      "tokenizer.chat_template".toNativeUtf8().cast(),
      tmplBuf,
      1024 * 64,
    );

    Pointer<Char> tmplPtr = tmplRes >= 0 ? tmplBuf : nullptr;
    final required = llama_chat_apply_template(
      tmplPtr,
      chatMsgs,
      nMsgs,
      request.addAssistant,
      nullptr,
      0,
    );
    final buf = malloc<Char>(required + 1);
    llama_chat_apply_template(
      tmplPtr,
      chatMsgs,
      nMsgs,
      request.addAssistant,
      buf,
      required + 1,
    );

    final prompt = buf.cast<Utf8>().toDartString();
    malloc.free(buf);
    malloc.free(tmplBuf);

    final stops = <String>{};
    final vocab = llama_model_get_vocab(model.pointer);
    final eos = llama_vocab_eos(vocab);
    if (eos != -1) {
      final textPtr = llama_vocab_get_text(vocab, eos);
      if (textPtr != nullptr) stops.add(textPtr.cast<Utf8>().toDartString());
    }
    final eot = llama_vocab_eot(vocab);
    if (eot != -1) {
      final textPtr = llama_vocab_get_text(vocab, eot);
      if (textPtr != nullptr) stops.add(textPtr.cast<Utf8>().toDartString());
    }

    request.sendPort.send(ApplyTemplateResponse(prompt, stops.toList()));
  } catch (e) {
    request.sendPort.send(ErrorResponse(e.toString()));
  } finally {
    for (var ptr in allocated) {
      malloc.free(ptr);
    }
    malloc.free(chatMsgs);
  }
}

void _handleLora(LoraRequest request, _LlamaWorkerState state, Function log) {
  final ctx = state.contexts[request.contextHandle];
  final modelHandle = state.contextToModel[request.contextHandle];
  if (ctx == null || modelHandle == null) {
    request.sendPort.send(ErrorResponse("Invalid context handle"));
    return;
  }

  try {
    if (request.op == LoraOp.set) {
      var adapter = state.loraAdapters[modelHandle]![request.path!];
      if (adapter == null) {
        final pathPtr = request.path!.toNativeUtf8();
        final adapterPtr = llama_adapter_lora_init(
          state.models[modelHandle]!.pointer,
          pathPtr.cast(),
        );
        malloc.free(pathPtr);
        if (adapterPtr == nullptr) {
          request.sendPort.send(
            ErrorResponse("Failed to load LoRA at ${request.path}"),
          );
          return;
        }
        adapter = _LlamaLoraWrapper(adapterPtr);
        state.loraAdapters[modelHandle]![request.path!] = adapter;
      }
      llama_set_adapter_lora(ctx.pointer, adapter.pointer, request.scale!);
      state.activeLoras[request.contextHandle]![request.path!] = request.scale!;
    } else if (request.op == LoraOp.remove) {
      final adapter = state.loraAdapters[modelHandle]![request.path!];
      if (adapter != null) {
        llama_rm_adapter_lora(ctx.pointer, adapter.pointer);
      }
      state.activeLoras[request.contextHandle]!.remove(request.path);
    } else if (request.op == LoraOp.clear) {
      llama_clear_adapter_lora(ctx.pointer);
      state.activeLoras[request.contextHandle]!.clear();
    }
    request.sendPort.send(DoneResponse());
  } catch (e) {
    request.sendPort.send(ErrorResponse(e.toString()));
  }
}

void _handleBackendInfo(WorkerRequest request) {
  request.sendPort.send(
    BackendInfoResponse(NativeHelpers.getAvailableDevices().join(", ")),
  );
}

void _handleGpuSupport(WorkerRequest request) {
  request.sendPort.send(GpuSupportResponse(llama_supports_gpu_offload()));
}

void _handleDispose(
  DisposeRequest request,
  _LlamaWorkerState state,
  ReceivePort rp,
) {
  for (final m in state.models.values) {
    m.dispose();
  }
  for (final c in state.contexts.values) {
    c.dispose();
  }
  llama_backend_free();
  request.sendPort.send(null);
  rp.close();
  Isolate.exit();
}
