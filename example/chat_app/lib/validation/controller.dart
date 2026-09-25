import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:llamadart_validation/llamadart_validation.dart';

import 'host.dart';

/// Coordinates the same suite for interactive and unattended Flutter runs.
class ValidationController extends ChangeNotifier {
  /// Allows host injection in widget tests.
  ValidationController({ValidationHost? host})
    : host = host ?? createValidationHost();

  /// Native/browser storage adapter.
  final ValidationHost host;

  /// Bounded current run progress.
  final List<Map<String, dynamic>> records = [];

  /// Whether a run is in progress.
  bool running = false;

  /// Current case or preparation phase.
  String phase = 'Ready';

  /// Complete or partial report.
  ValidationReport? report;

  /// Preparation/adapter failure description.
  String? error;
  ValidationRunner? _runner;
  bool _cancelled = false;
  bool _disposed = false;
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    cancel();
    super.dispose();
  }

  /// Cancels inference and prevents the next case from starting.
  void cancel() {
    _cancelled = true;
    host.cancelPreparation();
    _runner?.cancel();
  }

  /// Loads a checked-in profile and executes it once.
  Future<void> run(String profileId) async {
    if (running) throw StateError('A validation run is already active');
    if (!RegExp(r'^[a-z][a-z0-9-]{0,63}$').hasMatch(profileId)) {
      throw const FormatException('Invalid profile id');
    }
    _cancelled = false;
    running = true;
    phase = 'Preparing model';
    error = null;
    report = null;
    records.clear();
    _notify();
    var started = false;
    try {
      final source = await rootBundle.loadString(
        'packages/llamadart_validation/assets/profiles/$profileId.json',
      );
      final data = jsonDecode(source) as Map<String, dynamic>;
      data['execution_path'] = const String.fromEnvironment(
        'VALIDATION_EXECUTION_PATH',
        defaultValue: 'public_api',
      );
      final profile = ValidationProfile.fromJson(data);
      if (_cancelled) {
        throw StateError('Run cancelled before model preparation');
      }
      final runId = 'app-${DateTime.now().toUtc().microsecondsSinceEpoch}';
      await host.start(runId);
      started = true;
      if (_cancelled) {
        throw StateError('Run cancelled before model preparation');
      }
      final model = await host.prepare(profile);
      if (_cancelled) throw StateError('Run cancelled during preparation');
      final decisionReference = profile.isDecision
          ? await rootBundle.loadString(
              'packages/llamadart_validation/'
              '${profile.fixtureText('decision', 'reference')}',
            )
          : null;
      _runner = ValidationRunner(
        profile: profile,
        engine: host.createEngine(profile),
        decisionReference: decisionReference,
        emit: (event) async {
          await host.emit(event);
          if (event['type'] == 'case' || event['type'] == 'case_start') {
            phase = '${event['case_id']} ${event['status'] ?? 'running'}';
            if (event['type'] == 'case') records.add(event);
            _notify();
          }
        },
      );
      await _runner!.run(
        model.path,
        runId: runId,
        preparation: model.evidence,
        environment: {
          'platform': defaultTargetPlatform.name,
          'web': kIsWeb,
          'build_mode': kReleaseMode
              ? 'release'
              : kProfileMode
              ? 'profile'
              : 'debug',
          'source_commit': const String.fromEnvironment(
            'VALIDATION_COMMIT',
            defaultValue: 'unknown',
          ),
          'source_dirty': const bool.fromEnvironment(
            'VALIDATION_SOURCE_DIRTY',
            defaultValue: true,
          ),
          'hook_sha256': const String.fromEnvironment(
            'VALIDATION_HOOK_SHA256',
            defaultValue: 'unknown',
          ),
          'bridge_tag': const String.fromEnvironment(
            'VALIDATION_BRIDGE_TAG',
            defaultValue: 'unknown',
          ),
          'native_tag': const String.fromEnvironment(
            'VALIDATION_NATIVE_TAG',
            defaultValue: 'unknown',
          ),
          'litert_tag': const String.fromEnvironment(
            'VALIDATION_LITERT_TAG',
            defaultValue: 'unknown',
          ),
        },
      );
    } catch (exception) {
      error = redactDiagnostic('$exception');
      if (started) {
        await host.emit({'type': 'preparation_error', 'message': error});
      }
    } finally {
      try {
        if (started) report = await host.finish();
      } catch (exception) {
        error = redactDiagnostic('Report persistence failed: $exception');
      }
      running = false;
      _runner = null;
      phase = error != null
          ? 'Error'
          : report?.qualified == true
          ? 'Qualified'
          : 'Incomplete / failed';
      _notify();
    }
  }
}
