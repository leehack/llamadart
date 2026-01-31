import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'package:ffi/ffi.dart';
import 'package:http/http.dart' as http;
import 'package:llamadart/src/loader.dart';
import 'package:llamadart/src/llama_service_interface.dart';
import 'package:llamadart/src/native_helpers.dart';

// Export the interface types
export 'package:llamadart/src/llama_service_interface.dart';

// --- Messages ---
class _InitRequest {
  final String modelPath;
  final SendPort sendPort;
  final ModelParams modelParams;

  _InitRequest(this.modelPath, this.sendPort, this.modelParams);
}

class _GenerateRequest {
  final String prompt;
  final SendPort sendPort;
  final GenerationParams params;
  final int cancelTokenAddress; // Pass address as int to be safe/simple

  _GenerateRequest(
    this.prompt,
    this.sendPort,
    this.params,
    this.cancelTokenAddress,
  );
}

class _TokenizeRequest {
  final String text;
  final SendPort sendPort;

  _TokenizeRequest(this.text, this.sendPort);
}

class _DetokenizeRequest {
  final List<int> tokens;
  final SendPort sendPort;

  _DetokenizeRequest(this.tokens, this.sendPort);
}

class _MetadataRequest {
  final String key;
  final SendPort sendPort;
  _MetadataRequest(this.key, this.sendPort);
}

class _DisposeRequest {
  final SendPort sendPort;
  _DisposeRequest(this.sendPort);
}

class _ApplyTemplateRequest {
  final List<LlamaChatMessage> messages;
  final bool addAssistant;
  final SendPort sendPort;

  _ApplyTemplateRequest(this.messages, this.addAssistant, this.sendPort);
}

class _BackendInfoRequest {
  final SendPort sendPort;
  _BackendInfoRequest(this.sendPort);
}

class _GpuSupportRequest {
  final SendPort sendPort;
  _GpuSupportRequest(this.sendPort);
}

class _MetadataAllRequest {
  final SendPort sendPort;
  _MetadataAllRequest(this.sendPort);
}

class _ContextSizeRequest {
  final SendPort sendPort;
  _ContextSizeRequest(this.sendPort);
}

class _TokenCountRequest {
  final String text;
  final SendPort sendPort;
  _TokenCountRequest(this.text, this.sendPort);
}

// --- Responses ---
class _TokenResponse {
  final List<int> bytes;
  _TokenResponse(this.bytes);
}

class _TokenizeResponse {
  final List<int> tokens;
  _TokenizeResponse(this.tokens);
}

class _DetokenizeResponse {
  final String text;
  _DetokenizeResponse(this.text);
}

class _MetadataResponse {
  final String? value;
  _MetadataResponse(this.value);
}

class _ApplyTemplateResponse {
  final String prompt;
  _ApplyTemplateResponse(this.prompt);
}

class _ErrorResponse {
  final String message;
  _ErrorResponse(this.message);
}

class _BackendInfoResponse {
  final String name;
  _BackendInfoResponse(this.name);
}

class _GpuSupportResponse {
  final bool support;
  _GpuSupportResponse(this.support);
}

class _MetadataAllResponse {
  final Map<String, String> metadata;
  _MetadataAllResponse(this.metadata);
}

class _ContextSizeResponse {
  final int size;
  _ContextSizeResponse(this.size);
}

class _TokenCountResponse {
  final int count;
  _TokenCountResponse(this.count);
}

class _DoneResponse {}

// --- Service Class ---
/// Native implementation of [LlamaServiceBase] using dart:ffi and isolates.
class LlamaService implements LlamaServiceBase {
  Isolate? _isolate;
  SendPort? _sendPort;
  bool _isReady = false;

  // Checking cancellation token
  Pointer<Int8>? _currentCancelToken;

  /// Creates a new [LlamaService].
  ///
  /// [wllamaPath] and [wasmPath] are web-specific and ignored on native platforms.
  LlamaService({String? wllamaPath, String? wasmPath});

  /// Returns a list of available GPU devices and backends (e.g. "Vulkan0", "Metal").
  static Future<List<String>> getAvailableDevices() async {
    try {
      return NativeHelpers.getAvailableDevices();
    } catch (e) {
      _log("Error listing devices: $e", level: LlamaLogLevel.error);
      return [];
    }
  }

  /// Whether the service is ready for inference.
  @override
  bool get isReady => _isReady;

  /// Initializes the service with the model at [modelPath].
  ///
  /// [modelParams] allows customizing context size and GPU offloading.
  @override
  Future<void> init(String modelPath, {ModelParams? modelParams}) async {
    if (_isolate == null) {
      final receivePort = ReceivePort();
      _isolate = await Isolate.spawn(_isolateEntry, receivePort.sendPort);

      // Wait for the isolate to send its SendPort
      _sendPort = await receivePort.first as SendPort;
    }

    // Send Init request
    final initResponsePort = ReceivePort();
    _sendPort!.send(
      _InitRequest(
        modelPath,
        initResponsePort.sendPort,
        modelParams ?? const ModelParams(),
      ),
    );

    final response = await initResponsePort.first;
    if (response is _ErrorResponse) {
      throw Exception(response.message);
    }
    _isReady = true;
  }

