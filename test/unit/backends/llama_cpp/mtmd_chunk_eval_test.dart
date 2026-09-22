@TestOn('vm')
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:llamadart/src/backends/llama_cpp/bindings.dart';
import 'package:llamadart/src/backends/llama_cpp/mtmd_chunk_eval.dart';
import 'package:test/test.dart';

const _text = 0;
const _image = 1;
const _audio = 2;
const _nBatch = 512;
const _garbage = 999;

final _ctx = Pointer<mtmd_context>.fromAddress(0x100);
final _lctx = Pointer<llama_context>.fromAddress(0x200);
final _chunks = Pointer<mtmd_input_chunks>.fromAddress(0x300);
final _embd = Pointer<Float>.fromAddress(0x400);

class _FakeChunk {
  const _FakeChunk(this.type, this.nPos);

  final int type;
  final int nPos;
}

class _FakeMtmd {
  _FakeMtmd(this.prompt, this.cancelToken);

  final List<_FakeChunk> prompt;
  final Pointer<Int8> cancelToken;
  final List<String> calls = <String>[];
  final Map<String, int> results = <String, int>{};
  final Set<String> cancelDuring = <String>{};

  int _index(Pointer<mtmd_input_chunk> chunk) => chunk.address - 0x1000;

  int _finish(String call) {
    calls.add(call);
    if (cancelDuring.contains(call)) cancelToken.value = 1;
    return results[call] ?? 0;
  }

  MtmdChunkEvalApi get api => MtmdChunkEvalApi(
    chunksSize: (chunks) {
      expect(chunks, _chunks);
      calls.add('size');
      return prompt.length;
    },
    chunksGet: (chunks, index) {
      expect(chunks, _chunks);
      calls.add('get $index');
      return Pointer<mtmd_input_chunk>.fromAddress(0x1000 + index);
    },
    chunkType: (chunk) {
      calls.add('type ${_index(chunk)}');
      return prompt[_index(chunk)].type;
    },
    evalChunkSingle:
        (ctx, lctx, chunk, nPast, seqId, nBatch, logitsLast, newNPast) {
          expect((ctx, lctx), (_ctx, _lctx));
          final i = _index(chunk);
          newNPast.value += prompt[i].nPos;
          return _finish(
            'single $i nPast=$nPast seq=$seqId batch=$nBatch '
            'logitsLast=$logitsLast',
          );
        },
    encodeChunk: (ctx, chunk) {
      expect(ctx, _ctx);
      return _finish('encode ${_index(chunk)}');
    },
    outputEmbd: (ctx) {
      expect(ctx, _ctx);
      calls.add('embd');
      return _embd;
    },
    decodeImageChunk:
        (
          ctx,
          lctx,
          chunk,
          embd,
          nPast,
          seqId,
          nBatch,
          newNPast,
          callback,
          userData,
        ) {
          expect((ctx, lctx, embd), (_ctx, _lctx, _embd));
          expect((callback, userData), (nullptr, nullptr));
          final i = _index(chunk);
          newNPast.value = nPast + prompt[i].nPos;
          return _finish('decode $i nPast=$nPast seq=$seqId batch=$nBatch');
        },
  );
}

const _asrPrompt = <_FakeChunk>[
  _FakeChunk(_text, 10),
  _FakeChunk(_audio, 104),
  _FakeChunk(_audio, 52),
  _FakeChunk(_text, 6),
];

const _asrPromptCalls = <String>[
  'size',
  'get 0',
  'type 0',
  'single 0 nPast=0 seq=0 batch=512 logitsLast=false',
  'get 1',
  'type 1',
  'encode 1',
  'embd',
  'decode 1 nPast=10 seq=0 batch=512',
  'get 2',
  'type 2',
  'encode 2',
  'embd',
  'decode 2 nPast=114 seq=0 batch=512',
  'get 3',
  'type 3',
  'single 3 nPast=166 seq=0 batch=512 logitsLast=true',
];

