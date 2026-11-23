import 'dart:async';

import 'package:flutter/material.dart';
import 'package:genkit/genkit.dart';
import 'package:genkit_google_genai/genkit_google_genai.dart';
import 'package:genkit_llamadart/genkit_llamadart.dart';

import 'bridge_bootstrap.dart';

const _smolLm = LlamaModelDefinition(
  name: 'smollm2',
  modelPath:
      'https://huggingface.co/unsloth/SmolLM2-135M-Instruct-GGUF/resolve/'
      '9e6855bc4be717fca1ef21360a1db4b29d5c559a/'
      'SmolLM2-135M-Instruct-Q4_K_M.gguf',
  modelParams: ModelParams(contextSize: 1024),
  supportsEmbeddings: false,
  supportsTools: false,
  supportsConstrainedOutput: false,
);
const _qwen = LlamaModelDefinition(
  name: 'qwen3',
  modelPath:
      'https://huggingface.co/litert-community/Qwen3-0.6B/resolve/'
      '8d42ab5f1db14cad987fac57aeb17d070f9e180d/'
      'Qwen3-0.6B_dynamic_wi4b32_afp32.litertlm',
  modelParams: ModelParams(contextSize: 1024),
  supportsEmbeddings: false,
  supportsTools: false,
  supportsConstrainedOutput: false,
);
const _geminiModelName = 'gemini-3.5-flash-lite';

void main() => runApp(const GenkitDartPadApp());

GenkitPlugin _googlePlugin(String key) => googleAI(apiKey: key, store: false);

enum _Provider {
  gguf('GGUF'),
  liteRtLm('LiteRT-LM'),
  gemini('Gemini');

  const _Provider(this.label);

  final String label;
}

class GenkitDartPadApp extends StatelessWidget {
  const GenkitDartPadApp({
    super.key,
    this.bootstrapGguf = bootstrapBridge,
    this.bootstrapLiteRt = bootstrapLiteRtLm,
    this.runtimeFactory,
    this.googlePlugin = _googlePlugin,
  });

  final Future<void> Function() bootstrapGguf;
  final Future<void> Function() bootstrapLiteRt;
  final LlamaDartRuntimeFactory? runtimeFactory;
  final GenkitPlugin Function(String key) googlePlugin;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xff17695f),
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
        ),
      ),
      // The Navigator provides text-field overlays without changing the
      // about:srcdoc URL in DartPad's preview iframe.
      builder: (_, _) => Navigator(
        onGenerateRoute: (_) =>
            MaterialPageRoute<void>(builder: (_) => _Playground(app: this)),
      ),
    );
  }
}

class _Playground extends StatefulWidget {
  const _Playground({required this.app});

  final GenkitDartPadApp app;

  @override
  State<_Playground> createState() => _PlaygroundState();
}

class _PlaygroundState extends State<_Playground> {
  final _prompt = TextEditingController(text: 'Tell me a story about a fox.');
  final _apiKey = TextEditingController();
  final _output = StringBuffer();
  _Provider _provider = _Provider.gguf;
  Genkit? _ai;
  LlamaDartPlugin? _local;
  CancellationController? _cancellation;
  bool _loading = false;
  String _status = 'Load a GGUF model to begin.';

  bool get _isGemini => _provider == _Provider.gemini;
  bool get _busy => _loading || _cancellation != null;