  /// Initializes from a URL by downloading to a temporary file.
  @override
  Future<void> initFromUrl(String modelUrl, {ModelParams? modelParams}) async {
    final uri = Uri.parse(modelUrl);
    final filename = uri.pathSegments.last;
    final tempDir = Directory.systemTemp.createTempSync('llamadart_model_');
    final file = File('${tempDir.path}/$filename');

    if (!file.existsSync()) {
      _log('Downloading model from $modelUrl to ${file.path}...');
      final response = await http.get(uri);
      if (response.statusCode != 200) {
        throw Exception('Failed to download model: ${response.statusCode}');
      }
      await file.writeAsBytes(response.bodyBytes);
      _log('Download complete.');
    } else {
      _log('Using cached model at ${file.path}');
    }

    await init(file.path, modelParams: modelParams);
  }

  /// Generates text based on the [prompt].
  @override
  Stream<String> generate(String prompt, {GenerationParams? params}) {
    if (!_isReady) throw Exception('Service not initialized');

    final controller = StreamController<String>();
    final byteController = StreamController<List<int>>();
    final receivePort = ReceivePort();

    // Default params
    final p = params ?? const GenerationParams();

    // Allocate cancellation token (0 = run, 1 = cancel)
    _currentCancelToken = malloc<Int8>(1);
    _currentCancelToken!.value = 0;

    _sendPort!.send(
      _GenerateRequest(
        prompt,
        receivePort.sendPort,
        p,
        _currentCancelToken!.address,
      ),
    );

    // Pipe bytes through UTF-8 decoder correctly to handle multi-byte characters
    byteController.stream
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen(
          (text) {
            controller.add(text);
          },
          onDone: () {
            controller.close();
            if (_currentCancelToken != null) {
              malloc.free(_currentCancelToken!);
              _currentCancelToken = null;
            }
          },
          onError: (e) {
            controller.addError(e);
            if (_currentCancelToken != null) {
              malloc.free(_currentCancelToken!);
              _currentCancelToken = null;
            }
          },
        );

    receivePort.listen((message) {
      if (message is _TokenResponse) {
        byteController.add(message.bytes);
      } else if (message is _DoneResponse) {
        byteController.close();
        receivePort.close();
      } else if (message is _ErrorResponse) {
        byteController.addError(message.message);
        byteController.close();
        receivePort.close();
      }
    });

    return controller.stream;
  }

  /// Tokenizes the given [text] into a list of token IDs.
  @override
  Future<List<int>> tokenize(String text) async {
    if (!_isReady) throw Exception('Service not initialized');

    final receivePort = ReceivePort();
    _sendPort!.send(_TokenizeRequest(text, receivePort.sendPort));

    final response = await receivePort.first;
    if (response is _TokenizeResponse) {
      return response.tokens;
    } else if (response is _ErrorResponse) {
      throw Exception(response.message);
    } else {
      throw Exception('Unexpected response type: ${response.runtimeType}');
    }
  }

  /// Cancel the current generation.
  @override
  void cancelGeneration() {
    if (_currentCancelToken != null) {
      _currentCancelToken!.value = 1;
    }
  }

  /// Detokenizes the given [tokens] back into a string.
  @override
  Future<String> detokenize(List<int> tokens) async {
    if (!_isReady) throw Exception('Service not initialized');

    final receivePort = ReceivePort();
    _sendPort!.send(_DetokenizeRequest(tokens, receivePort.sendPort));

    final response = await receivePort.first;
    if (response is _DetokenizeResponse) {
      return response.text;
    } else if (response is _ErrorResponse) {
      throw Exception(response.message);
    } else {
      throw Exception('Unexpected response type: ${response.runtimeType}');
    }
  }

  @override
  Future<String> applyChatTemplate(
    List<LlamaChatMessage> messages, {
    bool addAssistant = true,
  }) async {
    if (!_isReady) throw Exception('Service not initialized');

    final receivePort = ReceivePort();
    _sendPort!.send(
      _ApplyTemplateRequest(messages, addAssistant, receivePort.sendPort),
    );

    final response = await receivePort.first;
    if (response is _ApplyTemplateResponse) {
      return response.prompt;
    } else if (response is _ErrorResponse) {
      throw Exception(response.message);
    } else {
      throw Exception('Unexpected response type: ${response.runtimeType}');
    }
  }

  @override
  Future<String?> getModelMetadata(String key) async {
    if (!_isReady) throw Exception('Service not initialized');

    final receivePort = ReceivePort();
    _sendPort!.send(_MetadataRequest(key, receivePort.sendPort));

    final response = await receivePort.first;
    if (response is _MetadataResponse) {
      return response.value;
    } else if (response is _ErrorResponse) {
      throw Exception(response.message);
    } else {
      throw Exception('Unexpected response type: ${response.runtimeType}');
    }
  }

  /// Disposes the service and the underlying isolate.
  @override
  Future<void> dispose() async {
    cancelGeneration();

    if (_sendPort != null) {
      final receivePort = ReceivePort();
      _sendPort!.send(_DisposeRequest(receivePort.sendPort));
      await receivePort.first;
      receivePort.close();
    }

    _isolate?.kill();
    _isolate = null;
    _sendPort = null;
    _isReady = false;
  }

