import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:llamadart/llamadart.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

const _defaultPrompt =
    'Write a concise explanation of why on-device language models are useful.';
const _llamaCppBenchmarkBackendNames = <String>{
  'auto',
  'cpu',
  'vulkan',
  'metal',
  'cuda',
  'opencl',
  'hip',
  'blas',
};
const _liteRtLmBenchmarkBackendNames = <String>{'auto', 'cpu', 'gpu', 'npu'};

String resolveLiteRtLmBenchmarkBackendName(
  String backend, {
  String? operatingSystem,
}) {
  final normalized = backend.trim().toLowerCase();
  if (normalized.isEmpty || normalized == 'auto') {
    return switch (operatingSystem ?? Platform.operatingSystem) {
      'ios' => 'cpu',
      _ => 'gpu',
    };
  }
  if (_liteRtLmBenchmarkBackendNames.contains(normalized)) {
    return normalized;
  }
  throw ArgumentError.value(
    backend,
    'LITERT_LM_BACKEND',
    'Expected auto, cpu, gpu, or npu.',
  );
}

String normalizeLlamaCppBenchmarkBackendName(String backend) {
  final normalized = backend.trim().toLowerCase();
  if (_llamaCppBenchmarkBackendNames.contains(normalized)) {
    return normalized;
  }
  return 'auto';
}

GpuBackend resolveLlamaCppBenchmarkBackend(
  String backend, {
  String? operatingSystem,
}) {
  final normalized = backend.trim().toLowerCase();
  return switch (normalized) {
    '' || 'auto' => _defaultLlamaCppBenchmarkBackend(
      operatingSystem: operatingSystem,
    ),
    'cpu' => GpuBackend.cpu,
    'vulkan' => GpuBackend.vulkan,
    'metal' => GpuBackend.metal,
    'cuda' => GpuBackend.cuda,
    'opencl' => GpuBackend.opencl,
    'hip' => GpuBackend.hip,
    'blas' => GpuBackend.blas,
    _ => throw ArgumentError.value(
      backend,
      'LLAMADART_BACKEND',
      'Expected auto, cpu, vulkan, metal, cuda, opencl, hip, or blas.',
    ),
  };
}

GpuBackend _defaultLlamaCppBenchmarkBackend({String? operatingSystem}) {
  final os = operatingSystem ?? Platform.operatingSystem;
  return switch (os) {
    'macos' || 'ios' => GpuBackend.metal,
    'android' || 'linux' || 'windows' => GpuBackend.vulkan,
    _ => GpuBackend.auto,
  };
}

String llamaCppBenchmarkBackendLabel(GpuBackend backend) {
  return switch (backend) {
    GpuBackend.auto => 'Auto',
    GpuBackend.cpu => 'CPU',
    GpuBackend.vulkan => 'Vulkan',
    GpuBackend.metal => 'Metal',
    GpuBackend.cuda => 'CUDA',
    GpuBackend.opencl => 'OpenCL',
    GpuBackend.hip => 'HIP',
    GpuBackend.blas => 'BLAS',
  };
}

String resolveBenchmarkModelPath(
  String value, {
  String? homeDirectory,
  bool? useDocumentsForRelative,
}) {
  final trimmed = value.trim();
  if (trimmed.isEmpty || path.isAbsolute(trimmed)) {
    return trimmed;
  }

  const documentsPrefix = 'documents:';
  final hasDocumentsPrefix = trimmed.startsWith(documentsPrefix);
  final shouldUseDocuments =
      hasDocumentsPrefix || (useDocumentsForRelative ?? Platform.isIOS);
  if (!shouldUseDocuments) {
    return trimmed;
  }

  final fileName = hasDocumentsPrefix
      ? trimmed.substring(documentsPrefix.length).trim()
      : trimmed;
  if (fileName.isEmpty || path.isAbsolute(fileName)) {
    return fileName;
  }

  final home = homeDirectory ?? Platform.environment['HOME'];
  if (home == null || home.isEmpty) {
    return fileName;
  }
  return path.join(home, 'Documents', fileName);
}

