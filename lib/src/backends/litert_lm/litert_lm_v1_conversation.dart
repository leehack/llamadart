part of 'litert_lm_v1_runtime.dart';

typedef _OwnedCallbackN =
    Void Function(Pointer<Void>, Pointer<Utf8>, Bool, Pointer<Utf8>);
typedef _ChunkCallbackN = Void Function(Pointer<Void>, Pointer<Void>);
typedef _ProxyCreateN =
    Pointer<Void> Function(
      Pointer<NativeFunction<_OwnedCallbackN>>,
      Pointer<Void>,
      Pointer<Pointer<NativeFunction<_ChunkCallbackN>>>,
    );
typedef _ProxyCreateD =
    Pointer<Void> Function(
      Pointer<NativeFunction<_OwnedCallbackN>>,
      Pointer<Void>,
      Pointer<Pointer<NativeFunction<_ChunkCallbackN>>>,
    );
typedef _SendStreamN =
    Int Function(
      Pointer<Void>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Void>,
      Pointer<NativeFunction<_ChunkCallbackN>>,
      Pointer<Void>,
    );
typedef _SendStreamD =
    int Function(
      Pointer<Void>,
      Pointer<Utf8>,
      Pointer<Utf8>,
      Pointer<Void>,
      Pointer<NativeFunction<_ChunkCallbackN>>,
      Pointer<Void>,
    );
typedef _StatusN = Int Function(Pointer<Void>);
typedef _StatusD = int Function(Pointer<Void>);

/// Internal C API 1.0 text conversation; not exported or publicly selected.
///
/// Chunks are copied native message JSON, not parsed content or tool calls.
/// Only one turn may run at a time. A cancelled or failed conversation is
/// deleted after its final callback and successful native drain; recreate it
/// through the runtime. This never enables single-threaded native execution.
final class LiteRtLmV1Conversation {
  LiteRtLmV1Conversation._(this._runtime, int maxOutputTokens) {
    final library = _runtime._library;
    for (final symbol in _symbols) {
      if (!library.providesSymbol(symbol)) {
        throw LlamaUnsupportedException(
          'C API 1.0 conversation preparation requires owner export $symbol.',
        );
      }
    }
    final abi = library.lookupFunction<Int32 Function(), int Function()>(
      'stream_proxy_callback_abi_version',
    )();
    if (abi != 2) {
      throw LlamaUnsupportedException(
        'C API 1.0 conversation requires owner stream proxy callback ABI 2; detected $abi.',
      );
    }
    Pointer<Void> sessionConfig = nullptr, sampler = nullptr, config = nullptr;
    try {
      sessionConfig = _runtime._create(
        'session_config_create',
        _runtime._configCreate,
      );
      _runtime._check(
        _runtime._setOutputTokens(sessionConfig, maxOutputTokens),
        'set_max_output_tokens',
      );
      sampler = _runtime._create(
        'sampler_params_create',
        (out) => _runtime._samplerCreate(2, out),
      );
      _runtime._check(_runtime._samplerTopK(sampler, 1), 'sampler_set_top_k');
      _runtime._check(
        _runtime._samplerTopP(sampler, 0.95),
        'sampler_set_top_p',
      );
      _runtime._check(
        _runtime._samplerTemperature(sampler, 0),
        'sampler_set_temperature',
      );
      _runtime._check(
        _runtime._setSampler(sessionConfig, sampler),
        'set_sampler_params',
      );
      config = _runtime._create('conversation_config_create', _configCreate);
      _runtime._check(
        _setSessionConfig(config, sessionConfig),
        'conversation_config_set_session_config',
      );
      _handle = _runtime._create(
        'conversation_create',
        (out) => _createConversation(_runtime._engine, config, out),
      );
    } finally {
      if (config != nullptr) _configDelete(config);
      if (sampler != nullptr) _runtime._samplerDelete(sampler);
      if (sessionConfig != nullptr) _runtime._configDelete(sessionConfig);
    }
  }

  static const _symbols = <String>[
    'stream_proxy_callback_abi_version',
    'stream_proxy_create',
    'stream_proxy_delete',
    'stream_proxy_free_string',
    'litert_lm_conversation_config_create',
    'litert_lm_conversation_config_delete',
    'litert_lm_conversation_config_set_session_config',
    'litert_lm_conversation_create',
    'litert_lm_conversation_delete',
    'litert_lm_conversation_send_message_stream',
    'litert_lm_conversation_cancel_process',
    'litert_lm_conversation_wait_until_done',
  ];