  /// Returns the name of the backend being used (e.g., 'Metal', 'Vulkan', 'CPU').
  @override
  Future<String> getBackendName() async {
    if (_sendPort == null) return "Unknown";
    final receivePort = ReceivePort();
    _sendPort!.send(_BackendInfoRequest(receivePort.sendPort));
    final response = await receivePort.first;
    if (response is _BackendInfoResponse) {
      return response.name;
    }
    return "Unknown";
  }

  /// Returns true if GPU acceleration is supported on this hardware.
  @override
  Future<bool> isGpuSupported() async {
    if (_sendPort == null) return false;
    final receivePort = ReceivePort();
    _sendPort!.send(_GpuSupportRequest(receivePort.sendPort));
    final response = await receivePort.first;
    if (response is _GpuSupportResponse) {
      return response.support;
    }
    return false;
  }

  /// Returns the resolved context size.
  @override
  Future<int> getContextSize() async {
    if (_sendPort == null) return 0;
    final receivePort = ReceivePort();
    _sendPort!.send(_ContextSizeRequest(receivePort.sendPort));
    final response = await receivePort.first;
    if (response is _ContextSizeResponse) {
      return response.size;
    }
    return 0;
  }

  /// Returns the token count for the given [text].
  @override
  Future<int> getTokenCount(String text) async {
    if (_sendPort == null) return 0;
    final receivePort = ReceivePort();
    _sendPort!.send(_TokenCountRequest(text, receivePort.sendPort));
    final response = await receivePort.first;
    if (response is _TokenCountResponse) {
      return response.count;
    }
    return 0;
  }

  /// Returns all model metadata keys and values.
  @override
  Future<Map<String, String>> getAllMetadata() async {
    if (_sendPort == null) return {};
    final receivePort = ReceivePort();
    _sendPort!.send(_MetadataAllRequest(receivePort.sendPort));
    final response = await receivePort.first;
    if (response is _MetadataAllResponse) {
      return response.metadata;
    }
    return {};
  }

  // --- Native Logging Callback ---
  static LlamaLogLevel _currentLogLevel = LlamaLogLevel.warn;

  static void _log(String message, {LlamaLogLevel level = LlamaLogLevel.info}) {
    if (_currentLogLevel == LlamaLogLevel.none) return;
    if (level.index >= _currentLogLevel.index) {
      print(message);
    }
  }

  static void _logCallback(
    int level,
    Pointer<Char> text,
    Pointer<Void> userData,
  ) {
    if (_currentLogLevel == LlamaLogLevel.none) return;

    final dartLevel = switch (level) {
      0 => LlamaLogLevel.none,
      1 => LlamaLogLevel.debug,
      2 => LlamaLogLevel.info,
      3 => LlamaLogLevel.warn,
      4 => LlamaLogLevel.error,
      5 => _currentLogLevel, // CONT (continue) - use current level
      _ => LlamaLogLevel.info,
    };

    if (dartLevel.index >= _currentLogLevel.index) {
      final msg = text.cast<Utf8>().toDartString();
      // llama.cpp often sends partial lines, we just print them using stdout.write
      // In Flutter, stdout.write might not always show up in the debug console,
      // but print() does. However, partial lines are better handled by stdout.
      stdout.write(msg);
    }
  }

  // --- Isolate Entry Point ---
  static void _isolateEntry(SendPort initialSendPort) {
    final receivePort = ReceivePort();
    initialSendPort.send(receivePort.sendPort);

    final state = _LlamaState();

    // Register log callbacks
    final logCallbackPtr = Pointer.fromFunction<ggml_log_callbackFunction>(
      _logCallback,
    );
    llama_log_set(logCallbackPtr, nullptr);
    ggml_log_set(logCallbackPtr, nullptr);

    _log("Isolate: Initializing Backend...");

    // Set environment variable to disable residency sets on macOS 15+
    // This prevents a crash on exit due to an aggressive assertion in llama.cpp
    try {
      if (Platform.isMacOS) {
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
        _log(
          "Isolate: Disabled Metal residency sets to prevent crash on exit.",
        );
      }
    } catch (e) {
      _log(
        "Isolate: Failed to set environment variable: $e",
        level: LlamaLogLevel.error,
      );
    }

    // Initialize backend (native side) - Standard cpp backend init
    try {
      ggml_backend_load_all();
      llama_backend_init();
      _log("Isolate: Backends loaded.");
    } catch (e) {
      _log("Isolate: Failed to load backends: $e", level: LlamaLogLevel.error);
    }

    _log("Isolate: Backend initialized.");

    receivePort.listen((message) {
      if (message is _InitRequest) {
        _handleInit(receivePort, message, state);
      } else if (message is _GenerateRequest) {
        _handleGenerate(receivePort, message, state);
      } else if (message is _TokenizeRequest) {
        _handleTokenize(receivePort, message, state);
      } else if (message is _DetokenizeRequest) {
        _handleDetokenize(receivePort, message, state);
      } else if (message is _MetadataRequest) {
        _handleMetadata(receivePort, message, state);
      } else if (message is _ApplyTemplateRequest) {
        _handleApplyTemplate(receivePort, message, state);
      } else if (message is _BackendInfoRequest) {
        _handleBackendInfo(receivePort, message, state);
      } else if (message is _GpuSupportRequest) {
        _handleGpuSupport(receivePort, message, state);
      } else if (message is _MetadataAllRequest) {
        _handleMetadataAll(receivePort, message, state);
      } else if (message is _ContextSizeRequest) {
        _handleContextSize(receivePort, message, state);
      } else if (message is _TokenCountRequest) {
        _handleTokenCount(receivePort, message, state);
      } else if (message is _DisposeRequest) {
        _handleDispose(receivePort, message, state);
      }
    });
  }

