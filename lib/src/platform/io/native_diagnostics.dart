import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:path/path.dart' as path;

/// Internal CLI runtime identifiers; this is not an engine capability API.
const nativeDiagnosticRuntimes = {'llama_cpp', 'litert_lm', 'stable_diffusion'};

const _codes = {
  'SURFACE_OBSERVED',
  'PROBE_HOST_UNAVAILABLE',
  'ASSET_DECLARATION_UNAVAILABLE',
  'ASSET_DECLARATION_INVALID',
  'ASSET_NOT_DECLARED',
  'ARTIFACT_MISSING',
  'DEPENDENCY_UNAVAILABLE',
  'BINARY_INCOMPATIBLE',
  'LOADER_FAILED',
  'SYMBOL_MISSING',
  'ABI_UNKNOWN',
  'CHILD_FAILED',
  'CHILD_PROTOCOL_INVALID',
  'PROBE_TIMEOUT',
  'TERMINATION_UNCONFIRMED',
};
const _phases = {
  'not_started',
  'declaration',
  'open',
  'symbols',
  'abi',
  'complete',
};
const _markers = {
  'not_checked',
  'not_available',
  'tts_v1',
  'callback_v2_finish_v1',
  'unknown',
};

/// Constructs only fixed, privacy-safe observation fields.
Map<String, Object> nativeDiagnosticObservation(
  String runtime,
  String code, {
  String phase = 'not_started',
  String marker = 'not_checked',
}) {
  if (!nativeDiagnosticRuntimes.contains(runtime) ||
      !_codes.contains(code) ||
      !_phases.contains(phase) ||
      !_markers.contains(marker)) {
    throw const FormatException('Invalid native diagnostic observation');
  }
  return Map.unmodifiable({
    'runtime': runtime,
    'code': code,
    'phase': phase,
    'abi_marker': marker,
    'target_source': 'local_manifest_declaration',
    'loader_strategy': 'direct_declared_files',
    'loaded_release': 'unknown',
    'emitted_app_libraries': 'not_checked',
    'production_loader': 'not_checked',
    'selected_backend': 'unknown',
    'selected_gpu': 'unknown',
    'gpu_usability': 'not_checked',
    'model_capabilities': 'not_checked',
    'inference': 'not_checked',
    'remediation': switch (code) {
      'SURFACE_OBSERVED' =>
        'Only the declared files and checked symbols/markers were observed; validate the intended app/model/backend separately.',
      'ASSET_NOT_DECLARED' =>
        'The local manifest does not declare this runtime. Check the intended build runtime selection and rebuild; publication policy and overrides can differ.',
      'ARTIFACT_MISSING' =>
        'A declared file is unavailable. Regenerate the intended build assets; do not infer runtime publication from this observation.',
      'BINARY_INCOMPATIBLE' =>
        'Check that the declared artifact matches the process OS and ABI, and verify custom overrides.',
      'DEPENDENCY_UNAVAILABLE' =>
        'A dependency or loader search path may be unavailable. Check the runtime packaging and documented OS dependencies.',
      'SYMBOL_MISSING' || 'ABI_UNKNOWN' =>
        'The checked interface is missing or unrecognized. Use the package-compatible runtime and verify custom overrides.',
      'LOADER_FAILED' =>
        'The direct file loader failed. Check packaging, OS dependencies and overrides; production loader behavior remains unchecked.',
      'PROBE_TIMEOUT' || 'TERMINATION_UNCONFIRMED' =>
        'The isolated check did not terminate normally. Validate the runtime separately before retrying.',
      'CHILD_FAILED' || 'CHILD_PROTOCOL_INVALID' =>
        'The isolated check failed without a valid result. No runtime usability conclusion is available.',
      _ =>
        'Use a supported desktop Dart source invocation with its local native-assets manifest. Flutter apps, devices and browsers require separate validation.',
    },
  });
}

/// Canonical JSON prevents duplicate keys and ignored trailing data in IPC.
Object? decodeNativeDiagnosticJson(String source) {
  final decoded = jsonDecode(source);
  final compact = StringBuffer();
  var quoted = false;
  var escaped = false;
  for (final unit in source.codeUnits) {
    if (quoted || !const {9, 10, 13, 32}.contains(unit)) {
      compact.writeCharCode(unit);
    }
    if (quoted) {
      if (escaped) {
        escaped = false;
      } else if (unit == 92) {
        escaped = true;
      } else if (unit == 34) {
        quoted = false;
      }
    } else if (unit == 34) {
      quoted = true;
    }
  }
  if (compact.toString() != jsonEncode(decoded)) {
    throw const FormatException('Noncanonical native diagnostic JSON');
  }
  return decoded;
}