  Future<void> _select(_Provider provider) async {
    if (_busy || provider == _provider) return;
    final ai = _ai;
    final local = _local;
    setState(() {
      _provider = provider;
      _ai = null;
      _local = null;
      _apiKey.clear();
      _output.clear();
      _loading = true;
      _status = _isGemini
          ? 'Enter a Gemini API key to connect.'
          : 'Load the ${provider.label} model to begin.';
    });
    try {
      await _close(ai, local);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _load() async {
    if (_busy || _ai != null) return;
    final key = _apiKey.text.trim();
    if (_isGemini && key.isEmpty) return;
    final provider = _provider;
    setState(() {
      _loading = true;
      _status = _isGemini ? 'Setting up Gemini…' : 'Loading ${provider.label}…';
    });

    LlamaDartPlugin? local;
    Genkit? ai;
    try {
      final String status;
      if (provider == _Provider.gemini) {
        _apiKey.clear();
        ai = Genkit(
          plugins: [widget.app.googlePlugin(key)],
          model: googleAI.gemini(_geminiModelName),
          isDevEnv: false,
        );
        status = 'Gemini ready. Generate to verify your key.';
      } else {
        final isGguf = provider == _Provider.gguf;
        await (isGguf
            ? widget.app.bootstrapGguf()
            : widget.app.bootstrapLiteRt());
        if (!mounted) return;
        final model = isGguf ? _smolLm : _qwen;
        local = LlamaDartPlugin(
          models: [model],
          runtimeFactory: widget.app.runtimeFactory,
        );
        final inspection = await local.inspectModel(model.name);
        if (!mounted) return;
        ai = Genkit(
          plugins: [local],
          model: llamaDart.model(model.name),
          isDevEnv: false,
        );
        final backend = inspection.capabilities?.backendName ?? provider.label;
        status = 'Model ready ($backend).';
      }
      setState(() {
        _ai = ai;
        _local = local;
        _status = status;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _status = switch (error) {
            _ when _isGemini => 'Gemini setup failed. Re-enter your API key.',
            LlamaException(:final message) => message,
            _ => 'Could not load ${provider.label}.',
          };
        });
      }
    } finally {
      if (_ai == null) await _close(ai, local);
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _generate() async {
    final ai = _ai;
    final prompt = _prompt.text.trim();
    if (_busy || ai == null || prompt.isEmpty) return;

    final isGemini = _isGemini;
    final isLiteRtLm = _provider == _Provider.liteRtLm;
    final cancellation = CancellationController();
    setState(() {
      _cancellation = cancellation;
      _output.clear();
      _status = 'Generating…';
    });

    try {
      final result = await ai.generate<Object?, Object>(
        // Qwen3 uses the prompt's soft switch with its built-in template.
        prompt: isLiteRtLm ? '$prompt\n/no_think' : prompt,
        config: isGemini
            ? GeminiOptions(maxOutputTokens: 256)
            : LlamaDartGenerationConfig(
                maxTokens: 128,
                // LiteRT-LM Web uses the model's default conversation template.
                enableThinking: isLiteRtLm,
              ),
        cancel: cancellation.token,
        onChunk: (chunk) {
          if (mounted && !cancellation.token.isCancelled) {
            setState(() => _output.write(chunk.text));
          }
        },
      );
      if (!mounted) return;
      _status = switch (result.finishReason) {
        _ when cancellation.token.isCancelled => 'Stopped.',
        FinishReason.aborted => 'Stopped.',
        FinishReason.failed =>
          isGemini
              ? 'Gemini request failed. Check your API key and connection.'
              : result.finishMessage ?? 'Generation failed.',
        FinishReason.blocked => 'The model blocked this response.',
        _ when _output.isEmpty => 'The model returned no response text.',
        _ => 'Done.',
      };
    } catch (_) {
      _status = cancellation.token.isCancelled
          ? 'Stopped.'
          : isGemini
          ? 'Gemini request failed. Check your API key and connection.'
          : 'Generation failed.';
    } finally {
      if (mounted) setState(() => _cancellation = null);
    }
  }

  Future<void> _close(Genkit? ai, LlamaDartPlugin? local) async {
    try {
      await local?.dispose();
    } finally {
      await ai?.shutdown();
    }
  }

  @override
  void dispose() {
    _cancellation?.cancel();
    _prompt.dispose();
    _apiKey.dispose();
    unawaited(_close(_ai, _local));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Genkit model playground')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
            children: [
              SegmentedButton<_Provider>(
                showSelectedIcon: false,
                segments: [
                  for (final provider in _Provider.values)
                    ButtonSegment(value: provider, label: Text(provider.label)),
                ],
                selected: {_provider},
                onSelectionChanged: _busy
                    ? null
                    : (value) => _select(value.single),
              ),
              const SizedBox(height: 16),
              if (_isGemini && _ai == null) ...[
                TextField(
                  controller: _apiKey,
                  decoration: const InputDecoration(
                    labelText: 'Gemini API key',
                  ),
                  obscureText: true,
                  autofillHints: null,
                  autocorrect: false,
                  enableSuggestions: false,
                  enableIMEPersonalizedLearning: false,
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 8),
              ],
              OutlinedButton(
                onPressed:
                    _busy ||
                        _ai != null ||
                        (_isGemini && _apiKey.text.trim().isEmpty)
                    ? null
                    : _load,
                child: Text(_isGemini ? 'Connect' : 'Load'),
              ),
              if (_loading) const LinearProgressIndicator(),
              const SizedBox(height: 16),
              TextField(
                controller: _prompt,
                decoration: const InputDecoration(labelText: 'Prompt'),
                minLines: 2,
                maxLines: 4,
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: _cancellation != null
                    ? () => _cancellation?.cancel()
                    : !_loading && _ai != null && _prompt.text.trim().isNotEmpty
                    ? _generate
                    : null,
                child: Text(_cancellation == null ? 'Generate' : 'Stop'),
              ),
              const SizedBox(height: 8),
              Semantics(
                liveRegion: true,
                label: _status,
                excludeSemantics: true,
                child: Text(_status),
              ),
              const Divider(height: 24),
              SelectionArea(child: Text(_output.toString())),
            ],
          ),
        ),
      ),
    );
  }
}