  static void _handleInit(
    ReceivePort receivePort,
    _InitRequest message,
    _LlamaState state,
  ) {
    try {
      _currentLogLevel = message.modelParams.logLevel;
      _log("Isolate: InitRequest received for path: ${message.modelPath}");

      if (!File(message.modelPath).existsSync()) {
        _log("Isolate: File does not exist!");
        message.sendPort.send(
          _ErrorResponse("File not found at ${message.modelPath}"),
        );
        return;
      }

      if (state.model != null) {
        _log("Isolate: Cleaning up previous model...");
        state.ctx?.dispose();
        state.model?.dispose();
        if (state.batch != null) {
          llama_batch_free(state.batch!);
          state.batch = null;
        }
        if (state.sampler != null) {
          llama_sampler_free(state.sampler!);
          state.sampler = null;
        }
        state.model = null;
        state.ctx = null;
      }

      final modelPathPtr = message.modelPath.toNativeUtf8();
      final modelParams = llama_model_default_params();
      modelParams.n_gpu_layers = message.modelParams.gpuLayers;
      modelParams.use_mmap = true;

      _log(
        "Isolate: Loading model with n_gpu_layers = ${modelParams.n_gpu_layers}",
      );

      // --- Backend Selection Logic ---

      // Safety Check: Disable Metal on iOS Simulator by default due to potential instability/crashes
      if (Platform.isIOS &&
          Platform.environment.containsKey('SIMULATOR_DEVICE_NAME')) {
        if (message.modelParams.preferredBackend == GpuBackend.auto) {
          _log(
            "Isolate: iOS Simulator detected. Disabling Metal (n_gpu_layers=0) for stability.",
          );
          modelParams.n_gpu_layers = 0;
        } else if (message.modelParams.preferredBackend == GpuBackend.metal) {
          _log(
            "Isolate: iOS Simulator detected but Metal explicitly requested. Proceeding with caution.",
          );
        }
      }

      Pointer<Pointer<Void>>? devicesPtr;

      if (message.modelParams.preferredBackend != GpuBackend.auto) {
        if (message.modelParams.preferredBackend == GpuBackend.cpu ||
            message.modelParams.preferredBackend == GpuBackend.blas) {
          _log("Isolate: Forcing CPU only (n_gpu_layers = 0)");
          modelParams.n_gpu_layers = 0;
          // We don't necessarily need to restrict 'devices' for CPU,
          // setting gpu layers to 0 is usually sufficient.
        } else {
          // Find the matching device
          final count = NativeHelpers.getDeviceCount();
          int? foundIndex;
          for (int i = 0; i < count; i++) {
            final name = NativeHelpers.getDeviceName(i);
            final desc = NativeHelpers.getDeviceDescription(i);
            _log("Isolate: Found device $i: $name ($desc)");

            bool match = false;
            if (message.modelParams.preferredBackend == GpuBackend.vulkan &&
                name.toLowerCase().contains("vulkan")) {
              match = true;
            }
            if (message.modelParams.preferredBackend == GpuBackend.metal &&
                name.toLowerCase().contains("metal")) {
              match = true;
            }
            if (message.modelParams.preferredBackend == GpuBackend.blas &&
                name.toLowerCase().contains("blas")) {
              match = true;
            }

            if (match) {
              foundIndex = i;
              break;
            }
          }

          if (foundIndex != null) {
            _log(
              "Isolate: Selecting device index $foundIndex for ${message.modelParams.preferredBackend}",
            );
            // specific device selection:
            // Allocate array of pointers: [device_ptr, nullptr]
            // llama_model_params.devices expects a NULL-terminated list.
            devicesPtr = calloc<Pointer<Void>>(2);
            devicesPtr[0] = NativeHelpers.getDevicePointer(
              foundIndex,
            ).cast<Void>();
            devicesPtr[1] = nullptr;

            // Cast to the expected type (Pointer<ggml_backend_dev_t> -> Pointer<Pointer<ggml_backend_device>>)
            // Since our binding uses the typedef, we cast accordingly.
            modelParams.devices = devicesPtr.cast();
          } else {
            _log(
              "Isolate: Warning - Preferred backend ${message.modelParams.preferredBackend} requested but no matching device found. Falling back to auto.",
              level: LlamaLogLevel.warn,
            );
          }
        }
      }

      _log("Isolate: Calling llama_model_load_from_file...");
      final modelPtr = llama_model_load_from_file(
        modelPathPtr.cast(),
        modelParams,
      );
      malloc.free(modelPathPtr);
      if (devicesPtr != null) {
        calloc.free(devicesPtr);
      }

      if (modelPtr == nullptr) {
        _log("Isolate: Failed to load model.", level: LlamaLogLevel.error);
        message.sendPort.send(_ErrorResponse("Failed to load model"));
        return;
      }
      state.model = _LlamaModelWrapper(modelPtr);
      _log("Isolate: Model loaded.");

      final ctxParams = llama_context_default_params();

      // Resolve context size
      int resolvedCtxSize = message.modelParams.contextSize;
      if (resolvedCtxSize <= 0) {
        resolvedCtxSize = llama_model_n_ctx_train(state.model!.pointer);
        _log("Isolate: Auto-detected context size: $resolvedCtxSize");
        // Safety cap for mobile/simulator: 4096
        if (resolvedCtxSize > 4096) {
          _log(
            "Isolate: Capping auto-detected context size to 4096 for stability.",
            level: LlamaLogLevel.warn,
          );
          resolvedCtxSize = 4096;
        }
      }
      ctxParams.n_ctx = resolvedCtxSize;
      ctxParams.n_batch = resolvedCtxSize;
      ctxParams.n_ubatch = resolvedCtxSize;

      _log(
        "Isolate: Context params set (n_ctx=$resolvedCtxSize). Creating context...",
      );
      final ctxPtr = llama_init_from_model(state.model!.pointer, ctxParams);

      if (ctxPtr == nullptr) {
        _log("Isolate: Failed to create context.", level: LlamaLogLevel.error);
        message.sendPort.send(_ErrorResponse("Failed to create context"));
        return;
      }
      state.ctx = _LlamaContextWrapper(ctxPtr, state.model!);
      _log("Isolate: Context created.");

      // Store params with resolved context size
      state.lastModelParams = message.modelParams.copyWith(
        contextSize: resolvedCtxSize,
      );

      // Initialize Sampler
      final samplerChainParams = llama_sampler_chain_default_params();
      state.sampler = llama_sampler_chain_init(samplerChainParams);

      // Dummy sampler
      llama_sampler_chain_add(
        state.sampler!,
        llama_sampler_init_dist(DateTime.now().millisecondsSinceEpoch),
      );

      // Initialize Batch
      state.batch = llama_batch_init(resolvedCtxSize, 0, 1);

      _log("Isolate: Init complete.");
      message.sendPort.send(_DoneResponse());
    } catch (e, stack) {
      _log("Isolate: Error during init: $e", level: LlamaLogLevel.error);
      _log(stack.toString(), level: LlamaLogLevel.error);
      message.sendPort.send(_ErrorResponse(e.toString()));
    }
  }

