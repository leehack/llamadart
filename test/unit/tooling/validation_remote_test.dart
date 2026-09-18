@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:llamadart/src/hook/native_bundle_config.dart';
import 'package:yaml/yaml.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../../tool/testing/validation/bundle.dart';
import '../../../tool/testing/validation/collect.dart';
import '../../../tool/testing/validation/process.dart';
import '../../../tool/testing/validation/remote.dart';
import '../../../tool/testing/validation/runtime_bundle.dart';

class FakeProvider implements RemoteProvider {
  int starts = 0;
  Completer<void>? pausePreflight;
  bool preflightFails = false;
  bool uncertainStart = false;
  bool collectionFails = false;
  bool cleanupVerified = true;
  bool successful = true;
  bool checkpointBeforeFailure = false;
  void Function(RemotePlan)? onStart;
  final List<String> calls = [];
  Map<String, dynamic>? cleanupRemote;
  @override
  Future<Map<String, dynamic>> identify(
    RemotePlan plan,
    String remoteId,
  ) async {
    calls.add('identify');
    if (remoteId != 'matrix-one') throw StateError('Wrong identity');
    return {'matrix_id': remoteId};
  }

  @override
  Future<void> preflight(RemotePlan plan) async {
    calls.add('preflight');
    await pausePreflight?.future;
    if (preflightFails) throw StateError('quota unavailable');
  }

  @override
  Future<Map<String, dynamic>> start(
    RemotePlan plan,
    void Function(Map<String, dynamic>) checkpoint,
  ) async {
    calls.add('start');
    onStart?.call(plan);
    starts++;
    final remote = <String, dynamic>{'matrix_id': 'matrix-one'};
    if (checkpointBeforeFailure) checkpoint(remote);
    if (uncertainStart) throw TimeoutException('Lost response');
    checkpoint(remote);
    return remote;
  }

  @override
  Future<Map<String, dynamic>> status(
    RemotePlan plan,
    Map<String, dynamic> remote,
  ) async {
    calls.add('status');
    return {
      'terminal': true,
      'state': 'FINISHED',
      'test_exit_code': successful ? 0 : 1,
      'matrix': {'outcomeSummary': successful ? 'SUCCESS' : 'FAILURE'},
    };
  }

  @override
  Future<void> collect(
    RemotePlan plan,
    Map<String, dynamic> remote,
    Directory output,
  ) async {
    calls.add('collect');
    if (collectionFails) throw StateError('retrieval interrupted');
  }

  @override
  Future<Map<String, dynamic>> cleanup(
    RemotePlan plan,
    Map<String, dynamic> remote,
  ) async {
    calls.add('cleanup');
    cleanupRemote = remote;
    return {'verified': cleanupVerified && remote.isNotEmpty};
  }
}

class MatrixProvider extends GcloudProvider {
  MatrixProvider(this.value, {super.execute});
  final Map<String, dynamic> value;
  @override
  Future<Map<String, dynamic>> matrix(
    RemotePlan plan,
    String id, {
    bool cancel = false,
  }) async {
    if (cancel) throw StateError('Read-only identity check must not cancel');
    return value;
  }
}

