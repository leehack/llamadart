@Tags(['local-only', 'e2e'])
/// Local-only device check that a LiteRT-LM bundle in a directory the app
/// cannot write loads and generates with `ModelParams.liteRtLmCacheDir` unset
/// (https://github.com/leehack/llamadart/pull/975), the case of a model
/// shipped in an iOS app bundle.
///
/// It downloads and hash-checks the locked `chat-litert-*` validation model,
/// hard-links it into directories it then sets to mode 555, and loads it
/// through `LlamaEngine(LlamaBackend())`:
///
/// - `unsuffixed` on `cpu` and `gpu`: a bundle named without `.litertlm`. It
///   must generate.
/// - `litertlm` on `gpu`: a bundle named `.litertlm`, which fails engine
///   creation where no temp cache default exists
///   (https://github.com/leehack/llamadart/issues/976). It is recorded, not
///   judged: it must either generate or throw a `LlamaException`.
///
/// No case may leave anything in its directory. Each one logs a `started`
/// line, which names the case a crash or a hang ended in, and then its
/// result:
///
/// ```text
/// E2E read-only bundle: case=<id> backend=<cpu|gpu> outcome=<ok|empty_reply|typed_error:<Type>> ms=<n>
/// ```
///
/// macOS and Android cache in a temp directory by default, so there every
/// case generates and the run checks the harness only.
/// `--dart-define=LITERT_READ_ONLY_NO_TEMP_CACHE=true` runs the LiteRT-LM
/// service with that default off, as on iOS and Linux, instead of the public
/// backend. `LITERT_READ_ONLY_MODEL` names a local copy of the model.
///
/// ```bash
/// cd example/chat_app
/// flutter test --run-skipped -t local-only \
///   integration_test/litert_lm_read_only_bundle_e2e_test.dart -d <device>
/// ```
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/litert_lm/litert_lm_backend.dart';
import 'package:llamadart/src/backends/litert_lm/litert_lm_service.dart';
import 'package:llamadart/src/backends/litert_lm/worker.dart';
import 'package:llamadart_validation/io.dart';
import 'package:llamadart_validation/llamadart_validation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

const _logTag = 'E2E read-only bundle:';
const _profileAssets = 'packages/llamadart_validation/assets/profiles/';
const _noTempCache = bool.fromEnvironment('LITERT_READ_ONLY_NO_TEMP_CACHE');
const _caseTimeout = Duration(minutes: 2);

// Octal 555 and 755.
const _readOnlyMode = 0x16d;
const _writableMode = 0x1ed;

const _cases = [
  (id: 'unsuffixed', backend: 'cpu', mustGenerate: true),
  (id: 'unsuffixed', backend: 'gpu', mustGenerate: true),
  (id: 'litertlm', backend: 'gpu', mustGenerate: false),
];

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a LiteRT-LM bundle in a read-only directory runs uncached', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Text('Running LiteRT-LM read-only bundle E2E')),
      ),
    );
    final support = await getApplicationSupportDirectory();
    final model = File(await _prepareModel(await _loadProfile('cpu'), support));
    final root = Directory(
      p.join(support.path, 'litert_lm_read_only_bundle_e2e'),
    );
    _deleteTree(root);
    addTearDown(() => _deleteTree(root));

    final fileName = p.basename(model.path);
    final bundles = {
      'unsuffixed': p.join(
        root.path,
        'unsuffixed',
        p.basenameWithoutExtension(fileName),
      ),
      'litertlm': p.join(root.path, 'litertlm', fileName),
    };
    final placements = <String>{};
    for (final bundle in bundles.values) {
      final directory = Directory(p.dirname(bundle))
        ..createSync(recursive: true);
      placements.add(_place(model, bundle));
      _chmod(directory, _readOnlyMode);
    }
    debugPrint(
      '$_logTag config os=${Platform.operatingSystem} '
      'service=${_noTempCache ? 'no_temp_cache' : 'public'} '
      'placement=${placements.join('+')}',
    );

    final failures = <String>[];
    for (final (:id, :backend, :mustGenerate) in _cases) {
      final label = 'case=$id backend=$backend';
      final bundle = bundles[id]!;
      final directory = Directory(p.dirname(bundle));
      void expectUntouched(String when) {
        expect(
          _canCreateFile(directory),
          isFalse,
          reason: '$label: the app can write the directory $when',
        );
        expect(
          directory.statSync().mode & 0x1ff,
          _readOnlyMode,
          reason: '$label: directory mode $when',
        );
        expect(
          [
            for (final entry in directory.listSync(followLinks: false))
              p.basename(entry.path),
          ],
          [p.basename(bundle)],
          reason: '$label: directory entries $when',
        );
      }

      expectUntouched('before the load');
      final profile = await _loadProfile(backend);
      expect(profile.loadParams.liteRtLmCacheDir, isNull);
      debugPrint('$_logTag started $label');
      final watch = Stopwatch()..start();
      String outcome;
      try {
        final reply = await _reply(bundle, profile).timeout(_caseTimeout);
        debugPrint('$_logTag reply $label text=${jsonEncode(reply)}');
        outcome = reply.isEmpty ? 'empty_reply' : 'ok';
      } on LlamaException catch (error) {
        debugPrint(
          '$_logTag error $label type=${error.runtimeType} '
          'message=${jsonEncode(error.message)}',
        );
        outcome = 'typed_error:${error.runtimeType}';
      }
      debugPrint(
        '$_logTag $label outcome=$outcome ms=${watch.elapsedMilliseconds}',
      );
      if (outcome == 'empty_reply' || (mustGenerate && outcome != 'ok')) {
        failures.add('$label: $outcome');
      }
      expectUntouched('after the load');
    }
    expect(failures, isEmpty, reason: failures.join('\n'));
  }, timeout: const Timeout(Duration(minutes: 13)));
}