  static void _handleGenerate(
    ReceivePort receivePort,
    _GenerateRequest message,
    _LlamaState state,
  ) {
    if (state.model == null) {
      message.sendPort.send(_ErrorResponse("Model not initialized"));
      return;
    }

    // Refresh context/batch for each request
    state.ctx?.dispose();
    state.ctx = null;
    if (state.batch != null) llama_batch_free(state.batch!);
    if (state.sampler != null) llama_sampler_free(state.sampler!);

    final ctxParams = llama_context_default_params();
    ctxParams.n_ctx = state.lastModelParams?.contextSize ?? 2048;
    ctxParams.n_batch = ctxParams.n_ctx;
    ctxParams.n_ubatch = ctxParams.n_ctx;
    final ctxPtr = llama_init_from_model(state.model!.pointer, ctxParams);
    if (ctxPtr == nullptr) {
      message.sendPort.send(_ErrorResponse("Failed to refresh context"));
      return;
    }
    state.ctx = _LlamaContextWrapper(ctxPtr, state.model!);

    final samplerChainParams = llama_sampler_chain_default_params();
    state.sampler = llama_sampler_chain_init(samplerChainParams);

    // 1. Repetition Penalty
    llama_sampler_chain_add(
      state.sampler!,
      llama_sampler_init_penalties(64, message.params.penalty, 0.0, 0.0),
    );

    // 2. Top-K
    llama_sampler_chain_add(
      state.sampler!,
      llama_sampler_init_top_k(message.params.topK),
    );

    // 3. Top-P
    llama_sampler_chain_add(
      state.sampler!,
      llama_sampler_init_top_p(message.params.topP, 1),
    );

    // 4. Temperature
    llama_sampler_chain_add(
      state.sampler!,
      llama_sampler_init_temp(message.params.temp),
    );

    // 5. Distribution Sampler
    llama_sampler_chain_add(
      state.sampler!,
      llama_sampler_init_dist(
        message.params.seed ?? DateTime.now().millisecondsSinceEpoch,
      ),
    );

    state.batch = llama_batch_init(ctxParams.n_ctx, 0, 1);

    _log(
      "Isolate: Generating for prompt: ${message.prompt.substring(0, min(100, message.prompt.length))}...",
    );

    // Safety: allocate enough for prompt chars OR context size
    final maxTokensPossible = max(message.prompt.length + 64, ctxParams.n_ctx);
    final tokensPtr = malloc<Int32>(maxTokensPossible);
    final pieceBuf = malloc<Uint8>(256);
    final cancelToken = Pointer<Int8>.fromAddress(message.cancelTokenAddress);

    try {
      // Tokenize
      final promptPtr = message.prompt.toNativeUtf8();
      final vocab = llama_model_get_vocab(state.model!.pointer);

      // Byte length is needed, not string length
      final byteLength = promptPtr.length;

      // Ensure buffer is large enough for tokens (usually n_bytes + special tokens)
      final nTokens = llama_tokenize(
        vocab,
        promptPtr.cast(),
        byteLength,
        tokensPtr,
        message.prompt.length + 8, // Safety margin for special tokens
        true, // add_special (BOS)
        true, // parse_special
      );
      malloc.free(promptPtr);

      if (nTokens < 0) {
        message.sendPort.send(_ErrorResponse("Tokenization failed"));
        return;
      }

      if (nTokens > ctxParams.n_ctx) {
        message.sendPort.send(
          _ErrorResponse(
            "Prompt too long ($nTokens tokens) for context size (${ctxParams.n_ctx})",
          ),
        );
        return;
      }

      // Initial Batch Decode (Prompt)
      final b = state.batch!;
      b.n_tokens = nTokens;

      for (int i = 0; i < nTokens; i++) {
        b.token[i] = tokensPtr[i];
        b.pos[i] = i;
        b.n_seq_id[i] = 1;
        b.seq_id[i][0] = 0;
        b.logits[i] = (i == nTokens - 1) ? 1 : 0;
      }

      if (llama_decode(state.ctx!.pointer, b) != 0) {
        message.sendPort.send(_ErrorResponse("Decode failed"));
        return;
      }

      // Generate Loop
      int currentPos = nTokens;
      String fullGeneratedText = "";

      for (int i = 0; i < message.params.maxTokens; i++) {
        // Sample
        final newTokenId = llama_sampler_sample(
          state.sampler!,
          state.ctx!.pointer,
          b.n_tokens - 1,
        );

        // Check EOG
        if (llama_vocab_is_eog(vocab, newTokenId)) {
          break;
        }

        // Convert to Bytes
        final n = llama_token_to_piece(
          vocab,
          newTokenId,
          pieceBuf.cast(),
          256,
          0,
          false,
        );
        if (n > 0) {
          final bytes = pieceBuf.asTypedList(n).toList();
          message.sendPort.send(_TokenResponse(bytes));

          // Check for stop sequences
          if (message.params.stopSequences.isNotEmpty) {
            final piece = utf8.decode(bytes, allowMalformed: true);
            fullGeneratedText += piece;
            bool stopFound = false;
            for (final stop in message.params.stopSequences) {
              if (fullGeneratedText.endsWith(stop)) {
                stopFound = true;
                break;
              }
            }
            if (stopFound) break;
          }
        }

        // Prepare next batch
        b.n_tokens = 1;
        b.token[0] = newTokenId;
        b.pos[0] = currentPos;
        b.n_seq_id[0] = 1;
        b.seq_id[0][0] = 0;
        b.logits[0] = 1;

        currentPos++;

        if (llama_decode(state.ctx!.pointer, b) != 0) {
          message.sendPort.send(
            _ErrorResponse("Decode failed during generation"),
          );
          break;
        }

        // Check cancellation
        if (cancelToken.value == 1) {
          _log("Isolate: Generation cancelled.");
          break; // Exit loop, will send Done
        }
      }

      message.sendPort.send(_DoneResponse());
    } catch (e, stack) {
      _log("Isolate: Error during generate: $e", level: LlamaLogLevel.error);
      _log(stack.toString(), level: LlamaLogLevel.error);
      message.sendPort.send(_ErrorResponse(e.toString()));
    } finally {
      malloc.free(tokensPtr);
      malloc.free(pieceBuf);
    }
  }