/// A selected manifest entry, never an assertion about a compiled app mapping.
final class NativeDiagnosticTarget {
  /// Concrete file declarations passed only to the private child.
  const NativeDiagnosticTarget(this.primary, this.wrapper, this.companions);

  /// The runtime's declared primary file.
  final String primary;

  /// Wrapper file, or [primary] for a monolithic artifact.
  final String wrapper;

  /// Declared dependency files opened before the primary.
  final List<String> companions;

  /// Private IPC representation, which must never be included in a report.
  Map<String, Object> toJson() => {
    'primary': primary,
    'wrapper': wrapper,
    'companions': companions,
  };

  /// Validates the private IPC target without echoing malformed values.
  static NativeDiagnosticTarget fromJson(Object? value) {
    if (value is! Map ||
        value.keys.join(',') != 'primary,wrapper,companions' ||
        value['primary'] is! String ||
        value['wrapper'] is! String ||
        value['companions'] is! List ||
        (value['companions'] as List).length > 24) {
      throw const FormatException('Invalid target');
    }
    final files = [
      value['primary'],
      value['wrapper'],
      ...value['companions'] as List,
    ];
    if (files.any(
      (item) =>
          item is! String ||
          item.isEmpty ||
          item.length > 4096 ||
          item.contains('\u0000') ||
          !path.isAbsolute(item),
    )) {
      throw const FormatException('Invalid target file');
    }
    return NativeDiagnosticTarget(
      value['primary'] as String,
      value['wrapper'] as String,
      List<String>.from(value['companions'] as List),
    );
  }
}

/// Reads a bounded local file, including when it changes after opening.
Future<String> readNativeDiagnosticFile(File file, int limit) async {
  final handle = await file.open();
  try {
    final bytes = await handle.read(limit + 1);
    if (bytes.length > limit) throw const FormatException('File exceeds limit');
    return utf8.decode(bytes);
  } finally {
    await handle.close();
  }
}

/// Reads only the current ABI's known, concrete local file declarations.
NativeDiagnosticTarget? parseNativeDiagnosticManifest(
  String source,
  String abi,
  String runtime,
) {
  if (source.length > 256 * 1024 ||
      !nativeDiagnosticRuntimes.contains(runtime)) {
    throw const FormatException('Invalid manifest');
  }
  final jsonSource = source
      .split('\n')
      .where((line) => !line.trimLeft().startsWith('#'))
      .join('\n');
  final decoded = decodeNativeDiagnosticJson(jsonSource);
  if (decoded is! Map ||
      jsonEncode(decoded['format-version']) != '[1,0,0]' ||
      decoded['native-assets'] is! Map) {
    throw const FormatException('Unsupported manifest');
  }
  final entries = (decoded['native-assets'] as Map)[abi];
  if (entries == null) return null;
  if (entries is! Map) throw const FormatException('Invalid ABI entry');
  final primaryId = switch (runtime) {
    'llama_cpp' => 'package:llamadart/llamadart',
    'stable_diffusion' => 'package:llamadart/stable_diffusion',
    _ =>
      'package:llamadart/litert_lm_${abi.startsWith('macos_') ? 'libLiteRtLm' : 'LiteRtLm'}',
  };
  String? file(String id) {
    final entry = entries[id];
    if (entry == null) return null;
    if (entry is! List ||
        entry.length != 2 ||
        entry[0] != 'absolute' ||
        entry[1] is! String ||
        (entry[1] as String).isEmpty ||
        (entry[1] as String).length > 4096 ||
        (entry[1] as String).contains('\u0000') ||
        !path.isAbsolute(entry[1] as String)) {
      throw const FormatException('Unsupported asset declaration');
    }
    return entry[1] as String;
  }

  final primary = file(primaryId);
  if (primary == null) return null;
  final wrapper = runtime == 'llama_cpp' && abi.startsWith('windows_')
      ? file('package:llamadart/llamadart_wrapper')
      : primary;
  if (wrapper == null) {
    throw const FormatException('Missing wrapper declaration');
  }
  final companions = <String>[];
  if (runtime == 'litert_lm') {
    // Fixed IDs only: untrusted neighboring assets are never opened.
    for (final name in const [
      'vcruntime140',
      'vcruntime140_1',
      'vcruntime140_threads',
      'msvcp140',
      'webgpu_dawn',
      'GemmaModelConstraintProvider',
      'LiteRt',
      'LiteRtTopKWebGpuSampler',
      'LiteRtWebGpuAccelerator',
      'libCLiteRTLM_mac',
      'libGemmaModelConstraintProvider',
      'libLiteRt',
      'libLiteRtMetalAccelerator',
      'libLiteRtTopKMetalSampler',
      'libLiteRtTopKWebGpuSampler',
      'libLiteRtWebGpuAccelerator',
      'libwebgpu_dawn',
    ]) {
      final candidate = file('package:llamadart/litert_lm_$name');
      if (candidate != null) companions.add(candidate);
    }
  }
  return NativeDiagnosticTarget(primary, wrapper, companions);
}

