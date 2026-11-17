@Tags(<String>['local-only'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio/llamadart_studio.dart';
import 'package:llamadart_studio/src/app/shared_prefs_store.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/fixture_text_input.dart';
import 'support/mobile_default_inputs.dart';

const _enabled = bool.fromEnvironment('STUDIO_MOBILE_DEFAULT_ACCEPTANCE');
const _identity = String.fromEnvironment('STUDIO_MOBILE_DEFAULT_IDENTITY');
const _modelId = 'qwen3.5-0.8b-q4-k-m';
const _arithmetic = 'What is 2 + 2? Reply with just the digit.';
const _expression = '(18.5 * 4) + sqrt(81)';
const _filePath = 'nested/bonjour.txt';
const _original = 'Bonjour Montréal — café ☕\n안녕하세요 🌲\n';
const _edited = 'Salut Québec — café ☕\n안녕하세요 🌲\n';
const _title = 'Montréal — 메모 🌲';
const _body = 'Café, naïve, 안녕하세요 👋\nDeuxième ligne — exact UTF-8.\n';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final results = <String, Object?>{
    for (final name in [
      'chat_arithmetic',
      'chat_math_tool',
      'coding_files',
      'notes_fresh_bootstrap',
    ])
      name: {'status': 'pending'},
  };
  Directory? runDirectory;

  void workflow(
    String name,
    int minutes,
    Future<void> Function(_Workflow harness) body,
  ) {
    testWidgets(
      name,
      (tester) async {
        final priorHitTestPolicy = WidgetController.hitTestWarningShouldBeFatal;
        WidgetController.hitTestWarningShouldBeFatal = true;
        addTearDown(
          () =>
              WidgetController.hitTestWarningShouldBeFatal = priorHitTestPolicy,
        );
        expect(Platform.isAndroid || Platform.isIOS, isTrue);
        final root = Platform.isIOS
            ? await getApplicationDocumentsDirectory()
            : (await getExternalStorageDirectory())!;
        runDirectory ??= Directory(
          '${root.path}/${Platform.isIOS ? 'validation/runs' : 'studio-acceptance'}/'
          '${DateTime.now().toUtc().toIso8601String().replaceAll(':', '-')}-defaults',
        )..createSync(recursive: true);
        final journal = File('${runDirectory!.path}/$name.jsonl');
        final harness = _Workflow(tester, journal);
        addTearDown(harness.close);
        void summary() => File('${runDirectory!.path}/summary.json')
            .writeAsStringSync(
              jsonEncode({
                'schema': 1,
                'suite': 'mobile-default-workflows',
                'cases': results,
                'process_recreation_qualified': false,
              }),
              flush: true,
            );
        results[name] = {'status': 'running'};
        summary();
        Object? failure;
        StackTrace? failureStack;
        Future<void> guard(String phase, Future<void> Function() action) async {
          try {
            await action();
          } catch (error, stack) {
            failure ??= error;
            failureStack ??= stack;
            results[name] = {
              'status': 'failed',
              'phase': phase,
              'error': error.toString(),
              'prior': results[name],
            };
            try {
              harness.record('failed', {
                'operation': phase,
                'exception': error.toString(),
                'stack': stack.toString(),
                ...harness.snapshot(),
              });
            } catch (journalError) {
              debugPrint(
                'Mobile default journal failure: ${journalError.runtimeType}',
              );
            }
          }
        }

        await guard('case', () async {
          await harness.start(name).timeout(const Duration(seconds: 90));
          await body(harness);
          expect(tester.takeException(), isNull);
          results[name] = {'status': 'passed'};
          harness.record('passed');
        });
        await guard('summary_before_cleanup', () async {
          summary();
        });
        await guard('cleanup', harness.close);
        await guard('summary_after_cleanup', () async {
          summary();
        });
        if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
      },
      skip: !_enabled,
      timeout: Timeout(Duration(minutes: minutes)),
    );
  }

  workflow('chat_arithmetic', 3, (h) async {
    await h.activate();
    final message = await h.chat(_arithmetic);
    expect(message.text.trim(), '4');
  });
  workflow('chat_math_tool', 3, (h) async {
    await h.activate();
    final message = await h.chat(
      'Use evaluateMath with expression "$_expression". '
      'Then reply with just the numerical result.',
    );
    final call = message.toolCalls.singleWhere((c) => c.name == 'evaluateMath');
    h.successful(call);
    expect(_arguments(call)['expression'], _expression);
    expect(_result(call)['expression'], _expression);
    expect(_result(call)['result'], 83);
    final finalMath = double.tryParse(message.text.trim());
    expect(finalMath?.isFinite, isTrue);
    expect(finalMath, 83);
  });
  workflow('coding_files', 4, (h) async {
    await h.activate();
    await h.navigate('coding');
    await h.tap('coding_create_local_workspace_button');
    await h.waitFor(
      () => h.deps!.codingController.state.workspaceRoot != null,
      'visible workspace creation',
    );
    final root = h.deps!.codingController.state.workspaceRoot!;
    expect(root.startsWith('${h.data!.path}/coding_workspaces/'), isTrue);
    expect(h.deps!.codingController.state.allowShellCommandTool, isFalse);
    final created = await h.coding(
      'Use write to create $_filePath with exactly this UTF-8 content '
      '(JSON string): ${jsonEncode(_original)}. Then use read on $_filePath '
      'to verify it. Do not use shell commands.',
    );
    final write = created.toolCalls.singleWhere((c) => c.name == 'write');
    h.successful(write);
    expect(_arguments(write)['path'], _filePath);
    expect(_arguments(write)['content'], _original);
    expect(_result(write)['path'], _filePath);
    expect(_result(write)['status'], 'created');
    final firstRead = created.toolCalls.lastWhere((c) => c.name == 'read');
    h.readResult(firstRead, _original);
    expect(
      created.toolCalls.indexOf(write),
      lessThan(created.toolCalls.indexOf(firstRead)),
    );
    await h.disk(File('$root/$_filePath'), _original, 'created_bytes');

    final changed = await h.coding(
      'First use read on $_filePath. Then use edit on $_filePath to replace '
      'exactly "Bonjour Montréal" with "Salut Québec". Then use read again '
      'to verify the entire edited file. Preserve every other byte. '
      'Do not overwrite with write or use shell commands.',
    );
    final edit = changed.toolCalls.singleWhere((c) => c.name == 'edit');
    h.successful(edit);
    expect(_arguments(edit)['path'], _filePath);
    expect(_arguments(edit)['findText'], 'Bonjour Montréal');
    expect(_arguments(edit)['replaceText'], 'Salut Québec');
    expect(_result(edit)['status'], 'patched');
    expect(_result(edit)['path'], _filePath);
    final before = changed.toolCalls.firstWhere((c) => c.name == 'read');
    final after = changed.toolCalls.lastWhere((c) => c.name == 'read');
    h.readResult(before, _original);
    h.readResult(after, _edited);
    expect(
      changed.toolCalls.indexOf(before),
      lessThan(changed.toolCalls.indexOf(edit)),
    );
    expect(
      changed.toolCalls.indexOf(edit),
      lessThan(changed.toolCalls.indexOf(after)),
    );
    expect(
      changed.toolCalls.any((c) => c.name == 'write' || c.name == 'bash'),
      isFalse,
    );
    await h.disk(File('$root/$_filePath'), _edited, 'edited_bytes');
    final files = find.textContaining('Files (');
    await h.tester.tap(files);
    await h.tester.pumpAndSettle();
    await h.tap('coding_file_nested');
    await h.tap('coding_file_$_filePath');
    await h.waitFor(
      () =>
          h.deps!.codingController.state.selectedFileSlice?.content == _edited,
      'file browser text',
    );
    final preview = find.byKey(const Key('coding_file_syntax_preview'));
    await h.tester.pumpAndSettle();
    await h.tester.ensureVisible(preview);
    await h.tester.pumpAndSettle();
    expect(preview, findsOneWidget);
    final displayed = h.tester
        .widgetList<RichText>(
          find.descendant(of: preview, matching: find.byType(RichText)),
        )
        .map((w) => w.text.toPlainText())
        .join('\n');
    expect(displayed, contains('Salut Québec — café ☕'));
    expect(displayed, contains('안녕하세요 🌲'));
    expect(displayed, isNot(contains('Bonjour Montréal')));
    h.record('displayed_file', {'text': displayed});
  });
  workflow('notes_fresh_bootstrap', 2, (h) async {
    await h.navigate('notes');
    await h.tap('vault_new_note_button');
    await h.waitFor(
      () => h.deps!.notebookController.state.selectedNote != null,
      'new note',
    );
    await h.enter('vault_note_title_input', _title);
    await h.enter('vault_note_content_input', _body);
    FocusManager.instance.primaryFocus?.unfocus();
    await h.tester.pumpAndSettle();
    await h.tap('vault_save_note_button');
    await h.waitFor(() {
      final state = h.deps!.notebookController.state;
      return state.selectedNote?.title == _title &&
          state.selectedNote?.content == _body &&
          state.drafts.isEmpty &&
          state.draftSaveErrors.isEmpty;
    }, 'committed note');
    final id = h.deps!.notebookController.state.selectedNote!.id;
    final file = File('${h.data!.path}/notes/$id.json');
    final committed = jsonDecode(await file.readAsString()) as Map;
    expect(committed['title'], _title);
    expect(committed['content'], _body);
    h.record('committed_note', {
      'sha256': (await sha256.bind(file.openRead()).first).toString(),
      'bytes': await file.length(),
    });
    await h.unmount();
    await (await SharedPreferences.getInstance()).reload();
    await h.bootstrap();
    final reopened = h.deps!.notebookController.state.notes.singleWhere(
      (n) => n.id == id,
    );
    expect(reopened.title, _title);
    expect(reopened.content, _body);
    await h.navigate('notes');
    // The new store has exactly one note, selected by the normal editor.
    await h.tester.ensureVisible(
      find.byKey(const Key('vault_note_title_input')),
    );
    await h.tester.pumpAndSettle();
    await h.tester.ensureVisible(
      find.byKey(const Key('vault_note_content_input')),
    );
    await h.tester.pumpAndSettle();
    expect(
      h.tester
          .widget<TextField>(find.byKey(const Key('vault_note_title_input')))
          .controller!
          .text,
      _title,
    );
    expect(
      h.tester
          .widget<TextField>(find.byKey(const Key('vault_note_content_input')))
          .controller!
          .text,
      _body,
    );
    expect(jsonDecode(await file.readAsString()), committed);
    h.record('reopened_note', {
      'same_process_fresh_bootstrap': true,
      'process_recreation_qualified': false,
      'title': reopened.title,
      'body': reopened.content,
    });
  });
}

Map<String, dynamic> _arguments(StudioToolInvocation call) =>
    jsonDecode(call.argumentsJson) as Map<String, dynamic>;
Map<String, dynamic> _result(StudioToolInvocation call) =>
    jsonDecode(call.resultJson!) as Map<String, dynamic>;

class _Workflow {
  _Workflow(this.tester, this.journal);
  final WidgetTester tester;
  final File journal;
  final Stopwatch clock = Stopwatch()..start();
  StudioDependencies? deps;
  Directory? data;
  late Directory models;
  NamespacedAcceptanceStore? kv;
  final String? priorCacheDirectory =
      DefaultModelDownloadManager.globalCacheDirectory;
  bool _closed = false;
  int turns = 0;

  void record(String phase, [Map<String, Object?> fields = const {}]) {
    journal.writeAsStringSync(
      '${jsonEncode({'schema': 1, 'phase': phase, 'elapsed_ms': clock.elapsedMilliseconds, ...fields})}\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  Map<String, Object?> snapshot() {
    final d = deps;
    if (d == null) return {};
    final r = d.modelHubController.runtimeStore.state;
    Map<String, Object?> stream(ActiveTurnStreamState s) => {
      'generating': s.isGenerating,
      'text': s.text,
      'thinking': s.thinkingText,
      'tokens': s.tokensGenerated,
      'elapsed_ms': s.elapsedMs,
      'tools': s.toolInvocations.map((c) => c.toJson()).toList(),
    };
    final settings =
        Map<String, Object?>.from(d.shellController.state.settings.toJson())
          ..remove('modelPath')
          ..remove('mmprojPath')
          ..remove('customModelDirectories');
    return {
      'effective_settings': settings,
      'backend_cached': r.backendName,
      'context_cached': r.resolvedContextSize,
      'gpu_layers_cached': r.resolvedGpuLayers,
      'actual_measurement_available': false,
      'loaded_engine_signature': r.loadedEngineSignature,
      'runtime_phase': r.phase.name,
      'runtime_error': r.errorMessage,
      'chat_error': d.chatController.state.lastTurnError,
      'coding_error': d.codingController.state.lastError,
      'active_skills': d.skillRegistry.state.activeSkills
          .map((s) => s.id)
          .toList(),
      'chat_generating': d.chatController.activeStreamStore.state.isGenerating,
      'coding_generating':
          d.codingController.activeStreamStore.state.isGenerating,
      'user_turns': turns,
      'chat_stream': stream(d.chatController.activeStreamStore.state),
      'coding_stream': stream(d.codingController.activeStreamStore.state),
      'chat_messages': d.chatController.state.activeConversation?.activeBranch
          .map((m) => m.toJson())
          .toList(),
      'coding_messages': d.codingController.state.messages
          .map((m) => m.toJson())
          .toList(),
      'disk': diskSnapshot(),
    };
  }

  Map<String, Object?> diskSnapshot() {
    final root = deps?.codingController.state.workspaceRoot;
    final noteId = deps?.notebookController.state.selectedNote?.id;
    final files = <String, File>{
      if (root != null) _filePath: File('$root/$_filePath'),
      if (data != null && noteId != null)
        'committed_note': File('${data!.path}/notes/$noteId.json'),
    };
    return files.map((name, file) {
      try {
        if (!file.existsSync()) return MapEntry(name, {'exists': false});
        final length = file.lengthSync();
        return MapEntry(name, {
          'exists': true,
          'bytes': length,
          if (length <= 1024 * 1024)
            'sha256': sha256.convert(file.readAsBytesSync()).toString(),
        });
      } catch (error) {
        return MapEntry(name, {'error': error.toString()});
      }
    });
  }

  Future<void> start(String name) async {
    registerFixtureTextInput(tester);
    final identity = jsonDecode(_identity) as Map<String, dynamic>;
    expect(
      RegExp(r'^[a-f0-9]{40}$').hasMatch(identity['source_commit'] as String),
      isTrue,
    );
    record('identity', {
      'build': identity,
      'dart_sdk': Platform.version,
      'platform': Platform.operatingSystem,
      'sole_hardware_override': 'threads2+2',
      'startup_selection_qualified': false,
      'operation_deadline_seconds': 90,
    });
    models = Platform.isIOS
        ? Directory(
            '${File(Platform.resolvedExecutable).parent.path}/studio-mobile-default-models',
          )
        : Directory(
            '${(await getTemporaryDirectory()).path}/studio-mobile-default-models',
          );
    await validateMobileDefaultDirectory(models);
    for (final entry in mobileDefaultAssets.entries) {
      final file = File('${models.path}/${entry.key}');
      final digest = (await sha256.bind(file.openRead()).first).toString();
      record('asset', {
        'name': entry.key,
        'sha256': digest,
        'bytes': await file.length(),
      });
      expect(await file.length(), entry.value['bytes']);
      expect(digest, entry.value['sha256']);
    }
    data = await (await getTemporaryDirectory()).createTemp(
      'studio-default-$name-',
    );
    kv = NamespacedAcceptanceStore(
      SharedPreferencesKeyValueStore(await SharedPreferences.getInstance()),
      '${name}_${DateTime.now().microsecondsSinceEpoch}',
    );
    await bootstrap();
  }

  Future<void> bootstrap() async {
    deps = await StudioDependencies.bootstrapProduction(
      appDataDirectoryOverride: data!.path,
      localModelRootsOverride: [models.path],
      keyValueStoreOverride: kv!,
    ).timeout(const Duration(seconds: 90));
    await tester.pumpWidget(LlamadartStudioApp(dependencies: deps!));
    await tester.pumpAndSettle();
    record('bootstrap', snapshot());
  }

  Future<void> activate() async {
    final d = deps!;
    expect(d.modelHubController.runtimeStore.state.isReady, isFalse);
    await d.shellController.updateSettings(
      (s) => s.copyWith(numberOfThreads: 2, numberOfThreadsBatch: 2),
    );
    await navigate('models');
    await enter('model_hub_search_field', 'qwen3.5 0.8b');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    final curated = CuratedModelCatalog.models.singleWhere(
      (m) => m.id == _modelId,
    );
    expect(d.modelHubController.state.cachedModelIds, contains(_modelId));
    await tap('activate_model_$_modelId');
    await waitFor(
      () =>
          d.modelHubController.runtimeStore.state.isReady &&
          d.shellController.state.activeWorkspace == StudioWorkspace.chat,
      'visible curated activation',
    );
    final s = d.shellController.state.settings;
    record('activated', snapshot());
    expect(
      d.modelHubController.runtimeStore.state.activeDescriptor?.id,
      _modelId,
    );
    expect(s.mmprojPath, '${models.path}/${mobileDefaultAssets.keys.last}');
    expect(s.temperature, curated.preset.temperature);
    expect(s.topK, curated.preset.topK);
    expect(s.topP, curated.preset.topP);
    expect(s.minP, curated.preset.minP);
    expect(s.penalty, curated.preset.penalty);
    expect(s.maxTokens, curated.preset.maxTokens);
    expect(s.thinkingEnabled, curated.preset.thinkingEnabled);
    expect(s.thinkingBudgetTokens, curated.preset.thinkingBudgetTokens);
    expect(s.requestedContextSize, curated.preset.contextSize);
    expect(s.computeDevice, ComputeDevice.auto);
    expect(s.autoTuneHardware, isTrue);
    expect(s.numberOfThreads, 2);
    expect(s.numberOfThreadsBatch, 2);
    expect(s.toolsEnabled, isTrue);
    expect(s.enabledBuiltInTools, const StudioSettings().enabledBuiltInTools);
    expect(d.skillRegistry.state.activeSkills.map((s) => s.id), [
      'builtin:dart-flutter-engineer',
    ]);
    expect(
      d.modelHubController.runtimeStore.state.hasUnappliedEngineChanges(
        s,
        isWeb: false,
      ),
      isFalse,
    );
  }

  Future<void> waitFor(bool Function() done, String phase) async {
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    record('wait_start', {'operation': phase});
    while (!done() && DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    record('wait_end', {'operation': phase, 'done': done(), ...snapshot()});
    expect(done(), isTrue, reason: phase);
    await tester.pump();
    expect(tester.takeException(), isNull, reason: phase);
  }

  Future<void> tap(String key) async {
    // Snackbars can cover mobile controls; wait for the existing notification.
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (find.byType(SnackBar).evaluate().isNotEmpty &&
        DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(find.byType(SnackBar), findsNothing);
    final target = find.byKey(Key(key));
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.tap(target, warnIfMissed: true);
    await tester.pump();
  }

  Future<void> enter(String key, String value) async {
    final target = find.byKey(Key(key));
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await enterFixtureText(tester, target, value);
  }

  Future<void> navigate(String workspace) async {
    await tap('open_sidebar_drawer_button');
    await tester.pumpAndSettle();
    await tap('nav_workspace_$workspace');
    await tester.pumpAndSettle();
  }

  Future<StudioMessage> chat(String prompt) async {
    expect(++turns, lessThanOrEqualTo(1));
    await enter('chat_composer_input', prompt);
    record('before_chat_send', {'prompt': prompt, ...snapshot()});
    await tap('chat_send_button');
    record('after_chat_send', snapshot());
    await waitFor(
      () =>
          !deps!.chatController.activeStreamStore.state.isGenerating &&
          (deps!.chatController.state.activeConversation?.activeBranch.length ??
                  0) >=
              2,
      'chat turn',
    );
    final message =
        deps!.chatController.state.activeConversation!.activeBranch.last;
    record('chat_outcome', {'message': message.toJson(), ...snapshot()});
    expect(deps!.chatController.state.lastTurnError, isNull);
    expect(message.role, StudioRole.assistant);
    for (final call in message.toolCalls) {
      successful(call);
    }
    return message;
  }

  Future<StudioMessage> coding(String prompt) async {
    expect(++turns, lessThanOrEqualTo(2));
    final count = deps!.codingController.state.messages.length;
    await enter('coding_prompt_input', prompt);
    record('before_coding_send', {'prompt': prompt, ...snapshot()});
    await tap('coding_send_button');
    record('after_coding_send', snapshot());
    await waitFor(
      () =>
          !deps!.codingController.activeStreamStore.state.isGenerating &&
          deps!.codingController.state.messages.length >= count + 2,
      'coding turn',
    );
    final message = deps!.codingController.state.messages.last;
    record('coding_outcome', {'message': message.toJson(), ...snapshot()});
    expect(deps!.codingController.state.lastError, isNull);
    expect(message.role, StudioRole.assistant);
    for (final call in message.toolCalls) {
      successful(call);
    }
    return message;
  }

  void successful(StudioToolInvocation call) {
    expect(call.isRunning, isFalse);
    expect(call.isError, isFalse);
    expect(call.resultJson, isNotNull);
    expect(_result(call).containsKey('error'), isFalse);
  }

  void readResult(StudioToolInvocation call, String text) {
    successful(call);
    expect(_arguments(call)['path'], _filePath);
    expect(_result(call)['path'], _filePath);
    final lines = text.split('\n');
    final numbered = [
      for (var i = 0; i < lines.length; i++) '${i + 1}: ${lines[i]}',
    ].join('\n').trimRight();
    expect(_result(call)['content'], numbered);
    expect(_result(call)['truncated'], isFalse);
  }

  Future<void> disk(File file, String expected, String phase) async {
    final bytes = await file.readAsBytes();
    record(phase, {
      'relative_path': _filePath,
      'sha256': sha256.convert(bytes).toString(),
      'bytes': bytes.length,
    });
    expect(bytes, utf8.encode(expected));
  }

  Future<void> unmount() async {
    await tester.pumpWidget(const SizedBox.shrink());
    final prior = deps;
    deps = null;
    await prior?.dispose().timeout(const Duration(seconds: 90));
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    record('before_cleanup', snapshot());
    try {
      await unmount();
      await kv?.removeWrittenKeys().timeout(const Duration(seconds: 90));
      if (data != null) await data!.delete(recursive: true);
      record('cleanup_complete');
    } finally {
      DefaultModelDownloadManager.globalCacheDirectory = priorCacheDirectory;
    }
  }
}