  static void _handleTokenize(
    ReceivePort receivePort,
    _TokenizeRequest message,
    _LlamaState state,
  ) {
    if (state.model == null) {
      message.sendPort.send(_ErrorResponse("Model not initialized"));
      return;
    }

    final promptPtr = message.text.toNativeUtf8();
    final vocab = llama_model_get_vocab(state.model!.pointer);
    final textLen = utf8.encode(message.text).length;

    try {
      int nTokens = -llama_tokenize(
        vocab,
        promptPtr.cast(),
        textLen,
        nullptr,
        0,
        true,
        true,
      );

      final tokensPtr = malloc<Int32>(nTokens + 1);
      final realNTokens = llama_tokenize(
        vocab,
        promptPtr.cast(),
        textLen,
        tokensPtr,
        nTokens + 1,
        true,
        true,
      );

      if (realNTokens < 0) {
        malloc.free(tokensPtr);
        message.sendPort.send(_ErrorResponse("Tokenization failed"));
        return;
      }

      final tokens = <int>[];
      for (int i = 0; i < realNTokens; i++) {
        tokens.add(tokensPtr[i]);
      }

      malloc.free(tokensPtr);
      message.sendPort.send(_TokenizeResponse(tokens));
    } catch (e) {
      message.sendPort.send(_ErrorResponse(e.toString()));
    } finally {
      malloc.free(promptPtr);
    }
  }