Future<String> resolveBenchmarkModelPathForApp(String value) async {
  final trimmed = value.trim();
  if (trimmed.isEmpty || path.isAbsolute(trimmed)) {
    return trimmed;
  }

  const documentsPrefix = 'documents:';
  final hasDocumentsPrefix = trimmed.startsWith(documentsPrefix);
  final shouldUseDocuments = hasDocumentsPrefix || Platform.isIOS;
  if (!shouldUseDocuments) {
    return trimmed;
  }

  final fileName = hasDocumentsPrefix
      ? trimmed.substring(documentsPrefix.length).trim()
      : trimmed;
  if (fileName.isEmpty || path.isAbsolute(fileName)) {
    return fileName;
  }

  final documentsDir = await getApplicationDocumentsDirectory();
  return path.join(documentsDir.path, fileName);
}

Map<String, Object?> _numericSummary(
  List<Map<String, Object?>> runs,
  String key,
) {
  final values =
      runs
          .map((run) => run[key])
          .whereType<num>()
          .where((value) => value.isFinite)
          .map((value) => value.toDouble())
          .toList()
        ..sort();
  if (values.isEmpty) {
    return {'median': null, 'min': null, 'max': null};
  }

  final middle = values.length ~/ 2;
  final median = values.length.isOdd
      ? values[middle]
      : (values[middle - 1] + values[middle]) / 2.0;
  return {'median': median, 'min': values.first, 'max': values.last};
}