/// The cache default of iOS and Linux, for a host that has a temp cache
/// default.
void _workerWithoutTempCache(SendPort initialSendPort) {
  runLiteRtLmWorkerForTesting(
    initialSendPort,
    LiteRtLmService(useTempCacheDir: false),
  );
}

Future<String> _reply(String bundle, ValidationProfile profile) async {
  final engine = LlamaEngine(
    _noTempCache
        ? LiteRtLmBackend(workerEntryPoint: _workerWithoutTempCache)
        : LlamaBackend(),
  );
  try {
    await engine.setModel(
      LlamaModel(ModelSource.path(bundle)),
      params: profile.loadParams,
    );
    final text = await engine
        .create(
          [
            LlamaChatMessage.fromText(
              role: LlamaChatRole.user,
              text: profile.fixtureText('hello', 'prompt'),
            ),
          ],
          params: profile.generationParams,
          enableThinking: false,
        )
        .text();
    return text.trim();
  } finally {
    await engine.dispose();
  }
}

Future<ValidationProfile> _loadProfile(String backend) async {
  final source = await rootBundle.loadString(
    '${_profileAssets}chat-litert-$backend.json',
  );
  return ValidationProfile.fromJson(jsonDecode(source) as Map<String, dynamic>);
}

Future<String> _prepareModel(
  ValidationProfile profile,
  Directory support,
) async {
  const supplied = String.fromEnvironment('LITERT_READ_ONLY_MODEL');
  final client = http.Client();
  final watch = Stopwatch()..start();
  try {
    final model = await prepareModel(
      profile,
      Directory(p.join(support.path, 'validation', 'models')),
      suppliedPath: supplied.isEmpty ? null : supplied,
      client: client,
      timeout: const Duration(minutes: 6),
    );
    debugPrint(
      '$_logTag model sha256=${profile.modelHash} '
      'cache_hit=${model.evidence['cache_hit']} '
      'prepare_ms=${watch.elapsedMilliseconds}',
    );
    return model.path;
  } finally {
    client.close();
  }
}

final DynamicLibrary _libc = DynamicLibrary.process();

// mode_t is 16 bits on Apple platforms and 32 on Linux; either one is passed
// as a 32-bit register argument.
final int Function(Pointer<Utf8>, int) _nativeChmod = _libc
    .lookupFunction<
      Int Function(Pointer<Utf8>, Uint32),
      int Function(Pointer<Utf8>, int)
    >('chmod');

final int Function(Pointer<Utf8>, Pointer<Utf8>) _nativeLink = _libc
    .lookupFunction<
      Int Function(Pointer<Utf8>, Pointer<Utf8>),
      int Function(Pointer<Utf8>, Pointer<Utf8>)
    >('link');

void _chmod(Directory directory, int mode) => using((arena) {
  final path = directory.path.toNativeUtf8(allocator: arena);
  if (_nativeChmod(path, mode) != 0) {
    throw FileSystemException(
      'chmod ${mode.toRadixString(8)} failed',
      directory.path,
    );
  }
});

/// Puts [model] at [path] as a regular file, like one shipped in an app
/// bundle: a hard link, or a copy when the cache is on another volume.
String _place(File model, String path) => using((arena) {
  final linked =
      _nativeLink(
        model.path.toNativeUtf8(allocator: arena),
        path.toNativeUtf8(allocator: arena),
      ) ==
      0;
  if (!linked) model.copySync(path);
  return linked ? 'hard_link' : 'copy';
});

bool _canCreateFile(Directory directory) {
  final probe = File(p.join(directory.path, 'write_probe'));
  try {
    probe.createSync();
  } on FileSystemException {
    return false;
  }
  probe.deleteSync();
  return true;
}

/// Also removes what a run that died left behind in read-only directories.
void _deleteTree(Directory root) {
  if (!root.existsSync()) return;
  for (final entry in root.listSync(followLinks: false)) {
    if (entry is Directory) _chmod(entry, _writableMode);
  }
  root.deleteSync(recursive: true);
}
