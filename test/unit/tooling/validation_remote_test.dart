@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../../tool/testing/validation/bundle.dart';
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
        final remote = await provider.start(
          plan(target: target),
          checkpoints.add,
        );
        expect(remote['matrix_id'], 'matrix-one');
        expect(checkpoints.first, {'submission_candidate_id': 'matrix-one'});
        expect(checkpoints.last['matrix_id'], 'matrix-one');
        expect(calls, hasLength(1));
        expect(calls.single, contains('--async'));
        expect(calls.single, contains('--num-flaky-test-attempts=0'));
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
