@Tags(<String>['local-only'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

import 'studio_test_fakes.dart';

// All inputs are synthetic. Local files are explicit; no discovery or downloads.
void main() {
  final chatPath = Platform.environment['STUDIO_ACCEPTANCE_CHAT_MODEL'];
  final embedPath = Platform.environment['STUDIO_ACCEPTANCE_EMBED_MODEL'];
  final rerankPath = Platform.environment['STUDIO_ACCEPTANCE_RERANK_MODEL'];
  final chatId =
      Platform.environment['STUDIO_ACCEPTANCE_CHAT_MODEL_ID'] ??
      'qwen3.8-27b-ud-q4-k-xl';
  final configured = chatPath != null && embedPath != null;
  late _LocalNotesStorage storage;
  late DirectLlamaInferencePort inference;
  late DirectLlamaPlaygroundPort embeddings;
  late LabModelCoordinator lab;
  late StudioShellController shell;
  late Directory root;
  late NotebookController notebook;
  late StudioNoteStore notes;

  group(
    'bounded real-model Notes qualification',
    () {
      setUpAll(() async {
        expect(File(chatPath!).existsSync(), isTrue);
        expect(File(embedPath!).existsSync(), isTrue);
        if (rerankPath != null) expect(File(rerankPath).existsSync(), isTrue);
        final chat = CuratedModelCatalog.byId(chatId);
        expect(
          chat,
          isNotNull,
          reason: 'Use a curated descriptor matching the local chat model.',
        );
        final embedder = CuratedModelCatalog.byId(
          'nomic-embed-text-v1.5-q8-0',
        )!;
        final reranker = CuratedModelCatalog.byId('bge-reranker-v2-m3-q8-0')!;
        storage = _LocalNotesStorage(<String, String>{
          embedder.id: embedPath,
          reranker.id: ?rerankPath,
        });
        inference = DirectLlamaInferencePort();
        embeddings = DirectLlamaPlaygroundPort();
        lab = LabModelCoordinator(
          storagePort: storage,
          modelLoader: embeddings,
          embeddingPort: embeddings,
          isWeb: false,
          isMobile: false,
        );
        shell = StudioShellController(keyValueStore: InMemoryKeyValueStore());
        await shell.initialize();
        final cpu = Platform.environment['STUDIO_NOTES_ACCEPTANCE_CPU'] == '1';
        final settings = StudioSettings(
          computeDevice: cpu ? ComputeDevice.cpu : ComputeDevice.auto,
          gpuLayers: cpu ? 0 : 99,
          autoTuneHardware: false,
          contextSize: 8192,
          requestedContextSize: 8192,
          numberOfThreads: 2,
          numberOfThreadsBatch: 2,
          maxTokens: 512,
          temperature: 0,
          thinkingEnabled: false,
          enabledBuiltInTools: const <String>[],
        );
        await shell.updateSettings((_) => settings);
        await inference.loadModel(
          assets: ResolvedModelAssets(
            descriptor: chat!,
            primarySource: ModelSource.path(chatPath),
          ),
          settings: settings,
          isWeb: false,
        );
        final runtime = inference.runtimeStore.state;
        expect(runtime.isReady, isTrue);
        if (!cpu) {
          expect(
            runtime.backendName.toLowerCase(),
            contains('metal'),
            reason: 'Default Notes qualification requires the Metal backend.',
          );
          expect(runtime.resolvedGpuLayers, isNotNull);
          expect(
            runtime.resolvedGpuLayers!,
            greaterThan(0),
            reason: 'A CPU fallback does not qualify the Metal profile.',
          );
        }
        await lab.loadLabModel(embedder);
        if (rerankPath != null) await lab.loadLabModel(reranker);
        print(
          'NOTES_QUALIFICATION_RUNTIME ${jsonEncode(<String, Object?>{'chatDescriptor': chatId, 'embeddingDescriptor': embedder.id, 'rerankerDescriptor': rerankPath == null ? null : reranker.id, 'backend': inference.runtimeStore.state.backendName, 'computeDevice': settings.computeDevice.name, 'gpuLayers': settings.gpuLayers, 'resolvedGpuLayers': runtime.resolvedGpuLayers, 'contextSize': settings.contextSize, 'temperature': settings.temperature, 'maxTokens': settings.maxTokens, 'thinkingEnabled': settings.thinkingEnabled})}',
        );
      });
      tearDownAll(() async {
        await lab.dispose();
        await inference.dispose();
        await storage.dispose();
        await shell.dispose();
      });
      setUp(() async {
        root = await Directory.systemTemp.createTemp(
          'studio_notes_qualification_',
        );
        notes = createDefaultNoteStore(
          fallbackKeyValueStore: InMemoryKeyValueStore(),
          directoryPath: root.path,
        );
        await notes.saveAll(_corpus());
        notebook = NotebookController(
          storagePort: storage,
          embeddingPort: embeddings,
          rerankerPort: embeddings,
          labModels: lab,
          noteStore: notes,
          inferencePort: inference,
          shellController: shell,
          isWeb: false,
          isMobile: false,
        );
        await notebook.initialize();
        notebook.setRerankVaultHits(rerankPath != null);
      });
      tearDown(() async {
        await notebook.dispose();
        await root.delete(recursive: true);
      });

      test(
        'retrieves relevant IDs among same-topic and unrelated distractors',
        () async {
          for (final entry in <String, String>{
            'Where does the Cedar Flutter workshop in Montreal take place?':
                'cedar_venue',
            'What food is suitable for guests with peanut allergies at Cedar?':
                'cedar_food',
            'What is the vegetable garden watering schedule?': 'garden',
          }.entries) {
            final hits = await notebook.searchNotes(entry.key, topK: 3);
            print(
              'NOTES_QUALIFICATION_RETRIEVAL ${jsonEncode(<String, Object?>{
                'question': entry.key,
                'expectedFirstId': entry.value,
                'hits': hits.map((h) => <String, Object?>{'id': h.note.id, 'cosine': h.cosineScore, 'rerank': h.rerankScore}).toList(),
              })}',
            );
            expect(notebook.state.errorMessage, isNull);
            expect(hits.first.note.id, entry.value);
          }
        },
      );

      test(
        'synthesizes two sources with citations to both selected note IDs',
        () async {
          final answer = await _answer(
            notebook,
            'For the Cedar Flutter workshop in Montreal, where should volunteers go and at what time must they arrive for setup?',
          );
          expect(answer.toLowerCase(), contains('maple hall'));
          expect(answer, contains('17:30'));
          expect(
            _citedIds(notebook),
            containsAll(<String>['cedar_venue', 'cedar_setup']),
          );
        },
      );

      test(
        'reports contradictory source facts without inventing a resolution',
        () async {
          final answer = await _answer(
            notebook,
            'The two Orbit maintenance notices have the same date and disagree. What duration does each give, and can these notes establish which is authoritative?',
          );
          expect(answer, contains('20'));
          expect(answer, contains('45'));
          expect(
            answer.toLowerCase(),
            matches(RegExp(r'conflict|contradict|disagree|inconsisten')),
          );
          expect(
            answer.toLowerCase(),
            matches(
              RegExp(
                r'cannot|can.t|not establish|not clear|unclear|no .*authorit|not .*authorit|neither',
              ),
            ),
          );
          expect(
            _citedIds(notebook),
            containsAll(<String>['orbit_ops', 'orbit_support']),
          );
        },
      );

      test('abstains when retrieved notes omit the requested fact', () async {
        final answer = await _answer(
          notebook,
          'What is the exact door access code for the Cedar workshop venue? Use only the notes; if it is absent, state that it is not provided.',
        );
        _expectMissing(answer);
        expect(answer, isNot(matches(RegExp(r'\b\d{4,}\b'))));
      });

      test(
        'edits reindex, reload retains vectors, and deleted sources cannot ground answers',
        () async {
          await notebook.indexNotes();
          expect(notebook.state.errorMessage, isNull);
          await notebook.updateNote(
            'cedar_venue',
            content:
                'The Cedar Flutter workshop in Montreal is at Birch Studio, 86 Pine Avenue. This replaces Maple Hall. No door access code is recorded.',
          );
          expect(
            notebook.state.notes
                .firstWhere((n) => n.id == 'cedar_venue')
                .isIndexed,
            isFalse,
          );
          final answer = await _answer(
            notebook,
            'What is the current venue for the Cedar Flutter workshop in Montreal?',
          );
          expect(answer.toLowerCase(), contains('birch studio'));
          expect(_citedIds(notebook), contains('cedar_venue'));
          final reloaded = createDefaultNoteStore(
            fallbackKeyValueStore: InMemoryKeyValueStore(),
            directoryPath: root.path,
          );
          final restored = await reloaded.loadAll();
          expect(restored, hasLength(_corpus().length));
          final venue = restored.firstWhere((n) => n.id == 'cedar_venue');
          expect(venue.content, contains('Birch Studio'));
          expect(venue.isIndexed, isTrue);
          expect(venue.embeddingModelId, 'nomic-embed-text-v1.5-q8-0');
          await notebook.dispose();
          notebook = NotebookController(
            storagePort: storage,
            embeddingPort: embeddings,
            rerankerPort: embeddings,
            labModels: lab,
            noteStore: reloaded,
            inferencePort: inference,
            shellController: shell,
            isWeb: false,
            isMobile: false,
          );
          await notebook.initialize();
          notebook.setRerankVaultHits(rerankPath != null);
          expect(notebook.state.indexedNoteCount, restored.length);
          await notebook.deleteNote('cedar_food');
          expect(
            (await reloaded.loadAll()).any((n) => n.id == 'cedar_food'),
            isFalse,
          );
          final afterDelete = await _answer(
            notebook,
            'Which Cedar workshop caterer can accommodate peanut allergies? Use only the remaining notes; if absent, say it is not provided.',
          );
          _expectMissing(afterDelete);
          expect(
            notebook.state.notebookAnswerSources.any(
              (h) => h.note.id == 'cedar_food',
            ),
            isFalse,
          );
          expect(afterDelete.toLowerCase(), isNot(contains('green fork')));
        },
      );
    },
    skip: configured
        ? false
        : 'Set STUDIO_ACCEPTANCE_CHAT_MODEL and STUDIO_ACCEPTANCE_EMBED_MODEL to explicit local GGUF paths.',
    timeout: const Timeout(Duration(minutes: 10)),
  );
}

