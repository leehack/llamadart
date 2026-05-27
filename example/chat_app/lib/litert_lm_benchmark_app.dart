import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:llamadart/llamadart.dart';

const _defaultPrompt =
    'Write a concise explanation of why on-device language models are useful.';

void main() {
  runApp(const LiteRtLmBenchmarkApp());
}

class LiteRtLmBenchmarkApp extends StatefulWidget {
  const LiteRtLmBenchmarkApp({super.key});

  @override
  State<LiteRtLmBenchmarkApp> createState() => _LiteRtLmBenchmarkAppState();
}

class _LiteRtLmBenchmarkAppState extends State<LiteRtLmBenchmarkApp> {
  final _modelPathController = TextEditingController(
    text: const String.fromEnvironment('LITERT_LM_MODEL'),
  );
  final _llamaModelPathController = TextEditingController(
    text: const String.fromEnvironment('LLAMADART_MODEL'),
  );
  final _promptController = TextEditingController(
    text: const String.fromEnvironment(
      'LITERT_LM_PROMPT',
      defaultValue: _defaultPrompt,
    ),
  );
  final _log = StringBuffer();
  bool _running = false;
  bool _autoRunStarted = false;
  String _backend = const String.fromEnvironment(
    'LITERT_LM_BACKEND',
    defaultValue: 'gpu',
  );
  bool _speculative = const bool.fromEnvironment(
    'LITERT_LM_SPECULATIVE',
    defaultValue: true,
  );
  int _maxTokens = const int.fromEnvironment(
    'LITERT_LM_MAX_TOKENS',
    defaultValue: 4096,
  );
  int _outputTokens = const int.fromEnvironment(
    'LITERT_LM_OUTPUT_TOKENS',
    defaultValue: 256,
  );
  int _warmups = const int.fromEnvironment(
    'LITERT_LM_WARMUPS',
    defaultValue: 1,
  );
  int _runs = const int.fromEnvironment('LITERT_LM_RUNS', defaultValue: 3);
  final bool _autoRun = const bool.fromEnvironment(
    'BENCHMARK_AUTO_RUN',
    defaultValue: false,
  );
  final String _cacheDir = const String.fromEnvironment('LITERT_LM_CACHE_DIR');

