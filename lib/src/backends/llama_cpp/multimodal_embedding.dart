part of 'llama_cpp_service.dart';

/// Native content embedding operations on the service's existing model/projector.
extension NativeContentEmbeddings on LlamaCppService {
  /// Reports loaded-model support; a missing context performs no native calls.
  LlamaEmbeddingCapabilities getEmbeddingCapabilities(int contextHandle) {
    final context = _contexts[contextHandle];
    final modelHandle = _contextToModel[contextHandle];
    final model = _models[modelHandle];
    if (context == null || model == null || modelHandle == null) {
      return const LlamaEmbeddingCapabilities();
    }
    _ensureContextUsable(contextHandle, context);
    final pooling = _calls.embeddingContextInfo(context.pointer).pooling;
    final modelInfo = _calls.embeddingModelInfo(model.pointer);
    final text =
        pooling != llama_pooling_type.LLAMA_POOLING_TYPE_RANK &&
        !(modelInfo.encoder && modelInfo.decoder);
    final projector = _mtmdContexts[_modelToMtmd[modelHandle]];
    if (!text ||
        projector == null ||
        _calls.mixedBatch == null ||
        _mtmdBarrier == null ||
        _mtmdExitTeardown == null ||
        pooling != llama_pooling_type.LLAMA_POOLING_TYPE_MEAN ||
        _embeddingModelHasCausalAttention(modelHandle) ||
        modelInfo.encoder) {
      return LlamaEmbeddingCapabilities(text: text);
    }
    _calls.failures.ensureUsable(projector, 'This multimodal projector');
    // Extended batches receive exactly one position per row in this adapter.
    if (_calls.embeddingProjectorUsesMrope(projector)) {
      return LlamaEmbeddingCapabilities(text: text);
    }
    return LlamaEmbeddingCapabilities(
      text: text,
      image: _mtmdHasEncoder(projector, audio: false) == true,
      audio: _mtmdHasEncoder(projector, audio: true) == true,
    );
  }

  /// Validates the complete batch before encoding or decoding any input.
  List<List<double>> embedContentBatch(
    int contextHandle,
    List<LlamaEmbeddingInput> inputs, {
    bool normalize = true,
    Pointer<Int8>? cancelToken,
  }) {
    if (inputs.isEmpty) return const [];
    final capabilities = getEmbeddingCapabilities(contextHandle);
    for (final input in inputs) {
      for (final kind in input.partKinds) {
        if (!capabilities.supports(kind)) {
          throw LlamaUnsupportedException(
            'Native ${kind.name} embeddings require a pooled embedding model, '
            'a compatible non-M-RoPE projector and guarded mixed-batch ABI v0.7.0-1.',
          );
        }
      }
    }
    final context = _contexts[contextHandle]!;
    final modelHandle = _contextToModel[contextHandle]!;
    final model = _models[modelHandle]!;
    final modelInfo = _calls.embeddingModelInfo(model.pointer);
    final contextInfo = _calls.embeddingContextInfo(context.pointer);
    final vocab = modelInfo.vocab;
    final projector = _mtmdContexts[_modelToMtmd[modelHandle]];
    final prepared = <_PreparedEmbedding>[];
    void checkCancelled() {
      if (cancelToken != null &&
          cancelToken != nullptr &&
          cancelToken.value != 0) {
        throw LlamaInferenceException('Native content embedding cancelled');
      }
    }

    try {
      for (final input in inputs) {
        checkCancelled();
        if (input.parts.every((part) => part is LlamaTextContent)) {
          final text = input.parts
              .cast<LlamaTextContent>()
              .map((p) => p.text)
              .join();
          final tokens = _tokenizeEmbeddingText(
            vocab,
            text,
            contextInfo.sequenceCapacity,
          );
          _checkEmbeddingPassTokenLimit(
            tokens.length,
            _embeddingPassTokenLimit(
              modelHandle,
              context.pointer,
              modelInfo.encoder,
              contextInfo.pooling,
            ),
          );
          prepared.add(_PreparedEmbedding(text: text));
        } else {
          final item = _prepareEmbedding(input, projector!, vocab);
          prepared.add(item);
          final count = mtmd_helper_get_n_tokens(item.chunks);
          final limits = _calls.embeddingContextInfo(context.pointer);
          final capacity = limits.capacity;
          if (count <= 0 || count > capacity || limits.sequences < 1) {
            throw LlamaInferenceException(
              'Expanded embedding input has $count rows; '
              'one complete input must fit the context, batch and micro-batch capacity ($capacity). '
              'Shorten the input or increase contextSize, batchSize and microBatchSize.',
            );
          }
        }
      }
      final vectors = <List<double>>[];
      for (final item in prepared) {
        checkCancelled();
        if (item.text != null) {
          vectors.add(embed(contextHandle, item.text!, normalize: normalize));
        } else {
          vectors.add(
            _embedPreparedContent(
              context,
              model.pointer,
              projector!,
              item,
              normalize: normalize,
              checkCancelled: checkCancelled,
            ),
          );
        }
      }
      checkCancelled();
      return vectors;
    } finally {
      for (final item in prepared) {
        item.dispose();
      }
    }
  }