  static void _handleDetokenize(
    ReceivePort receivePort,
    _DetokenizeRequest message,
    _LlamaState state,
  ) {
    if (state.model == null) {
      message.sendPort.send(_ErrorResponse("Model not initialized"));
      return;
    }

    final vocab = llama_model_get_vocab(state.model!.pointer);
    final buffer = malloc<Int8>(256);
    final resultBytes = <int>[];

    try {
      for (final token in message.tokens) {
        final n = llama_token_to_piece(
          vocab,
          token,
          buffer.cast(),
          256,
          0,
          true,
        );

        if (n > 0) {
          for (int i = 0; i < n; i++) {
            resultBytes.add(buffer[i]);
          }
        }
      }

      final text = utf8.decode(resultBytes, allowMalformed: true);
      message.sendPort.send(_DetokenizeResponse(text));
    } catch (e) {
      message.sendPort.send(_ErrorResponse(e.toString()));
    } finally {
      malloc.free(buffer);
    }
  }

  static void _handleMetadata(
    ReceivePort receivePort,
    _MetadataRequest message,
    _LlamaState state,
  ) {
    if (state.model == null) {
      message.sendPort.send(_ErrorResponse("Model not initialized"));
      return;
    }

    final keyPtr = message.key.toNativeUtf8();
    // 64KB buffer for metadata
    final buf = malloc<Int8>(1024 * 64);

    try {
      final res = llama_model_meta_val_str(
        state.model!.pointer,
        keyPtr.cast(),
        buf.cast(),
        1024 * 64,
      );

      if (res >= 0) {
        final val = buf.cast<Utf8>().toDartString();
        message.sendPort.send(_MetadataResponse(val));
      } else {
        message.sendPort.send(_MetadataResponse(null));
      }
    } catch (e) {
      message.sendPort.send(_ErrorResponse(e.toString()));
    } finally {
      malloc.free(keyPtr);
      malloc.free(buf);
    }
  }

  static void _handleApplyTemplate(
    ReceivePort receivePort,
    _ApplyTemplateRequest message,
    _LlamaState state,
  ) {
    if (state.model == null) {
      message.sendPort.send(_ErrorResponse("Model not initialized"));
      return;
    }

    final nMsgs = message.messages.length;
    final chatMsgs = malloc<llama_chat_message>(nMsgs);
    final allocatedStrings = <Pointer<Char>>[];

    try {
      for (int i = 0; i < nMsgs; i++) {
        final m = message.messages[i];
        final rolePtr = m.role.toNativeUtf8().cast<Char>();
        final contentPtr = m.content.toNativeUtf8().cast<Char>();
        allocatedStrings.add(rolePtr);
        allocatedStrings.add(contentPtr);

        chatMsgs[i].role = rolePtr;
        chatMsgs[i].content = contentPtr;
      }

      // Fetch template from model metadata
      final keyPtr = "tokenizer.chat_template".toNativeUtf8();
      final tmplBuf = malloc<Char>(1024 * 64);
      final tmplRes = llama_model_meta_val_str(
        state.model!.pointer,
        keyPtr.cast(),
        tmplBuf.cast(),
        1024 * 64,
      );
      malloc.free(keyPtr);

      Pointer<Char> tmplPtr = nullptr;
      if (tmplRes >= 0) {
        tmplPtr = tmplBuf;
        final templateStr = tmplBuf.cast<Utf8>().toDartString();
        _log(
          "Isolate: Using template from metadata (length: ${templateStr.length})",
        );
      } else {
        _log("Isolate: Template metadata NOT found. Using native fallback.");
      }

      _log("Isolate: Applying template to $nMsgs messages:");
      for (int i = 0; i < nMsgs; i++) {
        _log(
          "  [$i] role: ${message.messages[i].role}, content length: ${message.messages[i].content.length}",
        );
      }

      // First call to get required buffer size
      final requiredSize = llama_chat_apply_template(
        tmplPtr,
        chatMsgs,
        nMsgs,
        message.addAssistant,
        nullptr,
        0,
      );

      if (requiredSize < 0) {
        malloc.free(tmplBuf);
        message.sendPort.send(
          _ErrorResponse(
            "Failed to apply chat template (code $requiredSize). Try a different model or check metadata.",
          ),
        );
        return;
      }

      // Allocate buffer and call again
      final buf = malloc<Char>(requiredSize + 1);
      final actualSize = llama_chat_apply_template(
        tmplPtr,
        chatMsgs,
        nMsgs,
        message.addAssistant,
        buf,
        requiredSize + 1,
      );

      malloc.free(tmplBuf);

      if (actualSize < 0) {
        malloc.free(buf);
        message.sendPort.send(
          _ErrorResponse("Failed to apply chat template on second call"),
        );
        return;
      }

      final prompt = buf.cast<Utf8>().toDartString();
      malloc.free(buf);
      message.sendPort.send(_ApplyTemplateResponse(prompt));
    } catch (e) {
      message.sendPort.send(_ErrorResponse(e.toString()));
    } finally {
      for (final ptr in allocatedStrings) {
        malloc.free(ptr);
      }
      malloc.free(chatMsgs);
    }
  }