  @override
  void initState() {
    super.initState();
    if (_autoRun) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_autoRunStarted) {
          _autoRunStarted = true;
          _runBenchmarks();
        }
      });
    }
  }

  @override
  void dispose() {
    _modelPathController.dispose();
    _llamaModelPathController.dispose();
    _promptController.dispose();
    super.dispose();
  }

  Future<void> _runBenchmarks() async {
    final modelPath = _modelPathController.text.trim();
    final llamaModelPath = _llamaModelPathController.text.trim();
    if (modelPath.isEmpty && llamaModelPath.isEmpty) {
      _append('Set LITERT_LM_MODEL and/or LLAMADART_MODEL.');
      return;
    }
    setState(() {
      _running = true;
      _log.clear();
    });

    if (modelPath.isNotEmpty) {
      try {
        await _runLiteRtBenchmark(modelPath);
      } catch (error, stackTrace) {
        _append('ERROR litert_lm: $error');
        _append(stackTrace.toString());
      }
    }
    if (llamaModelPath.isNotEmpty) {
      try {
        await _runLlamaDartBenchmark(llamaModelPath);
      } catch (error, stackTrace) {
        _append('ERROR llamadart: $error');
        _append(stackTrace.toString());
      }
    }
    _append('BENCHMARK_DONE');
    if (mounted) {
      setState(() {
        _running = false;
      });
    }
  }

  void _append(String value) {
    // ignore: avoid_print
    print('BENCHMARK: $value');
    setState(() {
      _log.writeln(value);
    });
  }

  Future<void> _runLiteRtBenchmark(String modelPath) async {
    final engine = LlamaEngine(LiteRtLmBackend(preferredBackend: _backend));
    try {
      _append('=== LiteRT-LM / llamadart backend ===');
      _append('Initializing LiteRT-LM:');
      _append('  model: $modelPath');
      _append('  backend: $_backend');
      _append('  speculative: ignored by backend API');
      if (_cacheDir.isNotEmpty) {
        await Directory(_cacheDir).create(recursive: true);
        _append('  cache override ignored by backend API: $_cacheDir');
      }

      final loadSw = Stopwatch()..start();
      await engine.loadModel(
        modelPath,
        modelParams: ModelParams(
          contextSize: _maxTokens,
          preferredBackend: _backend == 'cpu'
              ? GpuBackend.cpu
              : Platform.isMacOS
              ? GpuBackend.metal
              : GpuBackend.vulkan,
        ),
      );
      loadSw.stop();
      _append(
        'Initialized. Running $_warmups warmup(s), $_runs measured run(s).',
      );

      for (var i = 0; i < _warmups; i++) {
        await engine
            .generate(
              _promptController.text,
              params: GenerationParams(maxTokens: _outputTokens, seed: 1),
            )
            .drain<void>();
      }

      var lastText = '';
      BackendPerfContextData? perf;
      var wallMs = 0;
      for (var i = 0; i < _runs; i++) {
        final buffer = StringBuffer();
        final sw = Stopwatch()..start();
        await for (final chunk in engine.generate(
          _promptController.text,
          params: GenerationParams(maxTokens: _outputTokens, seed: 1),
        )) {
          buffer.write(chunk);
        }
        sw.stop();
        wallMs = sw.elapsedMilliseconds;
        lastText = buffer.toString();
        perf = await engine.getPerformanceContext();
      }

      final metrics = {
        'loadMilliseconds': loadSw.elapsedMilliseconds,
        'wallMilliseconds': wallMs,
        'backendName': await engine.getBackendName(),
        'targetDecodeTokens': _outputTokens,
        'backendInitMilliseconds': perf?.loadMs,
        'promptEvalTokens': perf?.promptEvalTokens,
        'evalTokens': perf?.evalTokens,
        'promptEvalMs': perf?.promptEvalMs,
        'evalMs': perf?.evalMs,
        'sampleMs': perf?.sampleMs,
        'prefillTokensPerSecond': perf == null || perf.promptEvalMs <= 0
            ? null
            : perf.promptEvalTokens / (perf.promptEvalMs / 1000.0),
        'decodeTokensPerSecond': perf == null || perf.evalMs <= 0
            ? null
            : perf.evalTokens / (perf.evalMs / 1000.0),
        'wallTokensPerSecond': wallMs <= 0 || perf == null
            ? null
            : perf.evalTokens / (wallMs / 1000.0),
      };
      const encoder = JsonEncoder.withIndent('  ');
      _append('RESULT litert_lm ${jsonEncode(metrics)}');
      _append(encoder.convert(metrics));
      _append('Last LiteRT-LM response:');
      _append(lastText);
    } finally {
      await engine.dispose();
    }
  }

  Future<void> _runLlamaDartBenchmark(String modelPath) async {
    final engine = LlamaEngine(LlamaBackend());
    try {
      _append('');
      _append('=== llamadart / llama.cpp ===');
      _append('Initializing llamadart:');
      _append('  model: $modelPath');
      _append('  backend: Vulkan');
      final loadSw = Stopwatch()..start();
      await engine.loadModel(
        modelPath,
        modelParams: ModelParams(
          contextSize: _maxTokens,
          gpuLayers: ModelParams.maxGpuLayers,
          preferredBackend: GpuBackend.vulkan,
        ),
      );
      loadSw.stop();
      _append('Initialized in ${loadSw.elapsedMilliseconds}ms.');
      final backendName = await engine.getBackendName();
      final resolvedGpuLayers = await engine.getResolvedGpuLayers();
      _append('Resolved backend: $backendName');
      _append('Resolved GPU layers: ${resolvedGpuLayers ?? 'unknown'}');

      for (var i = 0; i < _warmups; i++) {
        await engine
            .generate(
              _promptController.text,
              params: GenerationParams(maxTokens: _outputTokens, seed: 1),
            )
            .drain<void>();
      }

      var lastText = '';
      BackendPerfContextData? perf;
      var wallMs = 0;
      for (var i = 0; i < _runs; i++) {
        final buffer = StringBuffer();
        final sw = Stopwatch()..start();
        await for (final chunk in engine.generate(
          _promptController.text,
          params: GenerationParams(maxTokens: _outputTokens, seed: 1),
        )) {
          buffer.write(chunk);
        }
        sw.stop();
        wallMs = sw.elapsedMilliseconds;
        lastText = buffer.toString();
        perf = await engine.getPerformanceContext();
      }

      final metrics = {
        'loadMilliseconds': loadSw.elapsedMilliseconds,
        'wallMilliseconds': wallMs,
        'backendName': backendName,
        'resolvedGpuLayers': resolvedGpuLayers,
        'promptEvalTokens': perf?.promptEvalTokens,
        'evalTokens': perf?.evalTokens,
        'promptEvalMs': perf?.promptEvalMs,
        'evalMs': perf?.evalMs,
        'sampleMs': perf?.sampleMs,
        'prefillTokensPerSecond': perf == null || perf.promptEvalMs <= 0
            ? null
            : perf.promptEvalTokens / (perf.promptEvalMs / 1000.0),
        'decodeTokensPerSecond': perf == null || perf.evalMs <= 0
            ? null
            : perf.evalTokens / (perf.evalMs / 1000.0),
      };
      const encoder = JsonEncoder.withIndent('  ');
      _append('RESULT llamadart ${jsonEncode(metrics)}');
      _append(encoder.convert(metrics));
      _append('Last llamadart response:');
      _append(lastText);
    } finally {
      await engine.dispose();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('LiteRT-LM Benchmark POC')),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                TextField(
                  controller: _modelPathController,
                  decoration: const InputDecoration(
                    labelText: 'LiteRT-LM model path (.litertlm)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _llamaModelPathController,
                  decoration: const InputDecoration(
                    labelText: 'llamadart model path (.gguf)',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _promptController,
                  minLines: 3,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    labelText: 'Prompt',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    DropdownButton<String>(
                      value: _backend,
                      items: const [
                        DropdownMenuItem(value: 'cpu', child: Text('CPU')),
                        DropdownMenuItem(value: 'gpu', child: Text('GPU')),
                        DropdownMenuItem(value: 'npu', child: Text('NPU')),
                      ],
                      onChanged: _running
                          ? null
                          : (value) =>
                                setState(() => _backend = value ?? _backend),
                    ),
                    FilterChip(
                      label: const Text('Speculative'),
                      selected: _speculative,
                      onSelected: _running
                          ? null
                          : (value) => setState(() => _speculative = value),
                    ),
                    _NumberField(
                      label: 'Max tokens',
                      value: _maxTokens,
                      enabled: !_running,
                      onChanged: (value) => _maxTokens = value,
                    ),
                    _NumberField(
                      label: 'Output',
                      value: _outputTokens,
                      enabled: !_running,
                      onChanged: (value) => _outputTokens = value,
                    ),
                    _NumberField(
                      label: 'Warmups',
                      value: _warmups,
                      enabled: !_running,
                      onChanged: (value) => _warmups = value,
                    ),
                    _NumberField(
                      label: 'Runs',
                      value: _runs,
                      enabled: !_running,
                      onChanged: (value) => _runs = value,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _running ? null : _runBenchmarks,
                    child: Text(_running ? 'Running...' : 'Run Benchmark'),
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.black26),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(12),
                      child: SelectableText(
                        _log.toString(),
                        style: const TextStyle(fontFamily: 'monospace'),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NumberField extends StatelessWidget {
  final String label;
  final int value;
  final bool enabled;
  final ValueChanged<int> onChanged;

  const _NumberField({
    required this.label,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 112,
      child: TextFormField(
        initialValue: '$value',
        enabled: enabled,
        keyboardType: TextInputType.number,
        decoration: InputDecoration(labelText: label),
        onChanged: (text) {
          final parsed = int.tryParse(text);
          if (parsed != null && parsed > 0) {
            onChanged(parsed);
          }
        },
      ),
    );
  }
}
