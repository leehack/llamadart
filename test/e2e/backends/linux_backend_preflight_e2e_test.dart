@TestOn('vm')
@Tags(['local-only', 'e2e'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:llamadart/backend.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/llama_cpp/build_identity.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

const _prefix = 'LLAMADART_LINUX_BACKEND_';
final _offloadPattern = RegExp(r'offloaded (\d+)/(\d+) layers to GPU');

void main() {
  test('Linux backend preflight preserves real backend execution', () async {
    final profile = Platform.environment['${_prefix}PROFILE'];
    if (!Platform.isLinux || profile == null) {
      markTestSkipped('Requires Linux and an explicit ${_prefix}PROFILE.');
      return;
    }
    final (preferred, expectedBackend, vulkanAvailable) = switch (profile) {
      'auto-no-vulkan-cpu' => (GpuBackend.auto, 'CPU', false),
      'auto-no-vulkan-cuda' => (GpuBackend.auto, 'CUDA', false),
      'vulkan' => (GpuBackend.vulkan, 'Vulkan', true),
      'cpu-no-vulkan' => (GpuBackend.cpu, 'CPU', false),
      _ => throw ArgumentError.value(profile, '${_prefix}PROFILE'),
    };
    final provenance = await _sourceProvenance(
      root: Directory.current,
      expectedRevision:
          Platform.environment['${_prefix}EXPECTED_SOURCE_REVISION'],
    );
    final model = File(_required('MODEL'));
    expect(model.existsSync(), isTrue, reason: 'Use an existing local GGUF.');
    final expectedHash = _required('MODEL_SHA256').toLowerCase();
    expect(expectedHash, matches(RegExp(r'^[a-f0-9]{64}$')));
    final modelHash = await _hash(model);
    expect(modelHash, expectedHash);
    final nativeLog = File(_required('NATIVE_LOG'));
    expect(nativeLog.existsSync(), isTrue);
    expect(
      _offloadPattern.allMatches(nativeLog.readAsStringSync()),
      isEmpty,
      reason:
          'Redirect this one profile to a fresh combined stdout/stderr log.',
    );
    final probeReason = probeLinuxVulkanUnavailableReason();
    expect(probeReason == null, vulkanAvailable, reason: probeReason);
    if (!vulkanAvailable) {
      expect(
        Platform.environment['VK_ICD_FILENAMES'],
        isNotEmpty,
        reason: 'Set an invalid process-scoped ICD path for negative controls.',
      );
    }
    await LlamaLogging.configure(nativeLevel: LlamaLogLevel.info);
    addTearDown(LlamaLogging.configure);
    final requestedLayers = preferred == GpuBackend.cpu ? 0 : 99;
    final engine = await LlamaEngine.load(
      LlamaModel(ModelSource.path(model.path)),
      params: ModelParams(
        contextSize: 2048,
        preferredBackend: preferred,
        gpuLayers: requestedLayers,
        numberOfThreads: 2,
        numberOfThreadsBatch: 2,
      ),
    );
    addTearDown(engine.dispose);
    final backend = await engine.getBackendName();
    final resolvedLayers = await engine.getResolvedGpuLayers();
    final completion = await engine.complete(
      const [
        LlamaChatMessage.fromText(
          role: LlamaChatRole.user,
          text: 'What is 2 + 2? Reply with only the digit.',
        ),
      ],
      enableThinking: false,
      params: const GenerationParams(maxTokens: 32, temp: 0, seed: 1),
    );
    final modules = await _loadedModules();
    final identity = readNativeBuildIdentity(isWindows: false);
    await engine.dispose();
    final nativeOutput = nativeLog.readAsStringSync();
    final offload = _offloadPattern.allMatches(nativeOutput).toList();
    final offloadedLayers = offload.fold<int>(0, (maximum, match) {
      final layers = int.parse(match[1]!);
      return layers > maximum ? layers : maximum;
    });
    final sources = <String, String>{};
    for (final file in [
      'lib/src/backends/llama_cpp/llama_cpp_service.dart',
      'lib/src/backends/llama_cpp/library_loading.dart',
      'lib/src/backends/linux_vulkan_probe_io.dart',
      'test/e2e/backends/linux_backend_preflight_e2e_test.dart',
    ]) {
      sources[file] = await _hash(File(file));
    }
    print(
      'RESULT linux_backend_preflight ${jsonEncode({'profile': profile, ...provenance, 'source_sha256': sources, 'native_build_identity': identity, 'native_modules': modules, 'model_sha256': modelHash, 'vulkan_probe_reason': probeReason, 'requested_backend': preferred.name, 'actual_backend': backend, 'requested_gpu_layers': requestedLayers, 'resolved_gpu_layers': resolvedLayers, 'native_offloaded_layers': offloadedLayers, 'native_offload_records': offload.map((match) => match[0]).toList(), 'native_log_sha256': await _hash(nativeLog), 'answer': completion.text})}',
    );
    expect(identity, isNotNull);
    expect(modules, isNotEmpty);
    expect(
      modules.any((module) => module['file'] == 'libflutter_linux_gtk.so'),
      isTrue,
      reason: 'Preload the production Flutter Linux library for this profile.',
    );
    expect(backend, expectedBackend);
    expect(completion.text.trim(), '4');
    if (expectedBackend == 'CPU') {
      expect(offloadedLayers, 0);
      if (preferred == GpuBackend.cpu) expect(resolvedLayers, 0);
    } else {
      expect(resolvedLayers, greaterThan(0));
      expect(
        offloadedLayers,
        greaterThan(0),
        reason: 'A requested layer count or backend label is not GPU proof.',
      );
      expect(
        modules.any(
          (module) => (module['file'] as String).startsWith(
            'libggml-${expectedBackend.toLowerCase()}.so',
          ),
        ),
        isTrue,
      );
    }
  });

  group('source provenance', () {
    const revision = '0123456789abcdef0123456789abcdef01234567';
    late Directory root;
    late File manifest;
    Map<String, Object?> archiveManifest() => {
      'gitRevision': revision,
      'generatedLockOverlays': [
        {
          'path': 'pubspec.lock',
          'bytes': 7,
          'sha256': 'a' * 64,
          'source': 'explicit generated dependency lock; no code overlay',
        },
      ],
      'noCodeOverlay': true,
    };
    setUp(() {
      root = Directory.systemTemp.createTempSync('linux_source_provenance_');
      manifest = File(
        path.join(root.path, 'QUALIFICATION_SOURCE_MANIFEST.json'),
      );
    });
    tearDown(() => root.deleteSync(recursive: true));

    test(
      'archive binds exact manifest bytes without claiming authentication',
      () async {
        final bytes = utf8.encode(jsonEncode(archiveManifest()));
        manifest.writeAsBytesSync(bytes);
        final result = await _sourceProvenance(
          root: root,
          expectedRevision: revision,
        );
        expect(result['source_kind'], 'archive-manifest');
        expect(result['source_head'], revision);
        expect(
          result['source_manifest_sha256'],
          sha256.convert(bytes).toString(),
        );
        expect(
          result['source_manifest_validation'],
          'format-and-overlay-policy-only',
        );
        expect(
          result['source_authentication'],
          'external-archive-and-all-files-verification-required',
        );
      },
    );

    test(
      'missing archive metadata never borrows an ancestor Git HEAD',
      () async {
        final nested = Directory.current.createTempSync(
          '.dart_tool/linux_archive_',
        );
        addTearDown(() => nested.deleteSync(recursive: true));
        await expectLater(_sourceProvenance(root: nested), throwsStateError);
      },
    );

    test('malformed or code-overlay manifests are refused', () async {
      for (final invalid in [
        'not JSON',
        jsonEncode({...archiveManifest(), 'gitRevision': 'not-a-revision'}),
        jsonEncode({...archiveManifest(), 'noCodeOverlay': false}),
        jsonEncode({...archiveManifest(), 'generatedLockOverlays': 'unknown'}),
        jsonEncode({
          ...archiveManifest(),
          'generatedLockOverlays': [
            {'path': 'lib/overlay.dart', 'bytes': 7, 'sha256': 'a' * 64},
          ],
        }),
        jsonEncode({
          ...archiveManifest(),
          'generatedLockOverlays': [
            {'path': '../pubspec.lock', 'bytes': 7, 'sha256': 'a' * 64},
          ],
        }),
        jsonEncode({
          ...archiveManifest(),
          'generatedLockOverlays': [
            {'path': 'pubspec.lock', 'bytes': -1, 'sha256': 'a' * 64},
          ],
        }),
      ]) {
        manifest.writeAsStringSync(invalid);
        await expectLater(_sourceProvenance(root: root), throwsFormatException);
      }
    });

    test(
      'an expected revision mismatch is refused before model loading',
      () async {
        manifest.writeAsStringSync(jsonEncode(archiveManifest()));
        await expectLater(
          _sourceProvenance(root: root, expectedRevision: 'f' * 40),
          throwsStateError,
        );
      },
    );

    test(
      'Git checkout retains its actual revision and takes precedence',
      () async {
        if (FileSystemEntity.typeSync('.git') !=
                FileSystemEntityType.directory &&
            FileSystemEntity.typeSync('.git') != FileSystemEntityType.file) {
          markTestSkipped('An archive has no Git metadata to inspect.');
          return;
        }
        final actual = Process.runSync('git', ['rev-parse', 'HEAD']);
        expect(actual.exitCode, 0);
        final result = await _sourceProvenance(root: Directory.current);
        expect(result['source_kind'], 'git');
        expect(result['source_head'], (actual.stdout as String).trim());
        expect(result.containsKey('source_manifest_sha256'), isFalse);
      },
    );
  });
}

Future<Map<String, Object?>> _sourceProvenance({
  required Directory root,
  String? expectedRevision,
}) async {
  final revisionPattern = RegExp(r'^[a-fA-F0-9]{40}$');
  if (expectedRevision != null && !revisionPattern.hasMatch(expectedRevision)) {
    throw const FormatException(
      'Expected source revision must be 40 hex digits.',
    );
  }
  late String revision;
  late Map<String, Object?> provenance;
  final git = FileSystemEntity.typeSync(path.join(root.path, '.git'));
  if (git != FileSystemEntityType.notFound) {
    final head = Process.runSync('git', [
      'rev-parse',
      'HEAD',
    ], workingDirectory: root.path);
    revision = (head.stdout as String).trim();
    if (head.exitCode != 0 || !revisionPattern.hasMatch(revision)) {
      throw StateError('Cannot determine the Git source revision.');
    }
    provenance = {'source_kind': 'git', 'source_head': revision};
  } else {
    final manifest = File(
      path.join(root.path, 'QUALIFICATION_SOURCE_MANIFEST.json'),
    );
    if (!manifest.existsSync()) {
      throw StateError(
        'Source requires Git metadata or a qualification manifest.',
      );
    }
    final bytes = await manifest.readAsBytes();
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic> ||
        decoded['gitRevision'] is! String ||
        !revisionPattern.hasMatch(decoded['gitRevision'] as String) ||
        decoded['noCodeOverlay'] != true ||
        decoded['generatedLockOverlays'] is! List) {
      throw const FormatException('Invalid qualification source manifest.');
    }
    final overlays = decoded['generatedLockOverlays'] as List;
    for (final overlay in overlays) {
      if (overlay is! Map<String, dynamic> ||
          overlay['path'] is! String ||
          overlay['bytes'] is! int ||
          (overlay['bytes'] as int) < 0 ||
          overlay['sha256'] is! String ||
          !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(overlay['sha256'] as String)) {
        throw const FormatException('Invalid generated lock overlay metadata.');
      }
      final name = overlay['path'] as String;
      if (path.posix.isAbsolute(name) ||
          name.contains(r'\') ||
          name
              .split('/')
              .any((part) => part.isEmpty || part == '.' || part == '..') ||
          path.posix.basename(name) != 'pubspec.lock') {
        throw const FormatException(
          'Qualification overlays must be relative pubspec.lock files.',
        );
      }
    }
    revision = decoded['gitRevision'] as String;
    provenance = {
      'source_kind': 'archive-manifest',
      'source_head': revision,
      'source_manifest_sha256': sha256.convert(bytes).toString(),
      'source_manifest_validation': 'format-and-overlay-policy-only',
      'source_authentication':
          'external-archive-and-all-files-verification-required',
      'source_generated_lock_overlays': overlays,
    };
  }
  if (expectedRevision != null &&
      revision.toLowerCase() != expectedRevision.toLowerCase()) {
    throw StateError('Source revision does not match the expected revision.');
  }
  return provenance;
}

String _required(String suffix) {
  final name = '$_prefix$suffix';
  final value = Platform.environment[name];
  if (value == null || value.isEmpty) throw StateError('Set $name.');
  return value;
}

Future<String> _hash(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

Future<List<Map<String, String>>> _loadedModules() async {
  final libraries = <String>{};
  final pattern = RegExp(
    r'/lib(?:llama(?:dart)?|ggml(?:-[^/]+)?|flutter_linux_gtk)\.so(?:\.\d+)*$',
  );
  for (final line in File('/proc/self/maps').readAsLinesSync()) {
    final start = line.indexOf('/');
    if (start < 0) continue;
    final library = line.substring(start);
    if (pattern.hasMatch(library)) {
      libraries.add(File(library).resolveSymbolicLinksSync());
    }
  }
  return [
    for (final library in libraries.toList()..sort())
      {'file': path.basename(library), 'sha256': await _hash(File(library))},
  ];
}