Map<String, Object?> _summarizeRuns(List<Map<String, Object?>> runs) {
  return {
    'wallTokensPerSecond': _numericSummary(runs, 'wallTokensPerSecond'),
    'decodeTokensPerSecond': _numericSummary(runs, 'decodeTokensPerSecond'),
    'decodeWithSamplingTokensPerSecond': _numericSummary(
      runs,
      'decodeWithSamplingTokensPerSecond',
    ),
    'wallMilliseconds': _numericSummary(runs, 'wallMilliseconds'),
    'evalTokens': _numericSummary(runs, 'evalTokens'),
  };
}

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
  String _backend = resolveLiteRtLmBenchmarkBackendName(
    const String.fromEnvironment('LITERT_LM_BACKEND', defaultValue: 'auto'),
  );
  String _llamaBackend = normalizeLlamaCppBenchmarkBackendName(
    const String.fromEnvironment('LLAMADART_BACKEND', defaultValue: 'auto'),
  );
  bool _speculative = const bool.fromEnvironment(
    'LITERT_LM_SPECULATIVE',
    defaultValue: false,
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
    final modelPath = await resolveBenchmarkModelPathForApp(
      _modelPathController.text,
    );
    final llamaModelPath = await resolveBenchmarkModelPathForApp(
      _llamaModelPathController.text,
    );
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
      _append('  speculative: $_speculative');
      if (_cacheDir.isNotEmpty) {
        await Directory(_cacheDir).create(recursive: true);
        _append('  cache override ignored by backend API: $_cacheDir');
      }

      final loadSw = Stopwatch()..start();
      await engine.loadModel(
        modelPath,
        modelParams: ModelParams(
          contextSize: _maxTokens,
          preferredBackend: _preferredGpuBackendForLiteRt(_backend),
          liteRtLmBackend: _liteRtLmBackendPreference(_backend),
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
              params: GenerationParams(
                maxTokens: _outputTokens,
                seed: 1,
                speculativeDecoding: _speculative,
              ),
            )
            .drain<void>();
      }

      var lastText = '';
      BackendPerfContextData? perf;
      var wallMs = 0;
      final runsDetail = <Map<String, Object?>>[];
      for (var i = 0; i < _runs; i++) {
        final buffer = StringBuffer();
        final sw = Stopwatch()..start();
        await for (final chunk in engine.generate(
          _promptController.text,
          params: GenerationParams(
            maxTokens: _outputTokens,
            seed: 1,
            speculativeDecoding: _speculative,
          ),
        )) {
          buffer.write(chunk);
        }
        sw.stop();
        wallMs = sw.elapsedMilliseconds;
        lastText = buffer.toString();
        perf = await engine.getPerformanceContext();
        final runMetrics = {
          'index': i,
          'wallMilliseconds': wallMs,
          'speculativeDecoding': _speculative,
          'promptEvalTokens': perf?.promptEvalTokens,
          'evalTokens': perf?.evalTokens,
          'hitEosBeforeTarget': perf == null
              ? null
              : perf.evalTokens < _outputTokens,
          'promptEvalMs': perf?.promptEvalMs,
          'evalMs': perf?.evalMs,
          'sampleMs': perf?.sampleMs,
          'prefillTokensPerSecond': perf == null || perf.promptEvalMs <= 0
              ? null
              : perf.promptEvalTokens / (perf.promptEvalMs / 1000.0),
          'decodeTokensPerSecond': perf == null || perf.evalMs <= 0
              ? null
              : perf.evalTokens / (perf.evalMs / 1000.0),
          'decodeWithSamplingTokensPerSecond':
              perf == null || perf.evalMs + perf.sampleMs <= 0
              ? null
              : perf.evalTokens / ((perf.evalMs + perf.sampleMs) / 1000.0),
          'wallTokensPerSecond': wallMs <= 0 || perf == null
              ? null
              : perf.evalTokens / (wallMs / 1000.0),
        };
        runsDetail.add(runMetrics);
        _append('RUN litert_lm ${jsonEncode(runMetrics)}');
      }

      final metrics = {
        'loadMilliseconds': loadSw.elapsedMilliseconds,
        'wallMilliseconds': wallMs,
        'backendName': await engine.getBackendName(),
        'targetDecodeTokens': _outputTokens,
        'speculativeDecoding': _speculative,
        'backendInitMilliseconds': perf?.loadMs,
        'promptEvalTokens': perf?.promptEvalTokens,
        'evalTokens': perf?.evalTokens,
        'hitEosBeforeTarget': perf == null
            ? null
            : perf.evalTokens < _outputTokens,
        'promptEvalMs': perf?.promptEvalMs,
        'evalMs': perf?.evalMs,
        'sampleMs': perf?.sampleMs,
        'prefillTokensPerSecond': perf == null || perf.promptEvalMs <= 0
            ? null
            : perf.promptEvalTokens / (perf.promptEvalMs / 1000.0),
        'decodeTokensPerSecond': perf == null || perf.evalMs <= 0
            ? null
            : perf.evalTokens / (perf.evalMs / 1000.0),
        'decodeWithSamplingTokensPerSecond':
            perf == null || perf.evalMs + perf.sampleMs <= 0
            ? null
            : perf.evalTokens / ((perf.evalMs + perf.sampleMs) / 1000.0),
        'wallTokensPerSecond': wallMs <= 0 || perf == null
            ? null
            : perf.evalTokens / (wallMs / 1000.0),
        'runs': _runs,
        'warmups': _warmups,
        'measured': _summarizeRuns(runsDetail),
        'runsDetail': runsDetail,
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

  GpuBackend _preferredGpuBackendForLiteRt(String backend) {
    return switch (backend) {
      'cpu' => GpuBackend.cpu,
      'gpu' => Platform.isMacOS ? GpuBackend.metal : GpuBackend.vulkan,
      _ => GpuBackend.auto,
    };
  }

  LiteRtLmBackendPreference _liteRtLmBackendPreference(String backend) {
    return switch (backend) {
      'cpu' => LiteRtLmBackendPreference.cpu,
      'gpu' => LiteRtLmBackendPreference.gpu,
      'npu' => LiteRtLmBackendPreference.npu,
      _ => LiteRtLmBackendPreference.auto,
    };
  }

  Future<void> _runLlamaDartBenchmark(String modelPath) async {
    final engine = LlamaEngine(LlamaBackend());
    try {
      final backendPreference = resolveLlamaCppBenchmarkBackend(_llamaBackend);
      _append('');
      _append('=== llamadart / llama.cpp ===');
      _append('Initializing llamadart:');
      _append('  model: $modelPath');
      _append('  backend: ${llamaCppBenchmarkBackendLabel(backendPreference)}');
      final loadSw = Stopwatch()..start();
      await engine.loadModel(
        modelPath,
        modelParams: ModelParams(
          contextSize: _maxTokens,
          gpuLayers: ModelParams.maxGpuLayers,
          preferredBackend: backendPreference,
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
      final runsDetail = <Map<String, Object?>>[];
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
        final runMetrics = {
          'index': i,
          'wallMilliseconds': wallMs,
          'promptEvalTokens': perf?.promptEvalTokens,
          'evalTokens': perf?.evalTokens,
          'hitEosBeforeTarget': perf == null
              ? null
              : perf.evalTokens < _outputTokens,
          'promptEvalMs': perf?.promptEvalMs,
          'evalMs': perf?.evalMs,
          'sampleMs': perf?.sampleMs,
          'prefillTokensPerSecond': perf == null || perf.promptEvalMs <= 0
              ? null
              : perf.promptEvalTokens / (perf.promptEvalMs / 1000.0),
          'decodeTokensPerSecond': perf == null || perf.evalMs <= 0
              ? null
              : perf.evalTokens / (perf.evalMs / 1000.0),
          'decodeWithSamplingTokensPerSecond':
              perf == null || perf.evalMs + perf.sampleMs <= 0
              ? null
              : perf.evalTokens / ((perf.evalMs + perf.sampleMs) / 1000.0),
          'wallTokensPerSecond': wallMs <= 0 || perf == null
              ? null
              : perf.evalTokens / (wallMs / 1000.0),
        };
        runsDetail.add(runMetrics);
        _append('RUN llamadart ${jsonEncode(runMetrics)}');
      }

      final metrics = {
        'loadMilliseconds': loadSw.elapsedMilliseconds,
        'wallMilliseconds': wallMs,
        'requestedBackend': backendPreference.name,
        'backendName': backendName,
        'resolvedGpuLayers': resolvedGpuLayers,
        'targetDecodeTokens': _outputTokens,
        'promptEvalTokens': perf?.promptEvalTokens,
        'evalTokens': perf?.evalTokens,
        'hitEosBeforeTarget': perf == null
            ? null
            : perf.evalTokens < _outputTokens,
        'promptEvalMs': perf?.promptEvalMs,
        'evalMs': perf?.evalMs,
        'sampleMs': perf?.sampleMs,
        'prefillTokensPerSecond': perf == null || perf.promptEvalMs <= 0
            ? null
            : perf.promptEvalTokens / (perf.promptEvalMs / 1000.0),
        'decodeTokensPerSecond': perf == null || perf.evalMs <= 0
            ? null
            : perf.evalTokens / (perf.evalMs / 1000.0),
        'decodeWithSamplingTokensPerSecond':
            perf == null || perf.evalMs + perf.sampleMs <= 0
            ? null
            : perf.evalTokens / ((perf.evalMs + perf.sampleMs) / 1000.0),
        'wallTokensPerSecond': wallMs <= 0 || perf == null
            ? null
            : perf.evalTokens / (wallMs / 1000.0),
        'runs': _runs,
        'warmups': _warmups,
        'measured': _summarizeRuns(runsDetail),
        'runsDetail': runsDetail,
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
        appBar: AppBar(title: const Text('LiteRT-LM Benchmark')),
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
                    DropdownButton<String>(
                      value: _llamaBackend,
                      items: const [
                        DropdownMenuItem(
                          value: 'auto',
                          child: Text('llama.cpp auto'),
                        ),
                        DropdownMenuItem(
                          value: 'cpu',
                          child: Text('llama.cpp CPU'),
                        ),
                        DropdownMenuItem(
                          value: 'vulkan',
                          child: Text('llama.cpp Vulkan'),
                        ),
                        DropdownMenuItem(
                          value: 'metal',
                          child: Text('llama.cpp Metal'),
                        ),
                        DropdownMenuItem(
                          value: 'cuda',
                          child: Text('llama.cpp CUDA'),
                        ),
                        DropdownMenuItem(
                          value: 'opencl',
                          child: Text('llama.cpp OpenCL'),
                        ),
                        DropdownMenuItem(
                          value: 'hip',
                          child: Text('llama.cpp HIP'),
                        ),
                        DropdownMenuItem(
                          value: 'blas',
                          child: Text('llama.cpp BLAS'),
                        ),
                      ],
                      onChanged: _running
                          ? null
                          : (value) => setState(
                              () => _llamaBackend = value ?? _llamaBackend,
                            ),
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
