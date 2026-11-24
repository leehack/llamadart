@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../../tool/testing/validation/bundle.dart';
import '../../../tool/testing/validation/process.dart';
import '../../../tool/testing/validation/remote.dart';

void main() {
  late Directory root;
  late File model;
  late Directory bundle;
  late List<List<String>> commands;
  const profile = 'gemma4-litert-gpu';
  const filename = 'gemma-4-E2B-it.litertlm';
  const payload = 'staged-model.litertlm';
  const modelBytes = [1, 3, 5, 7];
  final digest = sha256.convert(modelBytes).toString();

  File fixture(String path) {
    final file = File(p.join(root.path, path));
    file.parent.createSync(recursive: true);
    return file;
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('android-staged-model-test-');
    addTearDown(() => root.deleteSync(recursive: true));
    commands = [];
    for (final path in [
      '.flutter-version',
      'hook/build.dart',
      'lib/src/hook/native_release_pins.dart',
      'scripts/fetch_webgpu_bridge_assets.sh',
    ]) {
      File(path).copySync(fixture(path).path);
    }
    final profilePath =
        'packages/llamadart_validation/assets/profiles/$profile.json';
    final data = jsonDecode(File(profilePath).readAsStringSync()) as Map;
    (data['model'] as Map<String, dynamic>).addAll({
      'sha256': digest,
      'bytes': modelBytes.length,
    });
    fixture(profilePath).writeAsStringSync(jsonEncode(data));
    fixture('packages/llamadart_validation/pubspec.lock').createSync();
    fixture('example/chat_app/pubspec.lock').createSync();
    fixture('jdk/bin/${Platform.isWindows ? 'java.exe' : 'java'}').createSync();
    model = fixture('private source, never persisted/original.litertlm')
      ..writeAsBytesSync(modelBytes);
    bundle = Directory(p.join(root.path, 'bundle'));
  });

  Future<Directory> build({bool stage = true}) => buildValidationBundle(
    root.path,
    'android',
    bundle.path,
    profile: profile,
    model: stage ? model.path : null,
    execute: (binary, args, {directory, timeout, environment}) async {
      commands.add(args);
      if (binary == 'git') {
        return CommandResult(0, args.first == 'rev-parse' ? 'a' * 40 : '', '');
      }
      switch (args.first) {
        case '--version':
          return CommandResult(
            0,
            jsonEncode({
              'frameworkVersion': fixture(
                '.flutter-version',
              ).readAsStringSync().trim(),
              'dartSdkVersion': Platform.version,
            }),
            '',
          );
        case 'config':
          return CommandResult(
            0,
            jsonEncode({'jdk-dir': p.join(root.path, 'jdk')}),
            '',
          );
        case 'pub':
          return const CommandResult(0, '', '');
        case 'build':
          fixture(
            'example/chat_app/build/app/outputs/flutter-apk/app-debug.apk',
          ).writeAsStringSync(args.join('\n'));
          return const CommandResult(0, '', '');
        case 'app:assembleAndroidTest':
          fixture(
            'example/chat_app/build/app/outputs/apk/androidTest/debug/app-debug-androidTest.apk',
          ).writeAsStringSync(args.join('\n'));
          return const CommandResult(0, '', '');
      }
      throw StateError('Unexpected build command');
    },
  );

  Map<String, dynamic> planJson() => {
    'schema_version': 1,
    'run_id': 'qa-stage-model',
    'target': 'firebase-android',
    'profile': profile,
    'project': 'test-project',
    'account': 'tester@example.com',
    'bundle': bundle.path,
    'android_staged_model': true,
    'bundle_sha256': sha256
        .convert(
          File(p.join(bundle.path, 'bundle-manifest.json')).readAsBytesSync(),
        )
        .toString(),
    'settings': {'device_model': 'caiman', 'device_version': '35'},
  };

  test('Android build seals and submits the exact locked private payload', () async {
    await build();
    final manifest = await verifyBundle(bundle);
    expect(File(p.join(bundle.path, payload)).readAsBytesSync(), modelBytes);
    expect((manifest['files'] as Map)[payload], {
      'sha256': digest,
      'bytes': modelBytes.length,
    });
    expect(jsonEncode(manifest), isNot(contains(model.path)));
    const define = 'VALIDATION_ANDROID_STAGED_MODEL=true';
    expect(
      File(p.join(bundle.path, 'qa-app.apk')).readAsStringSync(),
      isNot(contains(define)),
    );
    expect(
      File(p.join(bundle.path, 'app.apk')).readAsStringSync(),
      contains('--dart-define=$define'),
    );
    expect(
      File(p.join(bundle.path, 'test.apk')).readAsStringSync(),
      contains(base64Encode(utf8.encode(define))),
    );

    final plan = RemotePlan(planJson());
    final submitted = <List<String>>[];
    final provider = GcloudProvider(
      execute: (binary, args, {directory, timeout, environment}) async {
        if (args.first == 'auth') {
          return const CommandResult(0, 'mock-token', '');
        }
        expect(directory, bundle.path);
        submitted.add(args);
        return const CommandResult(
          0,
          '',
          'Test [matrix-one] has been created in the Google Cloud.\n',
        );
      },
      createHttpClient: () => throw StateError('mock matrix lookup'),
    );
    await expectLater(provider.start(plan, (_) {}), throwsStateError);
    expect(
      submitted.single,
      containsAll([
        '--test-targets=class com.example.llamadart_chat_example.MainActivityTest',
        '--other-files=/data/local/tmp/llamadart-validation-model.litertlm=$payload',
        '--environment-variables=validationStageModelName=$filename,validationStageModelSha256=$digest,validationStageModelBytes=${modelBytes.length}',
      ]),
    );

    File(p.join(bundle.path, payload)).writeAsBytesSync([0, 3, 5, 7]);
    await expectLater(verifyBundle(bundle), throwsA(anything));
    await expectLater(writeBundleManifest(bundle, manifest), throwsStateError);
    final forgedFile = (manifest['files'] as Map)[payload] as Map;
    forgedFile['sha256'] = sha256.convert([0, 3, 5, 7]).toString();
    File(
      p.join(bundle.path, 'bundle-manifest.json'),
    ).writeAsStringSync(jsonEncode(manifest));
    await expectLater(verifyBundle(bundle), throwsStateError);
    expect(
      () => requireRemoteBundleTarget(
        RemotePlan(planJson()..remove('android_staged_model')),
        manifest,
      ),
      throwsStateError,
    );
  });

  for (final (name, bytes) in [
    ('wrong digest at the locked size', [0, 3, 5, 7]),
    ('wrong size', [1, 3, 5]),
  ]) {
    test('Android build rejects $name before building an APK', () async {
      model.writeAsBytesSync(bytes);
      await expectLater(build(), throwsStateError);
      expect(commands.where((args) => args.first == 'build'), isEmpty);
      expect(bundle.existsSync(), isFalse);
    });
  }

  test(
    'download bundle carries no staging payload or instrumentation opt-in',
    () async {
      await build(stage: false);
      final manifest = await verifyBundle(bundle);
      expect((manifest['files'] as Map).containsKey(payload), isFalse);
      expect(
        File(p.join(bundle.path, 'app.apk')).readAsStringSync(),
        isNot(contains('VALIDATION_ANDROID_STAGED_MODEL')),
      );
    },
  );
}