  _PreparedEmbedding _prepareEmbedding(
    LlamaEmbeddingInput input,
    Pointer<mtmd_context> projector,
    Pointer<llama_vocab> vocab,
  ) {
    final item = _PreparedEmbedding(
      freeChunks: _mtmdInputChunksFree,
      freeBitmap: _mtmdBitmapFree,
    );
    try {
      item.chunks = _mtmdInputChunksInit();
      if (item.chunks == nullptr) {
        throw LlamaInferenceException(
          'Media embedding token allocation failed',
        );
      }
      final marker = _mtmdDefaultMarker().cast<Utf8>().toDartString();
      final prompt = StringBuffer();
      for (final part in input.parts) {
        if (part is LlamaTextContent) {
          if (part.text.contains(marker)) {
            throw LlamaUnsupportedException(
              'Embedding text contains the reserved native media marker.',
            );
          }
          prompt.write(part.text);
        } else {
          item.bitmaps.add(_embeddingBitmap(projector, part));
          prompt.write(marker);
        }
      }
      final text = prompt.toString();
      using((arena) {
        final nativeText = arena<mtmd_input_text>();
        nativeText.ref
          ..text = text.toNativeUtf8(allocator: arena).cast()
          ..text_len = utf8.encode(text).length
          ..add_special =
              (llama_vocab_bos(vocab) != llama_vocab_eos(vocab) &&
                  llama_vocab_bos(vocab) != -1) &&
              !_promptStartsWithBosToken(vocab, text)
          ..parse_special = true;
        final bitmaps = arena<Pointer<mtmd_bitmap>>(item.bitmaps.length);
        for (var i = 0; i < item.bitmaps.length; i++) {
          bitmaps[i] = item.bitmaps[i];
        }
        if (_mtmdTokenize(
              projector,
              item.chunks,
              nativeText,
              bitmaps,
              item.bitmaps.length,
            ) !=
            0) {
          throw LlamaInferenceException('Media embedding tokenization failed');
        }
      });
      return item;
    } catch (_) {
      item.dispose();
      rethrow;
    }
  }

  Pointer<mtmd_bitmap> _embeddingBitmap(
    Pointer<mtmd_context> projector,
    LlamaContentPart part,
  ) {
    final String? sourcePath;
    Uint8List? bytes;
    Float32List? samples;
    if (part is LlamaImageContent) {
      sourcePath = part.path;
      bytes = part.bytes;
      if (part.url != null) {
        throw LlamaUnsupportedException(
          'Native embedding image URLs are unavailable; provide encoded bytes or a local file.',
        );
      }
    } else {
      final audio = part as LlamaAudioContent;
      sourcePath = audio.path;
      bytes = audio.bytes;
      samples = audio.samples;
    }
    if ([sourcePath, bytes, samples].where((source) => source != null).length !=
        1) {
      throw LlamaUnsupportedException(
        'Native embedding media requires exactly one source.',
      );
    }
    if (sourcePath != null) {
      try {
        bytes = File(sourcePath).readAsBytesSync();
      } on FileSystemException {
        throw LlamaInferenceException(
          'Cannot read native embedding media source',
        );
      }
    }
    if (samples != null &&
        (samples.isEmpty || samples.any((v) => !v.isFinite))) {
      throw LlamaInferenceException(
        'Embedding PCM must contain finite mono 16 kHz samples',
      );
    }
    if (samples != null &&
        _calls.embeddingAudioSampleRate(projector) != 16000) {
      throw LlamaUnsupportedException(
        'Native embedding PCM requires a 16 kHz projector.',
      );
    }
    final bitmap = using((arena) {
      if (samples != null) {
        final data = arena<Float>(samples.length);
        data.asTypedList(samples.length).setAll(0, samples);
        return _mtmdBitmapInitFromAudio(samples.length, data);
      }
      if (bytes!.isEmpty) {
        throw LlamaInferenceException('Encoded embedding media is empty');
      }
      final data = arena<Uint8>(bytes.length);
      data.asTypedList(bytes.length).setAll(0, bytes);
      return _mtmdHelperBitmapInitFromBuf(projector, data.cast(), bytes.length);
    });
    if (bitmap == nullptr) {
      _calls.failures.throwIfCaught(
        'mtmd bitmap constructor',
        LlamaInferenceException.new,
        windowsFreeOnly: [projector],
      );
      throw LlamaInferenceException('Cannot decode embedding media');
    }
    if (mtmd_bitmap_is_audio(bitmap) != (part is LlamaAudioContent)) {
      _mtmdBitmapFree(bitmap);
      throw LlamaUnsupportedException(
        'Embedding media encoding does not match its declared modality.',
      );
    }
    return bitmap;
  }

