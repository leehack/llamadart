@Tags(<String>['local-only'])
library;

import 'dart:io';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

import 'studio_test_fakes.dart';

// Local paths are explicit so this test cannot resolve or download host models.
class _LocalAcceptanceStorage extends FakeStudioStoragePort {
  _LocalAcceptanceStorage(this.paths);

  final Map<String, String> paths;

  @override
  Future<bool> isCached(
    StudioModelDescriptor descriptor, {
    required bool isWeb,
  }) async => paths.containsKey(descriptor.id);

  @override
  Future<ResolvedModelAssets> ensureDownloaded(
    StudioModelDescriptor descriptor, {
    required bool isWeb,
    String? bearerToken,
  }) async {
    final path = paths[descriptor.id];
    if (path == null) throw StateError('No local acceptance model configured.');
    return ResolvedModelAssets(
      descriptor: descriptor,
      primarySource: ModelSource.parse(path),
    );
  }
}

void main() {
  final embedPath = Platform.environment['STUDIO_ACCEPTANCE_EMBED_MODEL'];
  final rerankPath = Platform.environment['STUDIO_ACCEPTANCE_RERANK_MODEL'];
  final configured = embedPath != null && rerankPath != null;

  test(
    'real dedicated models support Playground similarity and Notes retrieval',
    () async {
      expect(File(embedPath!).existsSync(), isTrue);
      expect(File(rerankPath!).existsSync(), isTrue);
      final embedder = CuratedModelCatalog.byId('nomic-embed-text-v1.5-q8-0')!;
      final reranker = CuratedModelCatalog.byId('bge-reranker-v2-m3-q8-0')!;
      final storage = _LocalAcceptanceStorage(<String, String>{
        embedder.id: embedPath,
        reranker.id: rerankPath,
      });
      final port = DirectLlamaPlaygroundPort();
      final lab = LabModelCoordinator(
        storagePort: storage,
        modelLoader: port,
        embeddingPort: port,
        isWeb: false,
        isMobile: false,
      );
      final noteStore = EphemeralNoteStore();
      await noteStore.saveAll(<StudioNote>[
        StudioNote(
          id: 'montreal',
          title: 'Montreal meetup',
          content: 'The Flutter meetup is in Montreal on Thursday evening.',
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ),
        StudioNote(
          id: 'bread',
          title: 'Bread recipe',
          content: 'Bake sourdough bread with flour, water, salt and starter.',
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ),
      ]);
      final notebook = NotebookController(
        storagePort: storage,
        embeddingPort: port,
        rerankerPort: port,
        labModels: lab,
        noteStore: noteStore,
        isWeb: false,
        isMobile: false,
      );
      addTearDown(() async {
        await notebook.dispose();
        await lab.dispose();
        await storage.dispose();
      });
      final watch = Stopwatch()..start();
      await lab.loadLabModel(embedder);
      final similarity = await port.computeEmbeddings(<String>[
        'The Flutter meetup is in Montreal.',
        'The Flutter meetup is in Montreal.',
        'Bake sourdough bread with flour and water.',
      ]);
      expect(similarity.dimensions, greaterThan(0));
      expect(similarity.similarityMatrix[0][1], closeTo(1, 0.00001));
      expect(similarity.similarityMatrix[0][2].isFinite, isTrue);
      expect(similarity.similarityMatrix[0][2], lessThan(0.99));
      await notebook.initialize();
      await notebook.indexNotes();
      expect(notebook.state.errorMessage, isNull);
      expect(notebook.state.indexedNoteCount, 2);
      final semantic = await notebook.searchNotes(
        'Where is the Flutter meetup?',
      );
      expect(notebook.state.errorMessage, isNull);
      expect(semantic.first.note.id, 'montreal');
      await lab.loadLabModel(reranker);
      final ranked = await port.rerank(
        query: 'Where is the Flutter meetup?',
        documents: <String>[
          'Bake sourdough bread with flour and water.',
          'The Flutter meetup is in Montreal on Thursday evening.',
        ],
      );
      expect(ranked.first.originalIndex, 1);
      expect(ranked.every((r) => r.score.isFinite), isTrue);
      final reranked = await notebook.searchNotes(
        'Where is the Flutter meetup?',
        rerank: true,
      );
      expect(notebook.state.errorMessage, isNull);
      expect(reranked.first.note.id, 'montreal');
      expect(reranked.first.rerankScore, isNotNull);
      expect(
        notebook.buildRagChatPrompt('Where is the meetup?', hits: reranked),
        contains('Montreal'),
      );
      print(
        'REAL_STUDIO_ACCEPTANCE dimensions=${similarity.dimensions} '
        'unrelatedSimilarity=${similarity.similarityMatrix[0][2]} '
        'topRerankScore=${ranked.first.score} elapsedMs=${watch.elapsedMilliseconds}',
      );
    },
    skip: configured
        ? false
        : 'Set explicit local embedding and reranker paths.',
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