  final LiteRtLmV1Runtime _runtime;
  Pointer<Void> _handle = nullptr;
  LiteRtLmV1Turn? _turn;
  bool _quarantined = false;

  late final _configCreate = _runtime._library
      .lookupFunction<_CreateN, _CreateD>(
        'litert_lm_conversation_config_create',
      );
  late final _configDelete = _runtime._library
      .lookupFunction<_DeleteN, _DeleteD>(
        'litert_lm_conversation_config_delete',
      );
  late final _setSessionConfig = _runtime._library
      .lookupFunction<_SetPointerN, _SetPointerD>(
        'litert_lm_conversation_config_set_session_config',
      );
  late final _createConversation = _runtime._library
      .lookupFunction<_SessionN, _SessionD>('litert_lm_conversation_create');
  late final _delete = _runtime._library.lookupFunction<_DeleteN, _DeleteD>(
    'litert_lm_conversation_delete',
  );
  late final _send = _runtime._library
      .lookupFunction<_SendStreamN, _SendStreamD>(
        'litert_lm_conversation_send_message_stream',
      );
  late final _cancel = _runtime._library.lookupFunction<_StatusN, _StatusD>(
    'litert_lm_conversation_cancel_process',
  );
  late final _wait = _runtime._library.lookupFunction<_StatusN, _StatusD>(
    'litert_lm_conversation_wait_until_done',
  );
  late final _proxyCreate = _runtime._library
      .lookupFunction<_ProxyCreateN, _ProxyCreateD>('stream_proxy_create');
  late final _proxyDelete = _runtime._library
      .lookupFunction<_DeleteN, _DeleteD>('stream_proxy_delete');
  late final _freeString = _runtime._library
      .lookupFunction<
        Void Function(Pointer<Utf8>),
        void Function(Pointer<Utf8>)
      >('stream_proxy_free_string');

  /// Starts one text-only turn. Inspect [LiteRtLmV1Turn.done] for failures.
  ///
  /// The chunks stream closes after drain; errors are reported only by done,
  /// allowing a caller to await completion without subscribing to chunks.
  LiteRtLmV1Turn sendText(String text) {
    if (_quarantined || _handle == nullptr || _turn != null) {
      throw LlamaStateException(
        'C API 1.0 conversation is closed, quarantined or already streaming.',
      );
    }
    if (text.contains('\u0000')) {
      throw LlamaArgumentException('Conversation text must not contain NUL.');
    }
    final turn = LiteRtLmV1Turn._(this);
    _turn = turn;
    try {
      turn._start(jsonEncode({'role': 'user', 'content': text}));
      return turn;
    } on Object {
      _turn = null;
      _release();
      rethrow;
    }
  }

  void _release() {
    if (_handle != nullptr) _delete(_handle);
    _handle = nullptr;
    if (identical(_runtime._conversation, this)) {
      _runtime._conversation = null;
    }
  }

  /// Deletes an idle conversation exactly once.
  ///
  /// Cancel and await the active turn before closing. Failed drain quarantines
  /// the native family: closing/reuse/disposal is refused rather than risking
  /// a callback use-after-free. A missing final callback also retains handles.
  void close() {
    if (_quarantined || _turn != null) {
      throw LlamaStateException(
        'Await a successful C API 1.0 stream drain before closing.',
      );
    }
    _release();
  }
}

/// An owned internal streaming turn. Strings are copied before native return.
final class LiteRtLmV1Turn {
  LiteRtLmV1Turn._(this._conversation) {
    _chunks = StreamController<String>(onCancel: cancel);
  }

  final LiteRtLmV1Conversation _conversation;
  final Completer<LiteRtLmFinishReason> _done = Completer();
  late final StreamController<String> _chunks;
  late final NativeCallable<_OwnedCallbackN> _callback;
  Pointer<Void> _proxy = nullptr;
  Pointer<Utf8> _message = nullptr;
  bool _cancelled = false;
  bool _finished = false;
  Object? _error;
  bool _errorIsCancellation = false;

  /// Copied raw message JSON chunks; no borrowed native pointer escapes.
  Stream<String> get chunks => _chunks.stream;

  /// Completes only after a final callback and successful native drain.
  ///
  /// Failures, including native drain failure, reject this future. A native
  /// cancellation is a terminal reason, never permission to reuse its handle.
  Future<LiteRtLmFinishReason> get done => _done.future;