Future<String> _answer(NotebookController notebook, String question) async {
  await notebook.askNotebook(question, topK: 4);
  final answer = notebook.state.notebookAnswerText;
  print(
    'NOTES_QUALIFICATION_ANSWER ${jsonEncode(<String, Object?>{
      'question': question,
      'answer': answer,
      'sources': <String, String>{for (var i = 0; i < notebook.state.notebookAnswerSources.length; i++) 'Source ${i + 1}': notebook.state.notebookAnswerSources[i].note.id},
      'elapsedMs': notebook.state.notebookAnswerElapsedMs,
    })}',
  );
  expect(notebook.state.errorMessage, isNull);
  expect(notebook.state.isAnsweringNotebook, isFalse);
  expect(answer.trim(), isNotEmpty);
  _citedIds(notebook);
  return answer;
}

// Marker validity is separate from the factual checks and human output review.
Set<String> _citedIds(NotebookController notebook) {
  final sources = notebook.state.notebookAnswerSources;
  final cited = <String>{};
  for (final marker in RegExp(
    r'\[Source\s+(\d+)\]',
    caseSensitive: false,
  ).allMatches(notebook.state.notebookAnswerText)) {
    final index = int.parse(marker.group(1)!) - 1;
    expect(
      index,
      inInclusiveRange(0, sources.length - 1),
      reason: 'Every numeric citation must resolve to a selected source.',
    );
    cited.add(sources[index].note.id);
  }
  return cited;
}