void main() {
  late Pointer<Int8> cancelToken;
  late Pointer<llama_pos> newNPast;

  setUp(() {
    cancelToken = calloc<Int8>();
    newNPast = calloc<llama_pos>()..value = _garbage;
  });

  tearDown(() {
    calloc.free(cancelToken);
    calloc.free(newNPast);
  });

  int eval(_FakeMtmd fake) => evalMtmdChunksUntilCancelled(
    fake.api,
    _ctx,
    _lctx,
    _chunks,
    _nBatch,
    newNPast,
    cancelToken,
  );

  test('makes the calls of mtmd_helper_eval_chunks when not cancelled', () {
    final fake = _FakeMtmd(_asrPrompt, cancelToken);

    expect(eval(fake), 0);
    expect(fake.calls, _asrPromptCalls);
    expect(newNPast.value, 172);
  });

  test('evaluates image chunks and unknown chunk types as upstream does', () {
    final fake = _FakeMtmd(const [
      _FakeChunk(_image, 64),
      _FakeChunk(7, 3),
      _FakeChunk(_image, 64),
    ], cancelToken);

    expect(eval(fake), 0);
    expect(fake.calls, [
      'size',
      'get 0',
      'type 0',
      'encode 0',
      'embd',
      'decode 0 nPast=0 seq=0 batch=512',
      'get 1',
      'type 1',
      'single 1 nPast=64 seq=0 batch=512 logitsLast=false',
      'get 2',
      'type 2',
      'encode 2',
      'embd',
      'decode 2 nPast=67 seq=0 batch=512',
    ]);
    expect(newNPast.value, 131);
  });

  test('evaluates nothing when cancelled before the first chunk', () {
    final fake = _FakeMtmd(_asrPrompt, cancelToken);
    cancelToken.value = 1;

    expect(eval(fake), 0);
    expect(fake.calls, ['size']);
    expect(newNPast.value, 0);
  });

  test('stops before the next chunk when cancelled during a text chunk', () {
    final fake = _FakeMtmd(_asrPrompt, cancelToken)
      ..cancelDuring.add(_asrPromptCalls[3]);

    expect(eval(fake), 0);
    expect(fake.calls, _asrPromptCalls.take(4));
    expect(newNPast.value, 10);
  });

  test('stops before the next chunk when cancelled during a decode', () {
    final fake = _FakeMtmd(_asrPrompt, cancelToken)
      ..cancelDuring.add(_asrPromptCalls[8]);

    expect(eval(fake), 0);
    expect(fake.calls, _asrPromptCalls.take(9));
    expect(newNPast.value, 114);
  });

  for (final (encodeCall, completed) in [(6, 10), (11, 114)]) {
    test('skips the decode when cancelled during '
        '${_asrPromptCalls[encodeCall]}', () {
      final fake = _FakeMtmd(_asrPrompt, cancelToken)
        ..cancelDuring.add(_asrPromptCalls[encodeCall]);

      expect(eval(fake), 0);
      expect(fake.calls, _asrPromptCalls.take(encodeCall + 1));
      expect(newNPast.value, completed);
    });
  }

  for (final (failingCall, result) in [(3, -1), (6, 1), (8, 2), (16, 2)]) {
    test('returns $result from ${_asrPromptCalls[failingCall]} '
        'without further calls', () {
      final fake = _FakeMtmd(_asrPrompt, cancelToken)
        ..results[_asrPromptCalls[failingCall]] = result;

      expect(eval(fake), result);
      expect(fake.calls, _asrPromptCalls.take(failingCall + 1));
    });
  }

  test('tryLoad returns null when a library lacks the mtmd symbols', () {
    final library = DynamicLibrary.open(switch (Platform.operatingSystem) {
      'macos' => '/usr/lib/libSystem.B.dylib',
      'windows' => 'kernel32.dll',
      _ => 'libc.so.6',
    });

    expect(MtmdChunkEvalApi.tryLoad(library), isNull);
  });
}
