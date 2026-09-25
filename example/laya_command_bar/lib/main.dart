import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

import 'src/decider.dart';
import 'src/gemma.dart';
import 'src/host.dart';
import 'src/laya.dart';
import 'src/llm.dart';
import 'src/slots.dart';
import 'src/sources.dart';
import 'src/store.dart';
import 'src/ui/command_bar_page.dart';

void main() => runApp(const LayaCommandBarApp());

/// Opens the model folder, then shows the command bar with its four readers.
class LayaCommandBarApp extends StatefulWidget {
  /// Creates the app.
  const LayaCommandBarApp({super.key});

  @override
  State<LayaCommandBarApp> createState() => _LayaCommandBarAppState();
}

class _LayaCommandBarAppState extends State<LayaCommandBarApp> {
  final Map<AppSetting, bool> _settings = {
    for (final s in AppSetting.values) s: s == AppSetting.notifications,
  };
  AppStore? _store;
  List<SourceOption>? _sources;
  String? _error;
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onExitRequested: _onExit);
    unawaited(_open());
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    for (final source in _sources ?? const <SourceOption>[]) {
      unawaited(source.dispose());
    }
    super.dispose();
  }

  /// Frees every model before the app exits: llama.cpp's Metal backend
  /// aborts the process when it exits with GPU buffers still allocated.
  Future<AppExitResponse> _onExit() async {
    await Future.wait([
      for (final source in _sources ?? const <SourceOption>[]) source.dispose(),
    ]);
    return AppExitResponse.exit;
  }

  Future<void> _open() async {
    try {
      final store = await AppStore.open();
      final cpu = isAndroid;
      final sources = [
        SourceOption(
          'Laya',
          'Decision model with a command-tuned head, 527 MB',
          (onStatus) => loadLayaSource(
            head: store.commandHead(),
            downloads: store.downloads,
            cpu: cpu,
            onStatus: onStatus,
          ),
        ),
        SourceOption(
          'EmbeddingGemma',
          'Embeddings and examples, 334 MB',
          (onStatus) async => loadEmbeddingSource(
            downloads: store.downloads,
            cpu: cpu,
            corrections: await store.labels.corrections(),
            onStatus: onStatus,
          ),
        ),
        SourceOption(
          'Qwen2.5',
          'Small LLM scoring each intent name, 1.1 GB',
          (onStatus) async => loadLlmSource(
            downloads: store.downloads,
            cpu: cpu,
            corrections: await store.labels.corrections(),
            onStatus: onStatus,
          ),
        ),
        SourceOption(
          'decider',
          'Decision LLM reading the option letters, 2.0 GB',
          (onStatus) => loadDeciderSource(
            downloads: store.downloads,
            cpu: cpu,
            onStatus: onStatus,
          ),
        ),
      ];
      if (!mounted) return;
      setState(() {
        _store = store;
        _sources = sources;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _setSetting(AppSetting setting, bool on) =>
      setState(() => _settings[setting] = on);

  @override
  Widget build(BuildContext context) {
    final sources = _sources;
    return MaterialApp(
      title: 'Laya Command Bar',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.dark,
      ),
      themeMode: _settings[AppSetting.darkMode]!
          ? ThemeMode.dark
          : ThemeMode.light,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(
            _settings[AppSetting.largeText]! ? 1.2 : 1,
          ),
        ),
        child: child!,
      ),
      home: sources == null
          ? Scaffold(
              body: Center(
                child: _error == null
                    ? const CircularProgressIndicator()
                    : Text('Cannot open the model folder: $_error'),
              ),
            )
          : CommandBarPage(
              sources: sources,
              settings: _settings,
              onSetting: _setSetting,
              labels: _store?.labels,
            ),
    );
  }
}
