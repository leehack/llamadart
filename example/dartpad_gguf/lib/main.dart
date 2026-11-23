import 'dart:async';

import 'package:flutter/material.dart';
import 'package:llamadart/llamadart.dart';

import 'bridge_bootstrap.dart';

void main() => runApp(const GgufApp());

enum _Preset {
  stories(
    'Stories15M · 39.4 MB',
    'ggml-org/stories15M_MOE/resolve/b6dd737497465570b5f5e962dbc9d9454ed1e0eb/'
        'stories15M_MOE-Q8_0.gguf',
    'Once upon a time, a little fox',
  ),
  chat(
    'SmolLM2 135M Instruct · 105.5 MB',
    'unsloth/SmolLM2-135M-Instruct-GGUF/'
        'resolve/9e6855bc4be717fca1ef21360a1db4b29d5c559a/'
        'SmolLM2-135M-Instruct-Q4_K_M.gguf',
    'What are three things to pack for a day hike?',
  );

  const _Preset(this.label, this.download, this.prompt);

  final String label;
  final String download;
  final String prompt;

  Uri get url => Uri.https('huggingface.co', download);
}

Future<LlamaEngine> _createEngine() async {
  try {
    await bootstrapBridge();
  } on LlamaUnsupportedException {
    rethrow;
  } catch (_) {
    throw LlamaUnsupportedException(
      'The Web bridge could not load. Check that your browser can reach '
      'cdn.jsdelivr.net and try again.',
    );
  }
  return LlamaEngine(LlamaBackend());
}

class GgufApp extends StatelessWidget {
  const GgufApp({super.key, this.createEngine = _createEngine});

  final Future<LlamaEngine> Function() createEngine;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GGUF in DartPad',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xff99db97),
          brightness: Brightness.dark,
          surface: const Color(0xff15201c),
        ),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
        ),
      ),
      // The preset menu needs a navigator, but DartPad owns the frame URL.
      builder: (context, _) => Navigator(
        onGenerateRoute: (_) => MaterialPageRoute<void>(
          builder: (_) => _GgufScreen(createEngine: createEngine),
        ),
      ),
    );
  }
}

class _GgufScreen extends StatefulWidget {
  const _GgufScreen({required this.createEngine});

  final Future<LlamaEngine> Function() createEngine;

  @override
  State<_GgufScreen> createState() => _GgufScreenState();
}

class _GgufScreenState extends State<_GgufScreen> {
  final _prompt = TextEditingController(text: _Preset.stories.prompt);
  final _output = StringBuffer();
  LlamaEngine? _engine;
  StreamSubscription<String>? _generation;
  _Preset _preset = _Preset.stories;
  String? _runtime;
  String? _error;
  double? _progress;
  bool _loading = false;
  bool _stopping = false;