void _expectMissing(String answer) => expect(
  answer.toLowerCase(),
  matches(
    RegExp(
      r'not (?:provided|recorded|specified|available|mentioned|included|in the)|no .*?(?:information|code|caterer)|cannot|can.t|absent|do not (?:provide|contain|include)|don.t (?:provide|contain|include)',
    ),
  ),
);

List<StudioNote> _corpus() {
  final now = DateTime.utc(2026, 11, 15);
  StudioNote note(String id, String title, String content) => StudioNote(
    id: id,
    title: title,
    content: content,
    createdAt: now,
    updatedAt: now,
  );
  return <StudioNote>[
    note(
      'cedar_venue',
      'Cedar workshop venue',
      'The Cedar Flutter workshop in Montreal is at Maple Hall, 42 Cedar Street. Attendees arrive at 18:00. No door access code is recorded.',
    ),
    note(
      'cedar_setup',
      'Cedar volunteer setup',
      'Volunteers for the Cedar Flutter workshop in Montreal must arrive at 17:30 for projector and microphone setup. The public doors open at 18:00.',
    ),
    note(
      'cedar_food',
      'Cedar catering and allergies',
      'Green Fork caters the Cedar workshop. Peanut allergies can be accommodated with separately packed peanut-free meals; tell the catering lead in advance.',
    ),
    note(
      'orbit_ops',
      'Orbit operations maintenance notice',
      'Dated November 10, 2026. Orbit maintenance lasts 20 minutes. This notice gives no approval status or priority over the support notice.',
    ),
    note(
      'orbit_support',
      'Orbit support maintenance notice',
      'Dated November 10, 2026. Orbit maintenance lasts 45 minutes. This notice gives no approval status or priority over the operations notice.',
    ),
    note(
      'garden',
      'Vegetable garden schedule',
      'Water the vegetable garden on Tuesday and Saturday mornings. Tomatoes need support stakes.',
    ),
    note(
      'coffee',
      'Coffee grinder maintenance',
      'Clean the burr grinder weekly. Replace the espresso water filter every two months.',
    ),
    note(
      'harbor',
      'Harbor Flutter workshop in Quebec City',
      'The Harbor Flutter workshop in Quebec City is at River Room, 19 Harbor Lane. Volunteers arrive at 16:15. Blue Spoon caters.',
    ),
    note(
      'incident',
      'Build farm incident',
      'The build farm network interruption lasted 12 minutes. Rotate the cached runner image after the outage.',
    ),
    note(
      'budget',
      'Workshop accounting',
      'The Cedar workshop has a projector rental budget of 180 dollars. Submit receipts by Friday. This budget note does not list venue access or dietary arrangements.',
    ),
  ];
}

class _LocalNotesStorage extends FakeStudioStoragePort {
  _LocalNotesStorage(this.paths);
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
    if (path == null) {
      throw StateError('No explicit local qualification model.');
    }
    return ResolvedModelAssets(
      descriptor: descriptor,
      primarySource: ModelSource.path(path),
    );
  }
}
