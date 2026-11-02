import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:llamadart/llamadart.dart';

import 'lfm2_schema_replay.dart';
import 'lfm2_recording_backend.dart';

/// Captures fresh generation from exact historical prompt/tool/sampling rows.
///
/// Usage: `dart run test/support/lfm2_schema_generation.dart manifest.json`
/// `output.json existing-model-directory python|absent [--dry-run]`.
/// Select CPU (default) or existing Metal with LLAMADART_LFM_GENERATION_BACKEND.
Future<void> main(List<String> arguments) async {
  if (arguments.length < 4 || !['python', 'absent'].contains(arguments[3])) {
    stderr.writeln(
      'Expected manifest, output, existing model directory and '
      'python|absent auto-grammar contract. Optional: --dry-run.',
    );
    exitCode = 64;
    return;
  }
  final rows = (jsonDecode(File(arguments[0]).readAsStringSync()) as List)
      .cast<Map<String, dynamic>>();
  final ids = <String>{};
  final toolsById = <String, List<ToolDefinition>>{};
  for (final row in rows) {
    final id = '${row['set']}/${row['key']}';
    if (!ids.add(id)) throw StateError('Duplicate capture identity.');
    final sampling = row['sampling'] as Map;
    for (final field in [
      'maxTokens',
      'temp',
      'seed',
      'topK',
      'topP',
      'minP',
      'penalty',
    ]) {
      if (!sampling.containsKey(field)) {
        throw StateError('Incomplete sampling metadata.');
      }
    }
    if (['maxTokens', 'topK'].any((field) => sampling[field] is! int) ||
        sampling['seed'] != null && sampling['seed'] is! int ||
        ['temp', 'topP', 'minP', 'penalty'].any(
          (field) =>
              sampling[field] is! num || !(sampling[field] as num).isFinite,
        ) ||
        row['parallel'] is! bool ||
        row['thinking'] is! bool) {
      throw StateError('Invalid original sampling or request metadata.');
    }
    final model = File('${arguments[2]}/${row['model']}');
    if (!model.existsSync()) {
      throw StateError('Required cached model is unavailable.');
    }
    toolsById[id] = [
      for (final encoded in row['tools'] as List) _tool(encoded as Map),
    ];
  }
  if (arguments.contains('--dry-run')) {
    stdout.writeln(
      jsonEncode({
        'rows': rows.length,
        'models': rows.map((r) => r['model']).toSet().length,
        'tools_and_sampling': 'validated',
        'auto_grammar_contract': arguments[3],
      }),
    );
    return;
  }
  final useMetal =
      Platform.environment['LLAMADART_LFM_GENERATION_BACKEND'] == 'metal';
  final output = File(arguments[1]);
  final captures = <Map<String, dynamic>>[];
  for (final model in rows.map((row) => row['model'] as String).toSet()) {
    final file = File('${arguments[2]}/$model');
    final hash = (await sha256.bind(file.openRead()).first).toString();
    final recorder = Lfm2RecordingBackend();
    final engine = LlamaEngine(recorder);
    try {
      await engine.loadModel(
        file.path,
        modelParams: ModelParams(
          contextSize: 4096,
          gpuLayers: useMetal ? ModelParams.maxGpuLayers : 0,
          preferredBackend: useMetal ? GpuBackend.metal : GpuBackend.cpu,
          device: useMetal ? ComputeDevice.gpu : ComputeDevice.cpu,
          numberOfThreads: 2,
          numberOfThreadsBatch: 2,
        ),
      );
      final backend = await engine.getBackendName();
      if (useMetal && !backend.toLowerCase().contains('metal')) {
        throw StateError('Explicit Metal generation did not use Metal.');
      }
      for (final row in rows.where((row) => row['model'] == model)) {
        final id = '${row['set']}/${row['key']}';
        final tools = toolsById[id]!;
        final rendered = await engine.chatTemplate(
          [
            LlamaChatMessage.fromText(
              role: LlamaChatRole.system,
              text: row['system'] as String,
            ),
            LlamaChatMessage.fromText(
              role: LlamaChatRole.user,
              text: row['prompt'] as String,
            ),
          ],
          tools: tools,
          toolChoice: ToolChoice.values.byName(row['choice'] as String),
          parallelToolCalls: row['parallel'] as bool,
          enableThinking: row['thinking'] as bool,
        );
        final plainLfmAuto =
            rendered.format == ChatFormat.lfm2.index &&
            row['choice'] == 'auto' &&
            !(row['system'] as String).toLowerCase().contains(
              'force json schema.',
            );
        if (plainLfmAuto) {
          final expected = arguments[3] == 'python';
          if (expected != rendered.grammarLazy ||
              expected != (rendered.grammar != null) ||
              expected != rendered.grammarTriggers.isNotEmpty) {
            throw StateError(
              'Rendered auto grammar does not match the declared capture contract.',
            );
          }
          if (expected && !(await engine.capabilities).supportsLazyGrammar) {
            throw StateError(
              'Runtime does not admit lazy grammar qualification.',
            );
          }
        }
        final sampling = row['sampling'] as Map;
        final params = GenerationParams(
          maxTokens: sampling['maxTokens'] as int,
          temp: (sampling['temp'] as num).toDouble(),
          seed: sampling['seed'] as int?,
          topK: sampling['topK'] as int,
          topP: (sampling['topP'] as num).toDouble(),
          minP: (sampling['minP'] as num).toDouble(),
          penalty: (sampling['penalty'] as num).toDouble(),
        );
        recorder.resetCapture();
        final watch = Stopwatch()..start();
        Object? completionError;
        try {
          await engine
              .create(
                [
                  LlamaChatMessage.fromText(
                    role: LlamaChatRole.system,
                    text: row['system'] as String,
                  ),
                  LlamaChatMessage.fromText(
                    role: LlamaChatRole.user,
                    text: row['prompt'] as String,
                  ),
                ],
                params: params,
                tools: tools,
                toolChoice: ToolChoice.values.byName(row['choice'] as String),
                parallelToolCalls: row['parallel'] as bool,
                enableThinking: row['thinking'] as bool,
              )
              .drain<void>();
        } catch (error) {
          completionError = error;
        }
        final dispatched = recorder.lastParams;
        if (dispatched == null) {
          throw StateError(
            'Public completion did not dispatch: $completionError',
          );
        }
        if (dispatched.grammar != rendered.grammar ||
            dispatched.grammarLazy != rendered.grammarLazy ||
            jsonEncode(
                  dispatched.grammarTriggers
                      .map(
                        (trigger) => [
                          trigger.type,
                          trigger.value,
                          trigger.token,
                        ],
                      )
                      .toList(),
                ) !=
                jsonEncode(
                  rendered.grammarTriggers
                      .map(
                        (trigger) => [
                          trigger.type,
                          trigger.value,
                          trigger.token,
                        ],
                      )
                      .toList(),
                )) {
          throw StateError(
            'Public completion changed the expected rendered grammar state.',
          );
        }
        if (plainLfmAuto &&
            arguments[3] == 'python' &&
            !recorder.countedPromptPenalties) {
          throw StateError(
            'Public completion omitted required prompt penalties.',
          );
        }
        final raw = recorder.raw;
        final record = <String, dynamic>{
          ...row,
          'id': id,
          'raw': raw,
          'raw_sha256': sha256.convert(utf8.encode(raw)).toString(),
          'model_sha256': hash,
          'backend': backend,
          'generation_ms': watch.elapsedMilliseconds,
          'format': rendered.format,
          'thinking_forced_open': rendered.thinkingForcedOpen,
          'rendered_prompt': rendered.prompt,
          'grammar': dispatched.grammar,
          'grammar_lazy': dispatched.grammarLazy,
          'grammar_root': dispatched.grammarRoot,
          'grammar_triggers': [
            for (final trigger in dispatched.grammarTriggers)
              {
                'type': trigger.type,
                'value': trigger.value,
                'token': trigger.token,
              },
          ],
          'preserved_tokens': dispatched.preservedTokens,
          'stop_sequences': dispatched.stopSequences,
          'prompt_penalties_with_grammar': recorder.countedPromptPenalties,
          if (completionError != null)
            'completion_error': completionError.toString(),
          'provenance':
              'Fresh public engine.create generation from exact manifest; raw backend bytes retained before parsing.',
        };
        captures.add(record);
        _persist(output, captures, record);
        try {
          record['result'] = replayLfm2Capture(record);
        } catch (error) {
          record['error'] = {
            'type': error.runtimeType.toString(),
            'message': error.toString(),
          };
        }
        output.writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(captures),
        );
        stdout.writeln(
          jsonEncode({
            'id': id,
            'format': rendered.format,
            'grammar_lazy': dispatched.grammarLazy,
            'triggers': dispatched.grammarTriggers.length,
            'generation_ms': record['generation_ms'],
          }),
        );
      }
    } finally {
      await engine.dispose();
      output.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(captures),
      );
    }
  }
}

ToolDefinition _tool(Map encoded) {
  final function = Map<String, dynamic>.from(encoded['function'] as Map);
  final tool = lfm2CaptureTool({
    'tool': {
      'name': function['name'],
      'description': function['description'],
      'schema': function['parameters'],
      'origin': 'legacy_parameters',
    },
  });
  if (jsonEncode(tool.toJson()) != jsonEncode(encoded)) {
    throw StateError('Tool reconstruction changed the original declaration.');
  }
  return tool;
}

void _persist(
  File output,
  List<Map<String, dynamic>> captures,
  Map<String, dynamic> latest,
) {
  File(
    '${output.path}.jsonl',
  ).writeAsStringSync('${jsonEncode(latest)}\n', mode: FileMode.append);
  output.writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(captures),
  );
}