  void _selectPreset(_Preset preset) {
    setState(() {
      _preset = preset;
      _prompt.text = preset.prompt;
      _runtime = null;
      _error = null;
      _output.clear();
    });
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _progress = null;
      _runtime = null;
      _error = null;
      _output.clear();
    });
    try {
      final engine = _engine ?? await widget.createEngine();
      if (!mounted) {
        await engine.dispose();
        return;
      }
      _engine = engine;
      await engine.setModel(
        LlamaModel(ModelSource.url(_preset.url)),
        params: const ModelParams(contextSize: 1024),
        onProgress: (progress) {
          if (mounted) setState(() => _progress = progress.fraction);
        },
      );
      final backend = await engine.getBackendName();
      final metadata = await engine.getMetadata();
      final notes = (metadata['llamadart.webgpu.runtime_notes'] ?? '').split(
        ';',
      );
      final threading = notes.contains('core_single_thread')
          ? 'single-thread'
          : notes.contains('core_pthreads:1')
          ? 'threaded'
          : null;
      if (!mounted) return;
      setState(() {
        _runtime = [
          backend,
          ?metadata['llamadart.webgpu.core_variant'],
          ?metadata['llamadart.webgpu.execution'],
          ?threading,
        ].join(' · ');
      });
    } catch (error) {
      if (mounted) setState(() => _error = _describeError(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _describeError(Object error) => switch (error) {
    LlamaUnsupportedException(:final message) => 'Unavailable: $message',
    LlamaModelException(:final message) => 'Model load failed: $message',
    LlamaException(:final message) => message,
    _ => 'The operation failed. Try again.',
  };

  void _run() {
    setState(() {
      _output.clear();
      _error = null;
    });
    try {
      final engine = _engine!;
      final prompt = _prompt.text.trim();
      const params = GenerationParams(maxTokens: 128);
      final text = switch (_preset) {
        _Preset.stories => engine.generate(prompt, params: params),
        _Preset.chat =>
          engine
              .create([
                LlamaChatMessage.fromText(
                  role: LlamaChatRole.user,
                  text: prompt,
                ),
              ], params: params)
              .map((chunk) => chunk.text),
      };
      setState(() {
        _generation = text.listen(
          (chunk) => setState(() => _output.write(chunk)),
          onDone: _finishGeneration,
          onError: (Object error) => _finishGeneration(error),
          cancelOnError: true,
        );
      });
    } catch (error) {
      _finishGeneration(error);
    }
  }

  void _finishGeneration([Object? error]) {
    if (!mounted) return;
    setState(() {
      _generation = null;
      _stopping = false;
      if (error != null) _error = _describeError(error);
    });
  }

  Future<void> _stop() async {
    final generation = _generation!;
    setState(() => _stopping = true);
    try {
      await generation.cancel();
      _finishGeneration();
    } catch (error) {
      _finishGeneration(error);
    }
  }

  @override
  void dispose() {
    _prompt.dispose();
    unawaited(_disposeEngine());
    super.dispose();
  }

  Future<void> _disposeEngine() async {
    try {
      try {
        if (!_stopping) await _generation?.cancel();
      } finally {
        await _engine?.dispose();
      }
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(exception: error, stack: stack),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final running = _generation != null;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 650),
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                const Text(
                  'GGUF in DartPad',
                  style: TextStyle(fontSize: 30, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 24),
                DropdownButtonFormField<_Preset>(
                  initialValue: _preset,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Model'),
                  items: [
                    for (final preset in _Preset.values)
                      DropdownMenuItem(
                        value: preset,
                        child: Text(preset.label),
                      ),
                  ],
                  onChanged: _loading || running
                      ? null
                      : (preset) => _selectPreset(preset!),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton.tonal(
                    onPressed: _loading || running ? null : _load,
                    child: const Text('Load'),
                  ),
                ),
                if (_loading) ...[
                  const SizedBox(height: 12),
                  LinearProgressIndicator(
                    value: _progress,
                    semanticsLabel: 'Loading model',
                  ),
                ],
                if (_runtime case final runtime?) ...[
                  const SizedBox(height: 12),
                  Text(
                    runtime,
                    style: const TextStyle(fontFamily: 'monospace'),
                  ),
                ],
                const SizedBox(height: 24),
                TextField(
                  controller: _prompt,
                  enabled: !running,
                  minLines: 2,
                  maxLines: 5,
                  decoration: const InputDecoration(labelText: 'Prompt'),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 12),
                Align(
                  alignment: Alignment.centerLeft,
                  child: FilledButton(
                    onPressed: running
                        ? (_stopping ? null : _stop)
                        : (_runtime != null && _prompt.text.trim().isNotEmpty
                              ? _run
                              : null),
                    child: Text(running ? 'Stop' : 'Run'),
                  ),
                ),
                if (_error case final error?) ...[
                  const SizedBox(height: 12),
                  Semantics(liveRegion: true, child: Text(error)),
                ],
                if (_output.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  const Text(
                    'Output',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  SelectableText(_output.toString()),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
