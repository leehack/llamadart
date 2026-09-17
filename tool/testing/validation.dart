#!/usr/bin/env dart

import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'validation/bundle.dart';
import 'validation/collect.dart';
import 'validation/process.dart';
import 'validation/remote.dart';

/// Builds portable bundles and explicitly dispatches/reconciles remote runs.
Future<void> main(List<String> arguments) async {
  try {
    if (arguments.isEmpty || arguments.first == '--help') {
      stdout.writeln(
        'llamadart validation\n'
        '  build --target desktop|android|web|ios|ios-inputs --out <new-directory> [--profile <id>]\n'
        '  local --profile <id> [--model <path>] [--out <new-directory>]\n'
        '  report --out <run-directory>\n'
        '  plan --target <remote-target> --config <local-json> --bundle <directory> --out <plan.json>\n'
        '  run --plan <plan.json>\n'
        '  status|collect|cleanup --run-id <id>\n'
        '  reconcile --run-id <id> --remote-id <matrix-or-numeric-instance-id>\n'
        'Remote commands require explicit account/project and current quota/credit evidence.',
      );
      return;
    }
    final command = arguments.first;
    final options = _options(arguments.skip(1).toList());
    final root = File.fromUri(Platform.script).parent.parent.parent.path;
    final package = p.join(root, 'packages', 'llamadart_validation');
    final runRoot = Directory(p.join(root, '.dart_tool', 'validation', 'runs'));
    final profile = options['profile'] ?? 'tiny-gguf-cpu';
    String required(String key) =>
        options[key] ?? (throw FormatException('--$key is required'));
    if (command == 'build') {
      final bundle = await buildValidationBundle(
        root,
        required('target'),
        required('out'),
        profile: profile,
        team: options['team'],
      );
      stdout.writeln('Bundle: ${bundle.path}');
    } else if (command == 'local' || command == 'report') {
      final localOutput = p.absolute(
        options['out'] ??
            p.join(
              runRoot.path,
              'local-${DateTime.now().microsecondsSinceEpoch}',
            ),
      );
      Directory? provenanceDirectory;
      if (command == 'local') {
        final provenance = await readValidationProvenance(root);
        provenanceDirectory = Directory.systemTemp.createTempSync(
          'llamadart-provenance-',
        );
        File(
          p.join(provenanceDirectory.path, 'environment.json'),
        ).writeAsStringSync(jsonEncode(provenance));
      }
      late CommandResult result;
      try {
        result = await executeCommand(
          Platform.resolvedExecutable,
          [
            'run',
            command == 'local' ? 'bin/run.dart' : 'bin/report.dart',
            if (command == 'local') ...[
              '--profile',
              profile,
              '--environment-file',
              p.join(provenanceDirectory!.path, 'environment.json'),
              if (options['model'] != null) ...[
                '--model',
                p.absolute(options['model']!),
              ],
              '--out',
              localOutput,
              '--cache',
              p.join(root, '.dart_tool', 'validation', 'model-cache'),
            ] else
              p.absolute(required('out')),
          ],
          directory: package,
          timeout: const Duration(minutes: 20),
        );
      } finally {
        provenanceDirectory?.deleteSync(recursive: true);
      }
      stdout.write(result.output);
      stderr.write(result.error);
      exitCode = result.code;
      if (command == 'local' && Directory(localOutput).existsSync()) {
        File(
          p.join(localOutput, 'stdout.log'),
        ).writeAsStringSync(result.output);
        final nativeLog = File(p.join(localOutput, 'stderr.log'))
          ..writeAsStringSync(result.error);
        final report = await executeCommand(Platform.resolvedExecutable, [
          'run',
          'bin/report.dart',
          localOutput,
          '--native-log',
          nativeLog.path,
        ], directory: package);
        if (result.code == 0 || result.code == 1) exitCode = report.code;
      }
    } else if (command == 'plan') {
      final config =
          jsonDecode(File(required('config')).readAsStringSync())
              as Map<String, dynamic>;
      final bundle = Directory(required('bundle')).absolute;
      final manifest = await verifyBundle(bundle);
      final json = <String, dynamic>{
        'schema_version': 1,
        'run_id': 'qa-${DateTime.now().toUtc().microsecondsSinceEpoch}',
        'target': required('target'),
        'profile': options['profile'] ?? manifest['profile'],
        'account': config['account'],
        'project': config['project'],
        'settings': config['settings'],
        'bundle': bundle.path,
        'bundle_sha256':
            (await sha256
                    .bind(
                      File(
                        p.join(bundle.path, 'bundle-manifest.json'),
                      ).openRead(),
                    )
                    .first)
                .toString(),
      };
      final plan = RemotePlan(json);
      plan.validateBudget(DateTime.now().toUtc());
      File(required('out')).writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(json),
        flush: true,
      );
      stdout.writeln(
        'Plan written; no remote resources created: ${required('out')}',
      );
    } else {
      final controller = RemoteController(
        runRoot,
        GcloudProvider(),
        assess: (plan, directory) => assessCollectedRun(root, plan, directory),
      );
      final interrupt = ProcessSignal.sigint.watch().listen(
        (_) => controller.cancel(),
      );
      StreamSubscription<ProcessSignal>? termination;
      if (!Platform.isWindows) {
        termination = ProcessSignal.sigterm.watch().listen(
          (_) => controller.cancel(),
        );
      }
      try {
        Map<String, dynamic> state;
        if (command == 'run') {
          final plan = RemotePlan(
            jsonDecode(File(required('plan')).readAsStringSync())
                as Map<String, dynamic>,
          );
          state = await controller.run(plan);
        } else if ([
          'status',
          'collect',
          'cleanup',
          'reconcile',
        ].contains(command)) {
          final id = required('run-id');
          if (!RegExp(r'^qa-[a-z0-9-]+$').hasMatch(id)) {
            throw const FormatException('Invalid run ID');
          }
          state = await controller.recover(
            id,
            command,
            remoteId: command == 'reconcile' ? required('remote-id') : null,
          );
        } else {
          throw FormatException('Unknown command: $command');
        }
        stdout.writeln(
          jsonEncode({
            'phase': state['phase'],
            'cleanup': state['cleanup'],
            'collection': state['collection'],
            'error': state['error'],
          }),
        );
        if (state['qualified'] != true) exitCode = 1;
      } finally {
        await interrupt.cancel();
        await termination?.cancel();
      }
    }
  } catch (error) {
    stderr.writeln('Validation command failed: $error');
    exitCode = 1;
  }
}

Map<String, String> _options(List<String> args) {
  const allowed = {
    'team',
    'target',
    'out',
    'profile',
    'model',
    'config',
    'bundle',
    'plan',
    'run-id',
    'remote-id',
  };
  final options = <String, String>{};
  for (var i = 0; i < args.length; i += 2) {
    if (!args[i].startsWith('--') ||
        i + 1 >= args.length ||
        args[i + 1].startsWith('--')) {
      throw const FormatException('Options require --name value');
    }
    final key = args[i].substring(2);
    if (!allowed.contains(key) || options.containsKey(key)) {
      throw FormatException('Unknown/duplicate option: $key');
    }
    options[key] = args[i + 1];
  }
  return options;
}
