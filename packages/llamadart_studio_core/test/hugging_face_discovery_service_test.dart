import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

class _HubAdapter implements HttpClientAdapter {
  _HubAdapter(this.responses);

  final List<(int, Object)> responses;
  final List<RequestOptions> requests = [];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    final (status, body) = responses.removeAt(0);
    return ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  test(
    'Hub search sends bounded normalized queries and decodes public metadata',
    () async {
      final adapter = _HubAdapter([
        (
          200,
          [
            'ignore non-object entries',
            {'id': ''},
            {
              'modelId': 'owner/Alternate',
              'downloads': 12.9,
              'tags': 'invalid',
            },
            {
              'id': 'owner/Qwen3',
              'downloads': 42,
              'likes': 3,
              'pipeline_tag': 'text-generation',
              'tags': ['gguf', 99, 'qwen3'],
            },
          ],
        ),
        (200, <Object>[]),
      ]);
      final dio = Dio(BaseOptions(baseUrl: 'https://huggingface.co'))
        ..httpClientAdapter = adapter;
      addTearDown(() => dio.close(force: true));
      final service = HuggingFaceDiscoveryService(dio: dio);
      final hits = await service.searchRepositories(
        '  Qwen3 Montréal  ',
        limit: 4,
        bearerToken: '  synthetic-test-token  ',
      );
      expect(adapter.requests.single.uri.path, '/api/models');
      expect(adapter.requests.single.queryParameters, {
        'search': 'Qwen3 Montréal',
        'filter': 'gguf',
        'sort': 'downloads',
        'direction': '-1',
        'limit': 4,
      });
      expect(
        adapter.requests.single.headers['Authorization'],
        'Bearer synthetic-test-token',
      );
      expect(hits.map((hit) => hit.repoId), ['owner/Alternate', 'owner/Qwen3']);
      expect(hits.first.downloads, 12);
      expect(hits.first.likes, 0);
      expect(hits.first.tags, isEmpty);
      expect(hits.last.pipelineTag, 'text-generation');
      expect(hits.last.tags, ['gguf', 'qwen3']);
      expect(
        await service.searchRepositories('   ', bearerToken: '  '),
        isEmpty,
      );
      expect(
        adapter.requests.last.queryParameters.containsKey('search'),
        isFalse,
      );
      expect(
        adapter.requests.last.headers.containsKey('Authorization'),
        isFalse,
      );
    },
  );

  test(
    'Hub repository discovery pairs projectors only with compatible GGUF files',
    () async {
      final adapter = _HubAdapter([
        (
          200,
          [
            {'type': 'directory', 'path': 'skip'},
            {'type': 'file', 'path': 'README.md', 'size': 10},
            {'type': 'file', 'path': 'mmproj-Q4.gguf', 'size': 32},
            {
              'type': 'file',
              'path': 'mmproj-F16.gguf',
              'lfs': {'size': 256},
            },
            {
              'type': 'file',
              'path': 'weights/Qwen3-Q4_K_M-00001-of-00002.gguf',
              'size': 1,
              'lfs': {'size': 1024},
            },
            {
              'type': 'file',
              'path': 'weights/Qwen3-Q4_K_M-00002-of-00002.gguf',
              'size': 1024,
            },
            {'type': 'file', 'path': 'task.litertlm', 'size': 800},
          ],
        ),
      ]);
      final dio = Dio(BaseOptions(baseUrl: 'https://huggingface.co'))
        ..httpClientAdapter = adapter;
      addTearDown(() => dio.close(force: true));
      final models = await HuggingFaceDiscoveryService(
        dio: dio,
      ).inspectRepositoryFiles(' https://huggingface.co/owner/Qwen3-Test/// ');
      expect(
        adapter.requests.single.uri.path,
        '/api/models/owner/Qwen3-Test/tree/main',
      );
      expect(models, hasLength(2));
      final gguf = models.first;
      expect(
        gguf.id,
        'hf:owner/Qwen3-Test/weights/Qwen3-Q4_K_M-00001-of-00002.gguf',
      );
      expect(
        gguf.sourceUri,
        'https://huggingface.co/owner/Qwen3-Test/resolve/main/weights/Qwen3-Q4_K_M-00001-of-00002.gguf?download=true',
      );
      expect(gguf.publisher, 'owner');
      expect(gguf.quantizationLabel, 'Q4_K_M');
      expect(gguf.supportsThinking, isTrue);
      expect(gguf.supportsVision, isTrue);
      expect(gguf.companions.single.sizeBytes, 256);
      expect(
        gguf.companions.single.sourceUri,
        'https://huggingface.co/owner/Qwen3-Test/resolve/main/mmproj-F16.gguf?download=true',
      );
      expect(gguf.sizeBytes, 1280);
      expect(models.last.companions, isEmpty);
      expect(models.last.supportsVision, isFalse);
      expect(
        models.last.sizeBytes,
        800,
        reason:
            'An unrelated GGUF projector must not inflate a LiteRT-LM download.',
      );
    },
  );

  test(
    'Hub transport failures remain failures instead of empty discovery success',
    () async {
      final adapter = _HubAdapter([
        (503, {'error': 'temporarily unavailable'}),
      ]);
      final dio = Dio(BaseOptions(baseUrl: 'https://huggingface.co'))
        ..httpClientAdapter = adapter;
      addTearDown(() => dio.close(force: true));
      await expectLater(
        HuggingFaceDiscoveryService(dio: dio).searchRepositories('qwen'),
        throwsA(
          isA<DioException>().having(
            (error) => error.response?.statusCode,
            'status',
            503,
          ),
        ),
      );
    },
  );
}