void main() {
  test('desktop validation hook selects all advertised x64 backends', () {
    final yaml =
        loadYaml(
              File(
                'packages/llamadart_validation/pubspec.yaml',
              ).readAsStringSync(),
            )
            as Map;
    final raw =
        yaml['hooks']['user_defines']['llamadart'][nativeBackendUserDefineKey];
    for (final target in ['linux-x64', 'windows-x64']) {
      expect(
        parseRequestedBackends(bundle: target, rawUserConfig: raw),
        containsAll(['cpu', 'vulkan', 'cuda']),
      );
    }
  });

  test(
    'desktop payload guard rejects absent CUDA and accepts versioned modules',
    () {
      final root = Directory.systemTemp.createTempSync('validation-backends-');
      addTearDown(() => root.deleteSync(recursive: true));
      final libraries = Directory(p.join(root.path, 'lib'))..createSync();
      for (final target in [Abi.linuxX64, Abi.windowsX64]) {
        for (final file in libraries.listSync()) {
          file.deleteSync();
        }
        String name(String backend) => target == Abi.linuxX64
            ? 'libggml-$backend.so.0'
            : 'ggml-$backend.dll';
        for (final backend in ['cpu', 'vulkan']) {
          File(
            p.join(libraries.path, name(backend)),
          ).writeAsStringSync('fixture');
        }
        expect(
          () => requireDesktopBackendModules(root, abi: target),
          throwsStateError,
        );
        File(p.join(libraries.path, name('cuda'))).writeAsStringSync('fixture');
        expect(
          () => requireDesktopBackendModules(root, abi: target),
          returnsNormally,
        );
      }
      expect(
        () => requireDesktopBackendModules(root, abi: Abi.macosArm64),
        returnsNormally,
      );
    },
  );

  test(
    'desktop builder refuses to seal a CPU and Vulkan only payload',
    () async {
      final root = Directory.systemTemp.createTempSync('validation-build-');
      addTearDown(() => root.deleteSync(recursive: true));
      for (final path in [
        '.flutter-version',
        'hook/build.dart',
        'scripts/fetch_webgpu_bridge_assets.sh',
        'packages/llamadart_validation/assets/profiles/tiny-gguf-cpu.json',
      ]) {
        final target = File(p.join(root.path, path));
        target.parent.createSync(recursive: true);
        File(path).copySync(target.path);
      }
      final output = Directory(p.join(root.path, 'output'));
      var builds = 0;
      await expectLater(
        buildValidationBundle(
          root.path,
          'desktop',
          output.path,
          execute: (binary, args, {directory, timeout}) async {
            if (binary == 'git') {
              return CommandResult(
                0,
                args.first == 'rev-parse' ? 'a' * 40 : '',
                '',
              );
            }
            if (binary == 'flutter' && args.first == '--version') {
              return CommandResult(
                0,
                jsonEncode({
                  'frameworkVersion': File(
                    '.flutter-version',
                  ).readAsStringSync().trim(),
                  'dartSdkVersion': Platform.version.split(' ').first,
                }),
                '',
              );
            }
            if (args.first == 'pub') return const CommandResult(0, '', '');
            if (args.first != 'build') {
              throw StateError('Unexpected command after backend guard');
            }
            builds++;
            final destination = args[args.indexOf('-o') + 1];
            final name = args.contains('bin/run.dart') ? 'run' : 'report';
            final executable = File(
              p.join(
                destination,
                'bundle',
                'bin',
                Platform.isWindows ? '$name.exe' : name,
              ),
            );
            executable.parent.createSync(recursive: true);
            executable.writeAsStringSync('executable fixture');
            for (final backend in ['cpu', 'vulkan']) {
              final library = File(
                p.join(
                  destination,
                  'bundle',
                  'lib',
                  Platform.isWindows
                      ? 'ggml-$backend.dll'
                      : 'libggml-$backend.so.0',
                ),
              );
              library.parent.createSync(recursive: true);
              library.writeAsStringSync('library fixture');
            }
            return const CommandResult(0, '', '');
          },
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'missing backend',
            contains('missing backend modules: cuda'),
          ),
        ),
      );
      expect(builds, 2);
      expect(output.existsSync(), false);
    },
    skip: ![Abi.linuxX64, Abi.windowsX64].contains(Abi.current())
        ? 'Runs against the production host ABI on Linux/Windows x64 CI'
        : false,
  );

  test(
    'Windows arm64 keeps GGUF builds without requiring a LiteRT archive',
    () async {
      expect(standaloneLiteRtTarget(Abi.windowsArm64), isNull);
      expect(standaloneLiteRtTarget(Abi.windowsX64), 'windows-x64');
      expect(standaloneLiteRtTarget(Abi.linuxArm64), 'linux-arm64');
      final scratch = Directory.systemTemp.createTempSync('validation-arm64-');
      addTearDown(() => scratch.deleteSync(recursive: true));
      final identity = <String, dynamic>{'profile': 'tiny-gguf-cpu'};
      await bundleLiteRtRuntime(
        'missing-checkout',
        scratch,
        scratch,
        identity,
        abi: Abi.windowsArm64,
        execute: (executable, arguments, {directory, timeout}) async =>
            throw StateError('No extraction should run'),
      );
      expect(identity['litert_runtime_supported'], false);
      expect(scratch.listSync(), isEmpty);
      await expectLater(
        bundleLiteRtRuntime('missing-checkout', scratch, scratch, {
          'profile': 'chat-litert-cpu',
        }, abi: Abi.windowsArm64),
        throwsUnsupportedError,
      );
    },
  );
  test(
    'standalone LiteRT archive inventory matches every supported desktop hook',
    () {
      final hook = File('hook/build.dart').readAsStringSync();
      for (final target in [
        'macos-arm64',
        'macos-x64',
        'linux-arm64',
        'linux-x64',
        'windows-x64',
      ]) {
        final spec = liteRtArchiveSpec(hook, target);
        expect(spec.checksum, matches(r'^[a-f0-9]{64}$'));
        expect(spec.libraries, isNotEmpty);
        expect(spec.libraries.any((name) => name.contains('LiteRtLm')), true);
      }
      expect(() => liteRtArchiveSpec(hook, 'windows-arm64'), throwsStateError);
      expect(
        () => liteRtArchiveSpec(
          hook.replaceAll('sha256:', 'unverified:'),
          'macos-arm64',
        ),
        throwsStateError,
      );
    },
  );
  late Directory scratch;
  late Directory bundle;
  late Directory runs;
  final now = DateTime.utc(2026, 9, 17, 12);
  setUp(() async {
    scratch = Directory.systemTemp.createTempSync('validation-remote-test-');
    bundle = Directory(p.join(scratch.path, 'bundle'))..createSync();
    runs = Directory(p.join(scratch.path, 'runs'));
    File(p.join(bundle.path, 'app.apk')).writeAsStringSync('app');
    File(p.join(bundle.path, 'test.apk')).writeAsStringSync('test');
    File(
      'packages/llamadart_validation/assets/profiles/tiny-gguf-cpu.json',
    ).copySync(p.join(bundle.path, 'profile.json'));
    await writeBundleManifest(bundle, {
      'target': 'android',
      'profile': 'tiny-gguf-cpu',
      'source_dirty': false,
    });
  });
  tearDown(() => scratch.deleteSync(recursive: true));

  RemotePlan plan({
    String id = 'qa-one',
    String target = 'firebase-android',
    String profile = 'tiny-gguf-cpu',
  }) => RemotePlan({
    'schema_version': 1,
    'run_id': id,
    'target': target,
    'project': 'test-project',
    'account': 'tester@example.com',
    'profile': profile,
    'bundle': bundle.path,
    'bundle_sha256': sha256
        .convert(
          File(p.join(bundle.path, 'bundle-manifest.json')).readAsBytesSync(),
        )
        .toString(),
    'settings': {
      'device_model': 'test-device',
      'device_version': '35',
      'zone': 'us-central1-a',
      'machine_type': 'g2-standard-4',
      'network': 'validation',
      'iap_tag': 'validation-ssh',
      'image': 'projects/test-project/global/images/pinned',
      'gpu_ready_image': true,
      'driver_version': '550',
      'quota': {
        'verified_at': now.toIso8601String(),
        'remaining_physical': 1,
        'evidence': 'checked console',
      },
      'credit': {
        'verified_at': now.toIso8601String(),
        'evidence': 'checked billing console',
        'applicable': true,
        'available_usd': 20,
        'maximum_run_usd': 3,
        'expires_at': now.add(const Duration(days: 2)).toIso8601String(),
      },
    },
  });
  RemoteController controller(FakeProvider provider, {bool pass = true}) =>
      RemoteController(
        runs,
        provider,
        now: () => now,
        delay: (_) async {},
        assess: (_, _) async => pass,
      );

  test(
    'collected qualification binds every uploaded runtime identity',
    () async {
      final identity = <String, dynamic>{
        'source_commit': 'a' * 40,
        'source_dirty': false,
        'hook_sha256': 'b' * 64,
        'native_tag': 'v0.4.0',
        'litert_tag': '0.17.0-5',
        'bridge_tag': 'fixture-bridge',
      };
      await writeBundleManifest(bundle, {'target': 'android', ...identity});
      final profile = jsonDecode(
        File(p.join(bundle.path, 'profile.json')).readAsStringSync(),
      );
      final run = Directory(p.join(scratch.path, 'collected'))..createSync();
      final pulled = Directory(p.join(run.path, 'remote-results'))
        ..createSync();
      File(
        p.join(pulled.path, 'events.jsonl'),
      ).writeAsStringSync(jsonEncode({'type': 'manifest', 'profile': profile}));
      Future<bool> assess(Map<String, dynamic> environment) =>
          assessCollectedRun(
            Directory.current.path,
            plan(),
            run,
            execute: (executable, arguments, {directory, timeout}) async {
              expect(arguments, contains('bin/report.dart'));
              File(p.join(arguments[2], 'results.json')).writeAsStringSync(
                jsonEncode({
                  'manifest': {'environment': environment, 'profile': profile},
                  'summary': {'qualified': true},
                }),
              );
              return const CommandResult(0, '', '');
            },
          );
      expect(await assess(identity), true);
      for (final key in identity.keys) {
        expect(
          await assess({
            ...identity,
            key: key == 'source_dirty' ? true : 'different',
          }),
          false,
          reason: key,
        );
        expect(await assess({...identity}..remove(key)), false, reason: key);
      }
    },
  );

  test(
    'source provenance rejects local pub overrides before reading Git',
    () async {
      File(
        p.join(scratch.path, 'pubspec_overrides.yaml'),
      ).writeAsStringSync('dependency_overrides: {}');
      await expectLater(
        readValidationProvenance(
          scratch.path,
          execute: (executable, arguments, {directory, timeout}) async =>
              throw StateError('Git must not run'),
        ),
        throwsA(
          isA<StateError>().having(
            (error) => '$error',
            'reason',
            contains('local pub overrides'),
          ),
        ),
      );
    },
  );

  RemotePlan blazePlan({String id = 'qa-one', String funding = 'credit'}) {
    final json =
        jsonDecode(jsonEncode(plan(id: id).json)) as Map<String, dynamic>;
    final settings = json['settings'] as Map;
    settings['billing_mode'] = 'blaze';
    settings['billing_account'] = '123456-ABCDEF-123456';
    settings['budget'] = {
      'verified_at': now.toIso8601String(),
      'evidence': 'operator checked authorization and current gross pricing',
      'window_start': now.toIso8601String(),
      'expires_at': now.add(const Duration(hours: 4)).toIso8601String(),
      'maximum_run_usd': 2,
      'maximum_total_usd': 6,
      'funding': funding,
    };
    return RemotePlan(json);
  }

  test('billing mode is explicit and live account must match', () async {
    Map<String, dynamic> billing = {'billingEnabled': false};
    final provider = GcloudProvider(
      execute: (binary, args, {directory, timeout}) async => CommandResult(
        0,
        jsonEncode(
          args.first == 'billing'
              ? billing
              : [
                  {
                    'id': 'test-device',
                    'form': 'PHYSICAL',
                    'supportedVersionIds': ['35'],
                  },
                ],
        ),
        '',
      ),
    );
    await provider.preflight(plan());
    await expectLater(provider.preflight(blazePlan()), throwsStateError);
    billing = {
      'billingEnabled': true,
      'billingAccountName': 'billingAccounts/123456-ABCDEF-123456',
    };
    await provider.preflight(blazePlan());
    await expectLater(provider.preflight(plan()), throwsStateError);
    billing['billingAccountName'] = 'billingAccounts/654321-ABCDEF-123456';
    await expectLater(provider.preflight(blazePlan()), throwsStateError);
  });

  test('Blaze rejects missing, stale, underpriced or unauthorized budgets', () {
    for (final edit in <void Function(Map)>[
      (s) => s.remove('budget'),
      (s) => s['budget']['funding'] = 'assumed_credit',
      (s) => s['budget']['maximum_run_usd'] = 1,
      (s) => s['budget']['maximum_total_usd'] = 1,
      (s) => s['budget']['maximum_total_usd'] = double.nan,
      (s) => s['budget']['maximum_run_usd'] = double.infinity,
      (s) => s['budget']['window_start'] = now
          .add(const Duration(minutes: 1))
          .toIso8601String(),
      (s) => s['budget']['expires_at'] = now
          .add(const Duration(minutes: 59))
          .toIso8601String(),
      (s) => s['budget']['expires_at'] = now
          .add(const Duration(days: 2))
          .toIso8601String(),
      (s) => s['budget']['verified_at'] = now
          .subtract(const Duration(minutes: 16))
          .toIso8601String(),
      (s) => s['credit']['applicable'] = false,
      (s) => s['credit']['available_usd'] = 11.99,
      (s) => s['quota']['remaining_physical'] = 0,
    ]) {
      final json =
          jsonDecode(jsonEncode(blazePlan().json)) as Map<String, dynamic>;
      edit(json['settings'] as Map);
      expect(() => RemotePlan(json).validateBudget(now), throwsStateError);
    }
    blazePlan().validateBudget(now);
    final paid =
        jsonDecode(jsonEncode(blazePlan(funding: 'approved_charges').json))
            as Map<String, dynamic>;
    (paid['settings'] as Map).remove('credit');
    RemotePlan(paid).validateBudget(now);
    for (final edit in <void Function(Map)>[
      (s) => s['billing_mode'] = 'Blaze',
      (s) => s.remove('billing_account'),
      (s) => s['billing_account'] = 'another-account',
    ]) {
      final json =
          jsonDecode(jsonEncode(blazePlan().json)) as Map<String, dynamic>;
      edit(json['settings'] as Map);
      expect(() => RemotePlan(json), throwsFormatException);
    }
  });

  test(
    'Blaze reserves gross cost across runs and keeps Spark count guard',
    () async {
      final provider = FakeProvider();
      final control = controller(provider);
      for (var i = 0; i < 4; i++) {
        expect(
          (await control.run(plan(id: 'qa-spark-$i')))['phase'],
          'COMPLETE',
        );
      }
      expect(
        (await control.run(plan(id: 'qa-spark-five')))['phase'],
        'PREFLIGHT_FAILED',
      );
      for (var i = 0; i < 3; i++) {
        final result = await control.run(blazePlan(id: 'qa-blaze-$i'));
        expect(result['phase'], 'COMPLETE');
        expect(result['reserved_usd_cents'], 200);
      }
      expect(
        (await control.run(blazePlan(id: 'qa-blaze-four')))['phase'],
        'PREFLIGHT_FAILED',
      );
      expect(provider.starts, 7);
    },
  );

  test(
    'Blaze failed dispatch keeps reservation but preflight does not spend it',
    () async {
      final provider = FakeProvider()..preflightFails = true;
      final control = controller(provider);
      await control.run(blazePlan(id: 'qa-preflight'));
      provider.preflightFails = false;
      provider.uncertainStart = true;
      provider.checkpointBeforeFailure = true;
      for (var i = 0; i < 3; i++) {
        final result = await control.run(blazePlan(id: 'qa-failed-$i'));
        expect(result['cleanup'], 'VERIFIED');
        expect(result['dispatched_at'], isNotNull);
      }
      expect(
        (await control.run(blazePlan(id: 'qa-no-budget')))['phase'],
        'PREFLIGHT_FAILED',
      );
      expect(provider.starts, 3);
    },
  );

  test(
    'Blaze persists its rounded reservation before provider mutation',
    () async {
      final json =
          jsonDecode(jsonEncode(blazePlan().json)) as Map<String, dynamic>;
      json['settings']['budget']['maximum_run_usd'] = 2.001;
      final provider = FakeProvider()
        ..onStart = (selected) {
          final saved =
              jsonDecode(
                    File(
                      p.join(runs.path, selected.runId, 'orchestration.json'),
                    ).readAsStringSync(),
                  )
                  as Map;
          expect(saved['phase'], 'SUBMITTING');
          expect(saved['reserved_usd_cents'], 201);
          expect(saved['dispatched_at'], isNotNull);
        };
      expect(
        (await controller(provider).run(RemotePlan(json)))['phase'],
        'COMPLETE',
      );
      expect(provider.starts, 1);
    },
  );

  test(
    'Blaze refuses a prior dispatch whose cost cannot be reconciled',
    () async {
      final provider = FakeProvider();
      final control = controller(provider);
      await control.run(blazePlan());
      final file = File(p.join(runs.path, 'qa-one', 'orchestration.json'));
      final previous = jsonDecode(file.readAsStringSync()) as Map;
      previous.remove('reserved_usd_cents');
      file.writeAsStringSync(jsonEncode(previous));
      expect(
        (await control.run(blazePlan(id: 'qa-two')))['phase'],
        'PREFLIGHT_FAILED',
      );
      expect(provider.starts, 1);
    },
  );

  test('Blaze rechecks receipt freshness after slow preflight', () async {
    var current = now;
    final gate = Completer<void>();
    final provider = FakeProvider()..pausePreflight = gate;
    final control = RemoteController(runs, provider, now: () => current);
    final pending = control.run(blazePlan());
    current = now.add(const Duration(minutes: 16));
    gate.complete();
    expect((await pending)['phase'], 'PREFLIGHT_FAILED');
    expect(provider.starts, 0);
  });

  test(
    'Blaze free allowance supports bounded runs without assuming credit',
    () async {
      final json =
          jsonDecode(jsonEncode(blazePlan(funding: 'free_allowance').json))
              as Map<String, dynamic>;
      final settings = json['settings'] as Map;
      settings.remove('credit');
      settings['test_timeout_minutes'] = 10;
      settings['free_allowance'] = {
        'verified_at': now.toIso8601String(),
        'evidence':
            'all project test process durations checked, rounded per execution',
        'remaining_physical_minutes': 19,
      };
      final provider = FakeProvider();
      final control = controller(provider);
      final result = await control.run(RemotePlan(json));
      expect(result['phase'], 'COMPLETE');
      expect(result['reserved_physical_minutes'], 11);
      json['run_id'] = 'qa-two';
      expect(
        (await control.run(RemotePlan(json)))['phase'],
        'PREFLIGHT_FAILED',
      );
      expect(provider.starts, 1);
      for (final edit in <void Function(Map)>[
        (s) => s.remove('free_allowance'),
        (s) => s['free_allowance']['remaining_physical_minutes'] = 10,
        (s) => s['free_allowance']['remaining_physical_minutes'] = 31,
        (s) => s['free_allowance']['remaining_physical_minutes'] = 19.5,
        (s) => s['free_allowance']['verified_at'] = now
            .subtract(const Duration(minutes: 1))
            .toIso8601String(),
        (s) => s['free_allowance']['verified_at'] = now
            .subtract(const Duration(minutes: 16))
            .toIso8601String(),
      ]) {
        final invalid = jsonDecode(jsonEncode(json)) as Map<String, dynamic>;
        edit(invalid['settings'] as Map);
        expect(() => RemotePlan(invalid).validateBudget(now), throwsStateError);
      }
      for (final minutes in [0, 21, 10.5]) {
        settings['test_timeout_minutes'] = minutes;
        expect(() => RemotePlan(json), throwsFormatException);
      }
    },
  );

  test(
    'concurrent same-ID runs submit once and preserve the journal',
    () async {
      final gate = Completer<void>();
      final provider = FakeProvider()..pausePreflight = gate;
      final first = controller(provider).run(plan());
      try {
        await expectLater(controller(provider).run(plan()), throwsStateError);
      } finally {
        gate.complete();
      }
      await first;
      final file = File(p.join(runs.path, 'qa-one', 'orchestration.json'));
      final before = file.readAsStringSync();
      await expectLater(controller(provider).run(plan()), throwsStateError);
      expect(file.readAsStringSync(), before);
      expect(provider.starts, 1);
    },
  );

  test(
    'lost submission can reconcile and clean up without resubmitting',
    () async {
      final provider = FakeProvider()..uncertainStart = true;
      final control = controller(provider);
      final initial = await control.run(plan());
      expect(initial['cleanup'], 'UNKNOWN');
      final identified = await control.recover(
        'qa-one',
        'reconcile',
        remoteId: 'matrix-one',
      );
      expect((identified['remote'] as Map)['matrix_id'], 'matrix-one');
      expect(identified['qualified'], false);
      expect(identified['error'], isNotNull);
      final clean = await control.recover('qa-one', 'cleanup');
      expect(clean['cleanup'], 'VERIFIED');
      expect(provider.starts, 1);
      await expectLater(
        control.recover('qa-one', 'reconcile', remoteId: 'unrelated'),
        throwsStateError,
      );
      expect(provider.calls.where((call) => call == 'identify'), hasLength(1));
    },
  );

  test(
    'Firebase identity recovery verifies project, ID and unique run label',
    () async {
      Map<String, dynamic> fixture() => {
        'projectId': 'test-project',
        'testMatrixId': 'matrix-one',
        'clientInfo': {
          'clientInfoDetails': [
            {'key': 'matrixLabel', 'value': 'qa-one'},
          ],
        },
      };
      expect(
        (await MatrixProvider(
          fixture(),
        ).identify(plan(), 'matrix-one'))['matrix_id'],
        'matrix-one',
      );
      for (final invalid in [
        fixture()..['projectId'] = 'another-project',
        fixture()..['testMatrixId'] = 'another-matrix',
        fixture()
          ..['clientInfo'] = {
            'clientInfoDetails': [
              {'key': 'matrixLabel', 'value': 'another-run'},
            ],
          },
        fixture()..['clientInfo'] = {'clientInfoDetails': []},
      ]) {
        await expectLater(
          MatrixProvider(invalid).identify(plan(), 'matrix-one'),
          throwsStateError,
        );
      }
    },
  );

  test(
    'Firebase async URL receipts recover an owned Android or iOS matrix',
    () async {
      for (final target in ['firebase-android', 'firebase-ios']) {
        for (final timeoutMinutes in [10, 20]) {
          final calls = <List<String>>[];
          final checkpoints = <Map<String, dynamic>>[];
          final provider = MatrixProvider(
            {
              'projectId': 'test-project',
              'testMatrixId': 'matrix-one',
              'clientInfo': {
                'clientInfoDetails': [
                  {'key': 'matrixLabel', 'value': 'qa-one'},
                ],
              },
            },
            execute: (binary, args, {directory, timeout}) async {
              calls.add(args);
              return CommandResult(
                0,
                jsonEncode(
                  'https://console.firebase.google.com/project/test-project/testlab/histories/history/matrices/execution',
                ),
                'Uploading test files...\nTest [matrix-one] has been created in the Google Cloud.\n',
              );
            },
          );
          final selected =
              jsonDecode(jsonEncode(plan(target: target).json))
                  as Map<String, dynamic>;
          selected['settings']['test_timeout_minutes'] = timeoutMinutes;
          final remote = await provider.start(
            RemotePlan(selected),
            checkpoints.add,
          );
          expect(remote['matrix_id'], 'matrix-one');
          expect(checkpoints.first, {'submission_candidate_id': 'matrix-one'});
          expect(checkpoints.last['matrix_id'], 'matrix-one');
          expect(calls, hasLength(1));
          expect(calls.single, contains('--async'));
          expect(calls.single, contains('--num-flaky-test-attempts=0'));
          expect(calls.single, contains('--timeout=${timeoutMinutes}m'));
          expect(
            calls.single.where((arg) => arg.startsWith('--device=')),
            hasLength(1),
          );
        }
      }
    },
  );

  test(
    'Firebase submission rejects ambiguous receipts and foreign ownership',
    () async {
      for (final receipt in [
        '',
        'Test [matrix-one] has been created in the Google Cloud.\nTest [matrix-two] has been created in the Google Cloud.\n',
        'Test [matrix-one] has been created in the Google Cloud.\n',
      ]) {
        final checkpoints = <Map<String, dynamic>>[];
        final provider = MatrixProvider(
          {
            'projectId': 'another-project',
            'testMatrixId': 'matrix-one',
            'clientInfo': {
              'clientInfoDetails': [
                {'key': 'matrixLabel', 'value': 'qa-one'},
              ],
            },
          },
          execute: (binary, args, {directory, timeout}) async => CommandResult(
            0,
            jsonEncode('https://console.firebase.google.com/'),
            receipt,
          ),
        );
        await expectLater(
          provider.start(plan(), checkpoints.add),
          throwsStateError,
        );
        expect(
          checkpoints.where((value) => value.containsKey('matrix_id')),
          isEmpty,
        );
      }
    },
  );

  test(
    'Firebase saves verified identity when gcloud fails after creation',
    () async {
      final checkpoints = <Map<String, dynamic>>[];
      final provider = MatrixProvider(
        {
          'projectId': 'test-project',
          'testMatrixId': 'matrix-one',
          'clientInfo': {
            'clientInfoDetails': [
              {'key': 'matrixLabel', 'value': 'qa-one'},
            ],
          },
        },
        execute: (binary, args, {directory, timeout}) async =>
            const CommandResult(
              1,
              '',
              'Test [matrix-one] has been created in the Google Cloud.\n',
            ),
      );
      await expectLater(
        provider.start(plan(), checkpoints.add),
        throwsStateError,
      );
      expect(checkpoints.last['matrix_id'], 'matrix-one');
    },
  );

  test(
    'NPU bundles are blocked before provider preflight or submission',
    () async {
      const id = 'npu-qualcomm-sm8650';
      File(
        'packages/llamadart_validation/assets/profiles/$id.json',
      ).copySync(p.join(bundle.path, 'profile.json'));
      await writeBundleManifest(bundle, {
        'target': 'android',
        'profile': id,
        'source_dirty': false,
      });
      final provider = FakeProvider();
      final controller = RemoteController(runs, provider, now: () => now);
      final result = await controller.run(plan(profile: id));
      expect(result['qualified'], isNot(true));
      expect(result['error'], contains('StateError'));
      expect(provider.calls, isEmpty);
      expect(provider.starts, 0);
    },
  );

  test('SIGTERM on the command host terminates owned descendants', () async {
    if (Platform.isWindows) {
      return;
    }
    final ready = File(p.join(scratch.path, 'ready'));
    final leaked = File(p.join(scratch.path, 'leaked'));
    final script =
        'from pathlib import Path; import time; '
        'Path(${jsonEncode(ready.path)}).write_text("ready"); '
        'time.sleep(1); Path(${jsonEncode(leaked.path)}).write_text("leaked")';
    final host = await Process.start('python3', [
      'tool/testing/validation/process_host.py',
      '30',
      'python3',
      '-c',
      script,
    ]);
    final out = host.stdout.drain<void>();
    final err = host.stderr.drain<void>();
    try {
      for (var i = 0; i < 100 && !ready.existsSync(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(ready.existsSync(), true);
      host.kill(ProcessSignal.sigterm);
      expect(await host.exitCode.timeout(const Duration(seconds: 3)), 143);
      await Future.wait([out, err]);
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(leaked.existsSync(), false);
    } finally {
      host.kill(ProcessSignal.sigkill);
    }
  });

  test(
    'successful lifecycle requires provider, suite, retrieval and cleanup',
    () async {
      final provider = FakeProvider();
      final result = await controller(provider).run(plan());
      expect(result['qualified'], true);
      expect(provider.calls, [
        'preflight',
        'start',
        'status',
        'collect',
        'cleanup',
      ]);
      expect(
        File(p.join(runs.path, 'qa-one', 'cleanup.json')).existsSync(),
        true,
      );
    },
  );
  test('provider failure remains failed even with a passing suite', () async {
    final provider = FakeProvider()..successful = false;
    final result = await controller(provider).run(plan());
    expect(result['qualified'], false);
    expect(result['phase'], 'FAILED');
  });
  test('missing assertions cannot be replaced by provider success', () async {
    final result = await controller(FakeProvider(), pass: false).run(plan());
    expect(result['qualified'], false);
  });
  test('preflight failure performs no mutation', () async {
    final provider = FakeProvider()..preflightFails = true;
    final result = await controller(provider).run(plan());
    expect(provider.starts, 0);
    expect(result['cleanup'], 'NOT_REQUIRED');
  });
  test('unknown submission is not retried and blocks a fresh run', () async {
    final provider = FakeProvider()..uncertainStart = true;
    final control = controller(provider);
    expect((await control.run(plan()))['cleanup'], 'UNKNOWN');
    expect(
      (await control.run(plan(id: 'qa-two')))['phase'],
      'PREFLIGHT_FAILED',
    );
    expect(provider.starts, 1);
    await expectLater(control.run(plan()), throwsStateError);
  });
  test(
    'early checkpoint survives bootstrap failure and collects before cleanup',
    () async {
      final provider = FakeProvider()
        ..uncertainStart = true
        ..checkpointBeforeFailure = true;
      final result = await controller(provider).run(plan());
      expect(provider.cleanupRemote?['matrix_id'], 'matrix-one');
      expect(provider.calls, ['preflight', 'start', 'collect', 'cleanup']);
      expect(result['qualified'], false);
      expect(result['cleanup'], 'VERIFIED');
    },
  );
  test('collection failure still cleans up and stays failed', () async {
    final provider = FakeProvider()..collectionFails = true;
    final result = await controller(provider).run(plan());
    expect(provider.calls.last, 'cleanup');
    expect(result['qualified'], false);
    expect(result['collection'], 'INCOMPLETE');
  });
  test(
    'recovery never submits and cleanup failure blocks replacement',
    () async {
      final provider = FakeProvider()..cleanupVerified = false;
      final control = controller(provider);
      await control.run(plan());
      await control.recover('qa-one', 'status');
      expect(
        (await control.run(plan(id: 'qa-two')))['phase'],
        'PREFLIGHT_FAILED',
      );
      provider.cleanupVerified = true;
      expect(
        (await control.recover('qa-one', 'cleanup'))['cleanup'],
        'VERIFIED',
      );
      expect(provider.starts, 1);
    },
  );
  test('stale credit and insufficient quota fail locally', () {
    expect(
      () => plan(
        target: 'gce-linux-cuda',
      ).validateBudget(now.add(const Duration(minutes: 16))),
      throwsStateError,
    );
    final json = jsonDecode(jsonEncode(plan().json)) as Map<String, dynamic>;
    (json['settings']['quota'] as Map)['remaining_physical'] = 0;
    expect(() => RemotePlan(json).validateBudget(now), throwsStateError);
  });
  test(
    'altered bundle and mobile profile mismatch fail before provider',
    () async {
      final provider = FakeProvider();
      final selected = plan();
      File(p.join(bundle.path, 'app.apk')).writeAsStringSync('changed');
      expect(
        (await controller(provider).run(selected))['phase'],
        'PREFLIGHT_FAILED',
      );
      await writeBundleManifest(bundle, {
        'target': 'android',
        'profile': 'tiny-gguf-cpu',
      });
      expect(
        (await controller(
          provider,
        ).run(plan(id: 'qa-two', profile: 'tiny-gguf-cuda')))['phase'],
        'PREFLIGHT_FAILED',
      );
      expect(provider.calls, isEmpty);
    },
  );
  test(
    'wrong desktop OS and CPU profile on CUDA target fail before provisioning',
    () async {
      final provider = FakeProvider();
      await writeBundleManifest(bundle, {
        'target': 'desktop',
        'source_dirty': false,
        'build_os': 'macos',
        'build_abi': 'macos_arm64',
      });
      expect(
        (await controller(
          provider,
        ).run(plan(target: 'gce-linux-cuda')))['phase'],
        'PREFLIGHT_FAILED',
      );
      final assets = Directory(p.join(bundle.path, 'assets/profiles'))
        ..createSync(recursive: true);
      File(
        p.join(bundle.path, 'profile.json'),
      ).copySync(p.join(assets.path, 'tiny-gguf-cpu.json'));
      await writeBundleManifest(bundle, {
        'target': 'desktop',
        'source_dirty': false,
        'build_os': 'linux',
        'build_abi': 'linux_x64',
      });
      expect(
        (await controller(
          provider,
        ).run(plan(id: 'qa-two', target: 'gce-linux-cuda')))['phase'],
        'PREFLIGHT_FAILED',
      );
      expect(provider.calls, isEmpty);
    },
  );
  test(
    'uncertain GCE creation cannot be cleared by an empty inventory',
    () async {
      final provider = GcloudProvider(
        execute: (binary, args, {directory, timeout}) async =>
            const CommandResult(0, '[]', ''),
      );
      expect(
        (await provider.cleanup(
          plan(target: 'gce-linux-cuda'),
          {},
        ))['verified'],
        false,
      );
    },
  );
  test('cleanup refuses a changed or auxiliary boot disk', () async {
    final calls = <List<String>>[];
    final provider = GcloudProvider(
      execute: (binary, args, {directory, timeout}) async {
        calls.add(args);
        return CommandResult(
          0,
          jsonEncode([
            {
              'id': '123',
              'labels': {'llamadart-validation': 'qa-one'},
              'zone':
                  'https://compute.googleapis.com/compute/v1/projects/test-project/zones/us-central1-a',
              'disks': [
                {
                  'boot': true,
                  'autoDelete': true,
                  'source':
                      'projects/test-project/zones/us-central1-a/disks/valuable-data',
                },
              ],
            },
          ]),
          '',
        );
      },
    );
    expect(
      (await provider.cleanup(plan(target: 'gce-linux-cuda'), {
        'instance_id': '123',
        'creation_confirmed': true,
        'disks': [
          'projects/test-project/zones/us-central1-a/disks/valuable-data',
        ],
      }))['verified'],
      false,
    );
    expect(calls.any((c) => c.contains('delete')), false);
  });
  test(
    'total process deadline includes inherited pipes and kills descendants',
    () async {
      if (Platform.isWindows) return; // Windows job behavior runs in bundle CI.
      final marker = p.join(scratch.path, 'should-not-exist');
      final code =
          'import subprocess,sys; subprocess.Popen([sys.executable,"-c",${jsonEncode('import time; from pathlib import Path; time.sleep(1); Path(${jsonEncode(marker)}).write_text("leaked")')}])';
      final watch = Stopwatch()..start();
      await expectLater(
        executeCommand('python3', [
          '-c',
          code,
        ], timeout: const Duration(milliseconds: 100)),
        throwsA(isA<TimeoutException>()),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(File(marker).existsSync(), false);
    },
  );
}