  static void _handleBackendInfo(
    ReceivePort receivePort,
    _BackendInfoRequest message,
    _LlamaState state,
  ) {
    try {
      String backendName = "CPU";
      final count = ggml_backend_dev_count();
      for (int i = 0; i < count; i++) {
        final dev = ggml_backend_dev_get(i);
        final namePtr = ggml_backend_dev_name(dev);
        if (namePtr != nullptr) {
          final name = namePtr.cast<Utf8>().toDartString();
          if (name.contains("Metal") ||
              name.contains("CUDA") ||
              name.contains("Vulkan")) {
            backendName = name;
            break;
          }
        }
      }
      message.sendPort.send(_BackendInfoResponse(backendName));
    } catch (e) {
      message.sendPort.send(_BackendInfoResponse("CPU (Error: $e)"));
    }
  }

  static void _handleGpuSupport(
    ReceivePort receivePort,
    _GpuSupportRequest message,
    _LlamaState state,
  ) {
    try {
      final supported = llama_supports_gpu_offload();
      message.sendPort.send(_GpuSupportResponse(supported));
    } catch (e) {
      message.sendPort.send(_GpuSupportResponse(false));
    }
  }

  static void _handleContextSize(
    ReceivePort receivePort,
    _ContextSizeRequest message,
    _LlamaState state,
  ) {
    if (state.ctx == null) {
      message.sendPort.send(_ContextSizeResponse(0));
      return;
    }
    final size = llama_n_ctx(state.ctx!.pointer);
    message.sendPort.send(_ContextSizeResponse(size));
  }

  static void _handleTokenCount(
    ReceivePort receivePort,
    _TokenCountRequest message,
    _LlamaState state,
  ) {
    if (state.model == null) {
      message.sendPort.send(_ErrorResponse("Model not initialized"));
      return;
    }

    final promptPtr = message.text.toNativeUtf8();
    final vocab = llama_model_get_vocab(state.model!.pointer);
    final textLen = utf8.encode(message.text).length;

    try {
      int nTokens = -llama_tokenize(
        vocab,
        promptPtr.cast(),
        textLen,
        nullptr,
        0,
        true,
        true,
      );
      message.sendPort.send(_TokenCountResponse(nTokens));
    } catch (e) {
      message.sendPort.send(_ErrorResponse(e.toString()));
    } finally {
      malloc.free(promptPtr);
    }
  }

  static void _handleMetadataAll(
    ReceivePort receivePort,
    _MetadataAllRequest message,
    _LlamaState state,
  ) {
    if (state.model == null) {
      message.sendPort.send(_ErrorResponse("Model not initialized"));
      return;
    }

    final metadata = <String, String>{};
    final keyBuf = malloc<Int8>(1024);
    final valBuf = malloc<Int8>(1024 * 64);

    try {
      final nKeys = llama_model_meta_count(state.model!.pointer);
      for (int i = 0; i < nKeys; i++) {
        final keyLen = llama_model_meta_key_by_index(
          state.model!.pointer,
          i,
          keyBuf.cast(),
          1024,
        );
        if (keyLen >= 0) {
          final key = keyBuf.cast<Utf8>().toDartString();
          final valLen = llama_model_meta_val_str_by_index(
            state.model!.pointer,
            i,
            valBuf.cast(),
            1024 * 64,
          );
          if (valLen >= 0) {
            metadata[key] = valBuf.cast<Utf8>().toDartString();
          }
        }
      }
      message.sendPort.send(_MetadataAllResponse(metadata));
    } catch (e) {
      message.sendPort.send(_ErrorResponse(e.toString()));
    } finally {
      malloc.free(keyBuf);
      malloc.free(valBuf);
    }
  }

  static void _handleDispose(
    ReceivePort receivePort,
    _DisposeRequest message,
    _LlamaState state,
  ) {
    _log("Isolate: Disposing...");
    // Unregister log callbacks
    llama_log_set(nullptr, nullptr);
    ggml_log_set(nullptr, nullptr);

    if (state.batch != null) {
      llama_batch_free(state.batch!);
      state.batch = null;
    }
    if (state.sampler != null) {
      llama_sampler_free(state.sampler!);
      state.sampler = null;
    }

    // Explicitly dispose wrappers which detaches finalizers
    state.ctx?.dispose();
    state.model?.dispose();

    state.ctx = null;
    state.model = null;

    try {
      llama_backend_free();
    } catch (e) {
      _log("Isolate: Error during llama_backend_free: $e");
    }

    _log("Isolate: Disposed.");
    message.sendPort.send(null);
    receivePort.close();
    Isolate.exit();
  }
}

class _LlamaState {
  _LlamaModelWrapper? model;
  _LlamaContextWrapper? ctx;
  Pointer<llama_sampler>? sampler;
  llama_batch? batch;
  ModelParams? lastModelParams;
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
  // ignore: unused_field
  final _LlamaModelWrapper?
  _modelKeepAlive; // Keep model alive while context exists

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
    // Suppress unused warning by reading the field
    final _ = _modelKeepAlive;
    _finalizer?.detach(this);
    llama_free(pointer);
  }
}
