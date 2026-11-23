import 'dart:async';

import 'package:flutter/material.dart';
import 'package:llamadart/llamadart.dart';

import 'bridge_bootstrap.dart';

const _modelUrl =
    'https://huggingface.co/ggml-org/stories15M_MOE/'
    'resolve/b6dd737497465570b5f5e962dbc9d9454ed1e0eb/stories15M_MOE-Q8_0.gguf';

void main() => runApp(const GgufApp());

Future<LlamaEngine> _createEngine() async {
  await bootstrapBridge();
  return LlamaEngine(LlamaBackend());
}

class GgufApp extends StatelessWidget {
  const GgufApp({super.key, this.createEngine = _createEngine});

  final Future<LlamaEngine> Function() createEngine;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      // The Navigator provides overlays without writing to the iframe URL.
      builder: (_, _) => Navigator(
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
  final _prompt = TextEditingController(text: 'Once upon a time, a little fox');
  final _output = StringBuffer();
  LlamaEngine? _engine;
  double? _progress;
  bool _ready = false;
  bool _loading = false;
  bool _generating = false;
  String _status = 'Load Stories15M to begin.';

  Future<void> _load() => _run('Loading Stories15M…', () async {
    _loading = true;
    _progress = null;
    final engine = _engine ?? await widget.createEngine();
    if (!mounted) {
      await engine.dispose();
      return;
    }
    _engine = engine;
    await engine.setModel(
      LlamaModel(ModelSource.url(Uri.parse(_modelUrl))),
      params: const ModelParams(contextSize: 1024),
      onProgress: (progress) {
        if (mounted) setState(() => _progress = progress.fraction);
      },
    );
    _ready = true;
    _status = 'Model ready.';
  });

  Future<void> _generate() => _run('Generating…', () async {
    _generating = true;
    _output.clear();
    final chunks = _engine!.generate(
      _prompt.text.trim(),
      params: const GenerationParams(maxTokens: 128),
    );
    await for (final chunk in chunks) {
      if (!mounted) break;
      setState(() => _output.write(chunk));
    }
    _status = 'Model ready.';
  });

  Future<void> _run(String status, Future<void> Function() action) async {
    setState(() => _status = status);
    try {
      await action();
    } on LlamaException catch (error) {
      _status = error.message;
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
          _generating = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _prompt.dispose();
    unawaited(_engine?.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('GGUF in DartPad')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          FilledButton(
            onPressed: _loading || _ready ? null : _load,
            child: const Text('Load'),
          ),
          if (_loading)
            LinearProgressIndicator(
              value: _progress,
              semanticsLabel: 'Loading model',
            ),
          const SizedBox(height: 16),
          TextField(
            controller: _prompt,
            decoration: const InputDecoration(labelText: 'Prompt'),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _generating
                ? _engine!.cancelGeneration
                : _ready && _prompt.text.trim().isNotEmpty
                ? _generate
                : null,
            child: Text(_generating ? 'Stop' : 'Generate'),
          ),
          Semantics(liveRegion: true, child: Text(_status)),
          const SizedBox(height: 12),
          SelectableText(_output.toString()),
        ],
      ),
    );
  }
}
