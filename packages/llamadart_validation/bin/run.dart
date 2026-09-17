import 'dart:convert';
import 'dart:io';

import 'package:llamadart_validation/io.dart';
import 'package:llamadart_validation/llamadart_validation.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  try {
    final options = parseOptions(args, {
      'help',
      'list',
      'assets',
      'profile',
      'profile-file',
      'model',
      'cache',
      'out',
      'run-id',
      'environment-file',
    });
    final assets =
        options['assets'] ??
        p.join(File.fromUri(Platform.script).parent.parent.path, 'assets');
    if (options.containsKey('help')) {
      stdout.writeln(
        'llamadart-validate --profile <id> [--model <verified-file>] '
        '[--out <new-directory>] [--cache <directory>] [--assets <directory>]\n'
        '--list lists bundled profiles. --profile-file loads an explicit locked manifest.',
      );
      return;
    }
    if (options.containsKey('list')) {
      for (final file in Directory(
        p.join(assets, 'profiles'),
      ).listSync().whereType<File>()) {
        if (file.path.endsWith('.json')) {
          stdout.writeln(p.basenameWithoutExtension(file.path));
        }
      }
      return;
    }
    final profileId = options['profile'] ?? 'tiny-gguf-cpu';
    if (!RegExp(r'^[a-z][a-z0-9-]{0,63}$').hasMatch(profileId)) {
      throw const FormatException('Invalid profile id');
    }
    final profile = ValidationProfile.fromJson(
      jsonDecode(
            File(
              options['profile-file'] ??
                  p.join(assets, 'profiles', '$profileId.json'),
            ).readAsStringSync(),
          )
          as Map<String, dynamic>,
    );
    final runId =
        options['run-id'] ??
        'local-${DateTime.now().toUtc().microsecondsSinceEpoch}';
    final directory = Directory(
      options['out'] ?? p.join('.dart_tool', 'validation', 'runs', runId),
    );
    final journal = FileValidationJournal(directory);
    try {
      final prepared = await prepareModel(
        profile,
        Directory(
          options['cache'] ?? p.join('.dart_tool', 'validation', 'model-cache'),
        ),
        suppliedPath: options['model'],
      );
      final bundledEnvironment = File(
        p.join(
          File(Platform.resolvedExecutable).parent.parent.path,
          'environment.json',
        ),
      );
      final environmentPath =
          options['environment-file'] ??
          (bundledEnvironment.existsSync() ? bundledEnvironment.path : null);
      final environment = <String, dynamic>{
        if (environmentPath != null)
          ...jsonDecode(File(environmentPath).readAsStringSync())
              as Map<String, dynamic>,
        'os': Platform.operatingSystem,
        'os_version': Platform.operatingSystemVersion,
        'processors': Platform.numberOfProcessors,
        'dart': Platform.version,
        'build_mode': const bool.fromEnvironment('dart.vm.product')
            ? 'release'
            : 'jit',
      };
      final runner = ValidationRunner(
        profile: profile,
        engine: PublicValidationEngine(),
        emit: journal.emit,
      );
      final interrupt = ProcessSignal.sigint.watch().listen(
        (_) => runner.cancel(),
      );
      try {
        await runner.run(
          prepared.path,
          runId: runId,
          environment: environment,
          preparation: prepared.evidence,
        );
      } finally {
        await interrupt.cancel();
      }
    } catch (error) {
      await journal.emit({
        'type': 'preparation_error',
        'message': redactDiagnostic('$error'),
      });
      rethrow;
    } finally {
      journal.close();
      final report = writeReports(directory);
      stdout.writeln(
        'REPORT ${p.join(directory.absolute.path, 'summary.html')}',
      );
      if (!report.qualified) exitCode = 1;
    }
  } catch (error) {
    stderr.writeln(redactDiagnostic('$error'));
    exitCode = 1;
  }
}