  void _start(String message) {
    _message = message.toNativeUtf8(allocator: calloc);
    _callback = NativeCallable<_OwnedCallbackN>.listener(_onChunk);
    final out = calloc<Pointer<NativeFunction<_ChunkCallbackN>>>();
    try {
      _proxy = _conversation._proxyCreate(
        _callback.nativeFunction,
        nullptr,
        out,
      );
      if (_proxy == nullptr || out.value == nullptr) {
        throw LlamaStateException('C API 1.0 stream proxy allocation failed.');
      }
      // Read the thread-local error on this same thread before any other call.
      _conversation._runtime._check(
        _conversation._send(
          _conversation._handle,
          _message,
          nullptr,
          nullptr,
          out.value,
          _proxy,
        ),
        'conversation_send_message_stream',
      );
    } on Object {
      _cleanup();
      rethrow;
    } finally {
      calloc.free(out);
    }
  }

  /// Requests cancellation without freeing callbacks or waiting for native work.
  /// Later chunks are freed and suppressed; the conversation is deleted only
  /// after final+drain. Repeated or completed cancellation is harmless.
  void cancel() {
    if (_finished || _cancelled) return;
    _cancelled = true;
    _conversation._runtime._check(
      _conversation._cancel(_conversation._handle),
      'conversation_cancel_process',
    );
  }

  void _onChunk(
    Pointer<Void> data,
    Pointer<Utf8> chunk,
    bool isFinal,
    Pointer<Utf8> error,
  ) {
    try {
      if (!_finished) {
        if (error != nullptr && _error == null) {
          final nativeError = error.toDartString();
          _errorIsCancellation = RegExp(
            r'^CANCELLED(?::|$)',
          ).hasMatch(nativeError);
          _error = LlamaModelException(
            'C API 1.0 stream failed: ${liteRtLmNativeErrorDetail(code: -1, message: nativeError, paths: _conversation._runtime._diagnosticPaths)}',
          );
        }
        if (chunk != nullptr && !_cancelled && _error == null) {
          _chunks.add(chunk.toDartString());
        }
      }
    } on Object {
      _error ??= LlamaModelException(
        'C API 1.0 stream returned invalid callback data.',
      );
    } finally {
      if (chunk != nullptr) _conversation._freeString(chunk);
      if (error != nullptr) _conversation._freeString(error);
    }
    if (isFinal && !_finished) _finish();
  }

  void _finish() {
    _finished = true;
    final runtime = _conversation._runtime;
    var reason = LiteRtLmFinishReason.unknown;
    try {
      runtime._check(
        _conversation._wait(_conversation._handle),
        'conversation_wait_until_done',
      );
    } on Object catch (failure) {
      // Failed drain supplies no proof that callbacks have stopped. Retain the
      // callback, proxy, message, child and parent instead of unsafe cleanup.
      _conversation._quarantined = true;
      _done.completeError(failure);
      unawaited(_chunks.close());
      return;
    }
    final library = runtime._library;
    if (library.providesSymbol('stream_proxy_finish_reason_abi_version') &&
        library.providesSymbol('stream_proxy_get_finish_reason') &&
        library.lookupFunction<Int32 Function(), int Function()>(
              'stream_proxy_finish_reason_abi_version',
            )() ==
            1) {
      reason = LiteRtLmFinishReason.fromWire(
        library.lookupFunction<
          Int32 Function(Pointer<Void>),
          int Function(Pointer<Void>)
        >('stream_proxy_get_finish_reason')(_proxy),
      );
    }
    // A copied canonical cancellation error is normal only when the native
    // finish-reason extension independently confirms cancellation.
    if (_errorIsCancellation && reason == LiteRtLmFinishReason.cancelled) {
      _error = null;
    }
    if (reason == LiteRtLmFinishReason.error && _error == null) {
      _error = LlamaModelException(
        'C API 1.0 stream ended with a native error.',
      );
    }
    _cleanup();
    _conversation._turn = null;
    if (_cancelled ||
        _error != null ||
        reason == LiteRtLmFinishReason.cancelled ||
        reason == LiteRtLmFinishReason.error) {
      _conversation._release();
    }
    unawaited(_chunks.close());
    if (_error case final failure?) {
      _done.completeError(failure);
    } else {
      _done.complete(reason);
    }
  }

  void _cleanup() {
    if (_proxy != nullptr) _conversation._proxyDelete(_proxy);
    _proxy = nullptr;
    _callback.close();
    if (_message != nullptr) calloc.free(_message);
    _message = nullptr;
  }
}
