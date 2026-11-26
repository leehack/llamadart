@TestOn('vm')
@Tags(['local-only'])
@Timeout(Duration(minutes: 10))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:llamadart/llamadart.dart';
import 'package:test/test.dart';

/// Compares `topLogprobs` with `llama-server`'s `n_probs` for the same model
/// and prompt.
///
/// Set `LLAMADART_LOGPROBS_MODEL` to a small instruct GGUF, such as
/// `qwen2.5-1.5b-instruct-q4_k_m.gguf`, and put `llama-server` on `PATH` or
/// name it in `LLAMA_SERVER`. Both sides must run on the same kind of device,
/// the host's default: quantized logits differ by about 0.1 nat between CPU
/// and GPU kernels, and on macOS arm64 between the llamadart CPU runtime and
/// stock llama.cpp, so the tolerance only holds for GPU against GPU.
void main() {
  final model = Platform.environment['LLAMADART_LOGPROBS_MODEL'];
  final binary = Platform.environment['LLAMA_SERVER'] ?? 'llama-server';
  final skip = model == null
      ? 'Set LLAMADART_LOGPROBS_MODEL to a small instruct GGUF.'
      : null;
  const topLogprobs = 3;
  const tolerance = 0.02;

  late LlamaEngine engine;
  late Process server;
  late Uri base;
  final client = HttpClient();

  setUpAll(() async {
    if (model == null) return;
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    server = await Process.start(binary, [
      '-m',
      model,
      '--port',
      '$port',
      '-c',
      '2048',
      '-t',
      '2',
      '--no-webui',
    ]);
    unawaited(server.stdout.drain<void>());
    unawaited(server.stderr.drain<void>());
    base = Uri.parse('http://127.0.0.1:$port');
    for (var attempt = 0; attempt < 120; attempt++) {
      try {
        final request = await client.getUrl(base.resolve('/health'));
        final response = await request.close();
        await response.drain<void>();
        if (response.statusCode == 200) break;
      } on SocketException {
        // Not listening yet.
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }

    engine = LlamaEngine(LlamaBackend());
    await engine.loadModel(
      model,
      modelParams: const ModelParams(
        contextSize: 2048,
        numberOfThreads: 2,
        numberOfThreadsBatch: 2,
      ),
    );
  });

  tearDownAll(() async {
    if (model == null) return;
    client.close(force: true);
    server.kill();
    await server.exitCode;
    await engine.dispose();
  });

  Future<List<Map<String, dynamic>>> serverProbs(
    String prompt, {
    required int tokens,
    String? grammar,
  }) async {
    final request = await client.postUrl(base.resolve('/completion'));
    request.headers.contentType = ContentType.json;
    request.write(
      jsonEncode({
        'prompt': prompt,
        'n_predict': tokens,
        'temperature': 0,
        'n_probs': topLogprobs,
        'cache_prompt': false,
        'grammar': ?grammar,
      }),
    );
    final response = await request.close();
    final body = jsonDecode(await response.transform(utf8.decoder).join());
    return (body['completion_probabilities'] as List).cast();
  }

  Future<List<LlamaGeneratedTokenLogprobs>> ours(
    String prompt, {
    required int tokens,
    String? grammar,
    int batch = 1,
  }) async {
    final stream = engine.generate(
      prompt,
      params: GenerationParams(
        maxTokens: tokens,
        temp: 0,
        topK: 1,
        topP: 1,
        penalty: 1,
        seed: 1,
        reusePromptPrefix: false,
        grammar: grammar,
        topLogprobs: topLogprobs,
        streamBatchTokenThreshold: batch,
      ),
    );
    await stream.drain<void>();
    return rawTokenLogprobs(stream)!.toList();
  }

  /// llama-server also reports the end-of-generation token that stopped the
  /// reply (empty bytes), and reports a character split across tokens once,
  /// at its last token, with the bytes of the whole character.
  void expectParity(
    List<LlamaGeneratedTokenLogprobs> actual,
    List<Map<String, dynamic>> expected, {
    bool splitCharacter = false,
  }) {
    final reference = [
      for (final entry in expected)
        if ((entry['bytes'] as List).isNotEmpty) entry,
    ];
    final entries = splitCharacter ? [actual.last] : actual;
    expect(entries, hasLength(reference.length));
    for (final (i, entry) in entries.indexed) {
      final expectedEntry = reference[i];
      expect(entry.sampled.token, expectedEntry['id'], reason: 'token $i');
      expect([
        for (final e in splitCharacter ? actual : [entry]) ...e.sampled.bytes,
      ], (expectedEntry['bytes'] as List).cast<int>());
      expect(
        entry.sampled.logprob,
        closeTo((expectedEntry['logprob'] as num).toDouble(), tolerance),
        reason: 'sampled logprob $i',
      );
      final top = (expectedEntry['top_logprobs'] as List).cast<Map>();
      expect(entry.top.map((t) => t.token), top.map((t) => t['id']));
      for (final (j, alternative) in entry.top.indexed) {
        expect(
          alternative.logprob,
          closeTo((top[j]['logprob'] as num).toDouble(), tolerance),
          reason: 'alternative $j of token $i',
        );
      }
    }
  }

  const prompt = 'The capital of France is';

  test('matches n_probs for greedy generation', () async {
    expectParity(
      await ours(prompt, tokens: 8),
      await serverProbs(prompt, tokens: 8),
    );
  }, skip: skip);

  test(
    'matches n_probs under a grammar that picks an unlikely token',
    () async {
      const grammar = 'root ::= " Berlin"';
      final actual = await ours(prompt, tokens: 4, grammar: grammar);
      expectParity(
        actual,
        await serverProbs(prompt, tokens: 4, grammar: grammar),
      );
      expect(
        actual.any((e) => e.top.every((t) => t.token != e.sampled.token)),
        isTrue,
        reason: 'the grammar picked a token outside the top alternatives',
      );
    },
    skip: skip,
  );

  test('matches n_probs for a character split across tokens', () async {
    const grammar = 'root ::= "🙂"';
    final actual = await ours(prompt, tokens: 6, grammar: grammar);
    expectParity(
      actual,
      await serverProbs(prompt, tokens: 6, grammar: grammar),
      splitCharacter: true,
    );
    expect(utf8.decode([for (final e in actual) ...e.sampled.bytes]), '🙂');
    expect(
      actual.length,
      greaterThan(1),
      reason: 'the model splits the character across tokens',
    );
  }, skip: skip);

  test('reports the same entries for any chunk size', () async {
    final single = await ours(prompt, tokens: 8, batch: 1);
    final batched = await ours(prompt, tokens: 8, batch: 8);
    expect(
      batched.map((e) => e.sampled.token),
      single.map((e) => e.sampled.token),
    );
    expect(
      batched.map((e) => e.sampled.logprob),
      single.map((e) => e.sampled.logprob),
    );
  }, skip: skip);
}