  List<double> _embedPreparedContent(
    _LlamaContextWrapper context,
    Pointer<llama_model> model,
    Pointer<mtmd_context> projector,
    _PreparedEmbedding input, {
    required bool normalize,
    required void Function() checkCancelled,
  }) {
    final batch = _calls.createEmbeddingBatch(context.pointer);
    final mediaCopies = <Pointer<Float>>[];
    var embeddingsEnabled = false;
    try {
      final width = _calls.embeddingModelInfo(model).inputWidth;
      if (width <= 0) {
        throw LlamaInferenceException('Invalid media embedding input width');
      }
      using((arena) {
        final countPtr = arena<Size>();
        final position = arena<llama_pos>();
        final embd = arena<llama_embd>();
        var row = 0;
        for (var c = 0; c < mtmd_input_chunks_size(input.chunks); c++) {
          checkCancelled();
          final chunk = mtmd_input_chunks_get(input.chunks, c);
          final isText =
              mtmd_input_chunk_get_type(chunk) ==
              mtmd_input_chunk_type.MTMD_INPUT_CHUNK_TYPE_TEXT;
          countPtr.value = mtmd_input_chunk_get_n_tokens(chunk);
          Pointer<llama_token> tokens = nullptr;
          Pointer<Float> media = nullptr;
          if (isText) {
            tokens = mtmd_input_chunk_get_tokens_text(chunk, countPtr);
          } else {
            _calls.encodeEmbeddingChunk(projector, chunk);
            checkCancelled();
            final output = _calls.embeddingMediaOutput(projector);
            if (output == nullptr) {
              throw LlamaInferenceException(
                'Media encoder output is unavailable',
              );
            }
            media = calloc<Float>(countPtr.value * width);
            mediaCopies.add(media);
            media
                .asTypedList(countPtr.value * width)
                .setAll(0, output.asTypedList(countPtr.value * width));
          }
          for (var i = 0; i < countPtr.value; i++, row++) {
            final int index;
            if (isText) {
              index = llama_batch_ext_add_token(batch, 0, tokens[i]);
            } else {
              embd.ref
                ..data = media + i * width
                ..n_rows = 1
                ..n_embd = width;
              index = llama_batch_ext_add_embd(batch, 0, embd.ref);
            }
            position.value = row;
            if (index < 0 ||
                !llama_batch_ext_set_pos(batch, index, position) ||
                !_calls.mixedBatch!.setOutputRow(batch, index, true)) {
              throw LlamaInferenceException(
                'Mixed embedding batch rejected a row',
              );
            }
          }
        }
      });
      checkCancelled();
      _calls.synchronize(context.pointer);
      _clearContextMemory(context.pointer, strict: false);
      context.cachedPromptTokens = null;
      _calls.setEmbeddingOutput(context.pointer, true);
      embeddingsEnabled = true;
      _calls.processEmbeddingBatch(context.pointer, batch);
      checkCancelled();
      final output = _calls.embeddingSequenceOutput(context.pointer);
      if (output == nullptr) {
        throw LlamaInferenceException(
          'Pooled media embedding output is unavailable',
        );
      }
      final vector = List<double>.from(
        output.asTypedList(_calls.embeddingModelInfo(model).outputWidth),
        growable: false,
      );
      return normalize ? _normalizeEmbeddingVector(vector) : vector;
    } finally {
      if (embeddingsEnabled) _calls.setEmbeddingOutput(context.pointer, false);
      llama_batch_ext_free(batch);
      for (final copy in mediaCopies) {
        calloc.free(copy);
      }
    }
  }
}

final class _PreparedEmbedding {
  final String? text;
  Pointer<mtmd_input_chunks> chunks = nullptr;
  final List<Pointer<mtmd_bitmap>> bitmaps = [];

  final void Function(Pointer<mtmd_input_chunks>) freeChunks;
  final void Function(Pointer<mtmd_bitmap>) freeBitmap;

  _PreparedEmbedding({
    this.text,
    this.freeChunks = mtmd_input_chunks_free,
    this.freeBitmap = mtmd_bitmap_free,
  });

  void dispose() {
    if (chunks != nullptr) {
      freeChunks(chunks);
      chunks = nullptr;
    }
    for (final bitmap in bitmaps) {
      freeBitmap(bitmap);
    }
    bitmaps.clear();
  }
}