/// Injectable process start, confined to internal CLI tests.
typedef NativeDiagnosticProcessStarter =
    Future<Process> Function(String executable, List<String> arguments);

/// Recognizes the private CLI source or Dart's package-command snapshot layout.
/// Other app entry points must not relaunch their executable as a Dart helper.
bool isNativeDiagnosticCliInvocation(Uri entry, Uri config, Uri helper) {
  if (entry.scheme != 'file' ||
      config.scheme != 'file' ||
      helper.scheme != 'file') {
    return false;
  }
  if (entry == helper.resolve('../../../../bin/doctor_native.dart')) {
    return true;
  }
  return entry.resolve('.') == config.resolve('pub/bin/llamadart/') &&
      RegExp(
        r'^doctor_native\.dart-[A-Za-z0-9._-]{1,80}\.snapshot$',
      ).hasMatch(entry.pathSegments.last);
}

/// Launches the packaged helper without dartdev, hooks or a shell.
Future<Map<String, Object>> runNativeDiagnostic(
  String runtime, {
  Uri? packageConfig,
  Uri? childScript,
  String? abi,
  NativeDiagnosticProcessStarter? start,
  Duration timeout = const Duration(seconds: 30),
}) async {
  if (!nativeDiagnosticRuntimes.contains(runtime)) {
    throw ArgumentError('Unknown runtime');
  }
  Map<String, Object> result(String code, [String phase = 'not_started']) =>
      nativeDiagnosticObservation(runtime, code, phase: phase);
  if (!const {'macos', 'linux', 'windows'}.contains(Platform.operatingSystem)) {
    return result('PROBE_HOST_UNAVAILABLE');
  }
  final config = packageConfig ?? await Isolate.packageConfig;
  final script =
      childScript ??
      await Isolate.resolvePackageUri(
        Uri.parse(
          'package:llamadart/src/platform/io/native_diagnostics_child.dart',
        ),
      );
  if (config == null ||
      config.scheme != 'file' ||
      script == null ||
      script.scheme != 'file' ||
      (childScript == null &&
          !isNativeDiagnosticCliInvocation(Platform.script, config, script)) ||
      !await File.fromUri(script).exists()) {
    return result('PROBE_HOST_UNAVAILABLE');
  }
  NativeDiagnosticTarget? target;
  try {
    final manifest = File.fromUri(config.resolve('native_assets.yaml'));
    if (!await manifest.exists()) {
      return result('ASSET_DECLARATION_UNAVAILABLE', 'declaration');
    }
    target = parseNativeDiagnosticManifest(
      await readNativeDiagnosticFile(manifest, 256 * 1024),
      abi ?? Abi.current().toString(),
      runtime,
    );
  } catch (_) {
    return result('ASSET_DECLARATION_INVALID', 'declaration');
  }
  if (target == null) return result('ASSET_NOT_DECLARED', 'declaration');
  final directory = await Directory.systemTemp.createTemp(
    'llamadart_native_diagnostic_',
  );
  Process? child;
  var terminated = true;
  var phase = 'not_started';
  final output = File('${directory.path}/result.json');
  final phaseFile = File('${directory.path}/phase');
  final random = Random.secure();
  final nonce = List.generate(
    24,
    (_) => random.nextInt(256),
  ).map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  Future<void>? stdoutDone;
  Future<void>? stderrDone;
  final elapsed = Stopwatch()..start();
  try {
    var launchExpired = false;
    final launch =
        (start ??
        ((executable, arguments) => Process.start(
          executable,
          arguments,
          runInShell: false,
        )))(Platform.resolvedExecutable, [
          '--disable-dart-dev',
          '--packages=${config.toFilePath()}',
          script.toFilePath(),
        ]);
    unawaited(
      launch.then<void>((lateChild) async {
        if (launchExpired) {
          lateChild.kill(ProcessSignal.sigkill);
          unawaited(lateChild.stdout.drain<void>().catchError((Object _) {}));
          unawaited(lateChild.stderr.drain<void>().catchError((Object _) {}));
          try {
            await lateChild.exitCode.timeout(const Duration(seconds: 3));
          } catch (_) {
            /* A late launch contributes no runtime evidence. */
          }
        }
      }, onError: (Object _) {}),
    );
    try {
      child = await launch.timeout(timeout);
    } on TimeoutException {
      launchExpired = true;
      return result('PROBE_TIMEOUT');
    }
    terminated = false;
    // Native constructors and VM startup may print secrets. Never retain them.
    stdoutDone = child.stdout.drain<void>();
    stderrDone = child.stderr.drain<void>();
    final request = jsonEncode({
      'runtime': runtime,
      'nonce': nonce,
      'output': output.path,
      'phase': phaseFile.path,
      'target': target.toJson(),
    });
    int code;
    try {
      code =
          await (() async {
            child!.stdin.writeln(request);
            try {
              await child.stdin.close();
            } catch (_) {
              /* A failed child may close stdin first. */
            }
            return child!.exitCode;
          })().timeout(
            elapsed.elapsed >= timeout
                ? Duration.zero
                : timeout - elapsed.elapsed,
          );
      terminated = true;
    } on TimeoutException {
      child.kill(ProcessSignal.sigkill);
      try {
        await child.exitCode.timeout(const Duration(seconds: 3));
        terminated = true;
      } on TimeoutException {
        return result('TERMINATION_UNCONFIRMED');
      }
      return result('PROBE_TIMEOUT');
    }
    if (await phaseFile.exists()) {
      final value = await readNativeDiagnosticFile(phaseFile, 32);
      if (_phases.contains(value)) phase = value;
    }
    if (code != 0) return result('CHILD_FAILED', phase);
    if (!await output.exists()) {
      return result('CHILD_PROTOCOL_INVALID', phase);
    }
    final payload = decodeNativeDiagnosticJson(
      await readNativeDiagnosticFile(output, 8192),
    );
    if (payload is! Map ||
        payload.keys.join(',') != 'runtime,nonce,code,phase,marker' ||
        payload['runtime'] != runtime ||
        payload['nonce'] != nonce ||
        !_codes.contains(payload['code']) ||
        !_phases.contains(payload['phase']) ||
        !_markers.contains(payload['marker'])) {
      return result('CHILD_PROTOCOL_INVALID', phase);
    }
    final observation = nativeDiagnosticObservation(
      runtime,
      payload['code'] as String,
      phase: payload['phase'] as String,
      marker: payload['marker'] as String,
    );
    // Only the child probe's finite result vocabulary is accepted.
    if (!const {
      'SURFACE_OBSERVED',
      'ARTIFACT_MISSING',
      'DEPENDENCY_UNAVAILABLE',
      'BINARY_INCOMPATIBLE',
      'LOADER_FAILED',
      'SYMBOL_MISSING',
      'ABI_UNKNOWN',
    }.contains(payload['code'])) {
      return result('CHILD_PROTOCOL_INVALID', phase);
    }
    if (payload['code'] == 'SURFACE_OBSERVED' &&
        (payload['phase'] != 'complete' ||
            payload['marker'] !=
                switch (runtime) {
                  'llama_cpp' => 'tts_v1',
                  'litert_lm' => 'callback_v2_finish_v1',
                  _ => 'not_available',
                })) {
      return result('CHILD_PROTOCOL_INVALID', phase);
    }
    return observation;
  } catch (_) {
    return result(
      child == null ? 'PROBE_HOST_UNAVAILABLE' : 'CHILD_PROTOCOL_INVALID',
      phase,
    );
  } finally {
    if (!terminated && child != null) {
      child.kill(ProcessSignal.sigkill);
      try {
        await child.exitCode.timeout(const Duration(seconds: 3));
        terminated = true;
      } catch (_) {
        /* No raw subprocess failure reaches the report. */
      }
    }
    if (terminated) {
      try {
        await Future.wait([
          ?stdoutDone,
          ?stderrDone,
        ]).timeout(const Duration(seconds: 3), onTimeout: () => <void>[]);
        await directory.delete(recursive: true);
      } catch (_) {
        /* Cleanup failures contain no reportable runtime evidence. */
      }
    }
  }
}
