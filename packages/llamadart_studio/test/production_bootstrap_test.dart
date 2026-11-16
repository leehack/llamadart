@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio/llamadart_studio.dart';
import 'package:llamadart_studio/main.dart' as app;
import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'production entrypoint boots and persists only in isolated mobile app data',
    (tester) async {
      final directory = Directory.systemTemp.createTempSync(
        'studio_bootstrap_',
      );
      final support = Directory('${directory.path}/support')..createSync();
      final working = Directory('${directory.path}/workspace')..createSync();
      final previousDirectory = Directory.current;
      final previousTarget = debugDefaultTargetPlatformOverride;
      final previousCache = DefaultModelDownloadManager.globalCacheDirectory;
      final previousFlutterError = FlutterError.onError;
      final previousPlatformError = PlatformDispatcher.instance.onError;
      final previousErrorWidget = ErrorWidget.builder;
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      final messenger = tester.binding.defaultBinaryMessenger;
      StudioDependencies? dependencies;
      SharedPreferences.setMockInitialValues({
        'studio.settings.v1': jsonEncode(
          const StudioSettings(
            autoLoadLastModel: false,
            toolsEnabled: false,
          ).toJson(),
        ),
      });
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getApplicationSupportDirectory') {
          return support.path;
        }
        return '${directory.path}/temporary';
      });
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      Directory.current = working;
      try {
        // Verify the platform implementation resolves the sandbox before main
        // can construct any persistent store or download manager.
        await tester.runAsync(() async {
          expect((await getApplicationSupportDirectory()).path, support.path);
          await app.main();
        });
        FlutterError.onError = previousFlutterError;
        PlatformDispatcher.instance.onError = previousPlatformError;
        ErrorWidget.builder = previousErrorWidget;
        await tester.pump();
        final widget = tester.widget<LlamadartStudioApp>(
          find.byType(LlamadartStudioApp),
        );
        final deps = widget.dependencies;
        dependencies = deps;
        expect(deps.isMobile, isTrue);
        expect(deps.shellController.currentSettings.autoLoadLastModel, isFalse);
        expect(
          deps.modelHubController.runtimeStore.state.activeDescriptor,
          isNull,
        );
        expect(deps.modelHubController.state.localModels, isEmpty);
        final appData = '${support.path}/llamadart_studio';
        expect(
          DefaultModelDownloadManager.globalCacheDirectory,
          '$appData/model_cache',
        );
        await tester.runAsync(() async {
          final note = await deps.notebookController.createNote(
            title: 'Isolated bootstrap',
            content: 'Saved through production storage.',
          );
          expect(await File('$appData/notes/${note.id}.json').exists(), isTrue);
          expect(deps.codingController.state.workspaceRoot, isNull);
          final localRoot = await deps.createLocalCodingWorkspace();
          expect(
            Directory(localRoot).parent.path,
            '$appData/coding_workspaces',
          );
          await deps.codingController.setWorkspaceRoot(localRoot);
          expect(deps.codingController.state.workspaceRoot, localRoot);
          expect(deps.codingController.state.lastError, isNull);
          await deps.shellController.updateSettings(
            (s) => s.copyWith(maxTokens: 321),
          );
          final preferences = await SharedPreferences.getInstance();
          final saved =
              jsonDecode(preferences.getString('studio.settings.v1')!) as Map;
          expect(saved['maxTokens'], 321);
        });
        expect(deps.mcpManager.state.servers, isEmpty);
      } finally {
        FlutterError.onError = previousFlutterError;
        PlatformDispatcher.instance.onError = previousPlatformError;
        ErrorWidget.builder = previousErrorWidget;
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(() async {
          await dependencies?.dispose();
        });
        messenger.setMockMethodCallHandler(channel, null);
        SharedPreferences.setMockInitialValues(<String, Object>{});
        DefaultModelDownloadManager.globalCacheDirectory = previousCache;
        debugDefaultTargetPlatformOverride = previousTarget;
        Directory.current = previousDirectory;
        directory.deleteSync(recursive: true);
      }
    },
  );
}
