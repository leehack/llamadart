@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:llamadart/src/core/image/png_encoder.dart';
import 'package:llamadart/src/hook/native_release_pins.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../../example/chat_app/integration_test/support/image_evidence.dart';
import '../../../tool/testing/validation/bundle.dart';
import '../../../tool/testing/validation/collect.dart';
import '../../../tool/testing/validation/image_profile.dart';
import '../../../tool/testing/validation/process.dart';
import '../../../tool/testing/validation/remote.dart';

const _package = 'packages/llamadart_validation';
const _commit = 'd3351a49ef3b55e7ff312af7636e62d29f020af9';

Map<String, dynamic> _profile(String id) =>
    jsonDecode(
          File('$_package/assets/image_profiles/$id.json').readAsStringSync(),
        )
        as Map<String, dynamic>;

Map<String, dynamic> _copy(Map<String, dynamic> value) =>
    jsonDecode(jsonEncode(value)) as Map<String, dynamic>;

/// Rejects every submission at preflight and records whether it got there,
/// so a test observes the upload boundary without a provider.
class _PreflightProbe implements RemoteProvider {
  int preflights = 0;
  @override
  Future<void> preflight(RemotePlan plan) async {
    preflights++;
    throw StateError('stop before submission');
  }

  @override
  Future<Map<String, dynamic>> identify(RemotePlan plan, String remoteId) =>
      throw UnimplementedError();
  @override
  Future<Map<String, dynamic>> start(
    RemotePlan plan,
    void Function(Map<String, dynamic>) checkpoint,
  ) => throw UnimplementedError();
  @override
  Future<Map<String, dynamic>> status(
    RemotePlan plan,
    Map<String, dynamic> remote,
  ) => throw UnimplementedError();
  @override
  Future<void> collect(
    RemotePlan plan,
    Map<String, dynamic> remote,
    Directory output,
  ) => throw UnimplementedError();
  @override
  Future<Map<String, dynamic>> cleanup(
    RemotePlan plan,
    Map<String, dynamic> remote,
  ) => throw UnimplementedError();
}

class _OwnedMatrix extends GcloudProvider {
  _OwnedMatrix({super.execute});
  @override
  Future<Map<String, dynamic>> matrix(
    RemotePlan plan,
    String id, {
    bool cancel = false,
  }) async => {
    'projectId': plan.project,
    'testMatrixId': id,
    'clientInfo': {
      'clientInfoDetails': [
        {'key': 'matrixLabel', 'value': plan.runId},
      ],
    },
  };
}

void main() {
  final now = DateTime.utc(2026, 10, 14, 12);
  late Directory scratch;
  late Directory bundle;
  setUp(() {
    scratch = Directory.systemTemp.createTempSync('validation-image-test-');
    bundle = Directory(p.join(scratch.path, 'bundle'))..createSync();
  });
  tearDown(() => scratch.deleteSync(recursive: true));

  Future<void> sealBundle(
    String id, {
    Map<String, Object?> overrides = const {},
    void Function(Map<String, dynamic> profile)? editProfile,
  }) async {
    // The builder records the execution path in the bundled copy.
    final profile = {..._profile(id), 'execution_path': 'public_api'};
    editProfile?.call(profile);
    File(
      p.join(bundle.path, 'profile.json'),
    ).writeAsStringSync(jsonEncode(profile));
    final target = profile['backend'] == 'metal' ? 'ios' : 'android';
    File(
      p.join(bundle.path, target == 'ios' ? 'tests.zip' : 'app.apk'),
    ).writeAsStringSync('payload');
    await writeBundleManifest(bundle, {
      'source_commit': _commit,
      'source_dirty': false,
      'target': target,
      'profile': id,
      'test_target': imageGenerationTestTarget,
      'stable_diffusion_tag': stableDiffusionReleaseTag,
      ...overrides,
    });
  }

  RemotePlan plan(String id, {String? target, Directory? sealed}) =>
      RemotePlan({
        'schema_version': 1,
        'run_id': 'qa-image',
        'target':
            target ??
            (id.endsWith('metal') ? 'firebase-ios' : 'firebase-android'),
        'project': 'test-project',
        'account': 'tester@example.com',
        'profile': id,
        'bundle': (sealed ?? bundle).path,
        'bundle_sha256': sha256
            .convert(
              File(
                p.join((sealed ?? bundle).path, 'bundle-manifest.json'),
              ).readAsBytesSync(),
            )
            .toString(),
        'settings': {
          'device_model': 'SC-51E',
          'device_version': '36',
          'quota': {
            'verified_at': now.toIso8601String(),
            'remaining_physical': 1,
            'evidence': 'checked console',
          },
        },
      });

  group('image-generation profiles', () {
    test('lock exactly the chat app SDXS model for one mobile target', () {
      for (final (id, target) in [
        ('image-sdxs-cpu', 'android'),
        ('image-sdxs-metal', 'ios'),
      ]) {
        final profile = _profile(id);
        expect(profile['id'], id);
        expect(isImageGenerationProfile(profile), isTrue);
        expect(
          () => requireImageGenerationProfile(profile, target),
          returnsNormally,
        );
        expect(
          () => requireImageGenerationProfile({
            ...profile,
            'execution_path': 'public_api',
          }, target),
          returnsNormally,
          reason: 'bundled copy',
        );
        for (final other in ['android', 'ios', 'desktop', 'web']) {
          if (other == target) continue;
          expect(
            () => requireImageGenerationProfile(profile, other),
            throwsUnsupportedError,
            reason: '$id on $other',
          );
        }
      }
    });

    test('reject a changed lock, kind, backend or shape', () {
      final base = _profile('image-sdxs-cpu');
      final mutations = <String, void Function(Map<String, dynamic>)>{
        'sha256': (v) => v['model']['sha256'] = 'f' * 64,
        'bytes': (v) => v['model']['bytes'] = 682847201,
        'revision': (v) => v['model']['revision'] = 'a' * 40,
        'url': (v) => v['model']['url'] = 'https://example.com/sdxs.gguf',
        'model id': (v) => v['model']['id'] = 'sd-turbo-q8_0-taesd',
        'kind': (v) => v['model']['kind'] = 'raw',
        'extra model key': (v) => v['model']['access'] = 'public',
        'missing model key': (v) => (v['model'] as Map).remove('url'),
        'extra key': (v) => v['fixtures'] = <String, Object>{},
        'runtime': (v) => v['runtime'] = 'gguf',
        'schema': (v) => v['schema_version'] = 2,
        'id': (v) => v['id'] = 'Image',
        'native path': (v) => v['execution_path'] = 'native_c_api',
      };
      for (final entry in mutations.entries) {
        final changed = _copy(base);
        entry.value(changed);
        expect(
          () => requireImageGenerationProfile(changed, 'android'),
          throwsFormatException,
          reason: entry.key,
        );
      }
      expect(
        () => requireImageGenerationProfile(
          _copy(base)..['backend'] = 'vulkan',
          'android',
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('no device route'),
          ),
        ),
      );
    });

    test('share no ID with text profiles and resolve by ID', () {
      final text = Directory(
        '$_package/assets/profiles',
      ).listSync().map((f) => p.basename(f.path)).toSet();
      final image = Directory(
        '$_package/assets/image_profiles',
      ).listSync().map((f) => p.basename(f.path)).toSet();
      expect(image, {'image-sdxs-cpu.json', 'image-sdxs-metal.json'});
      expect(text.intersection(image), isEmpty);
      expect(
        p.split(validationProfileFile(_package, 'image-sdxs-cpu').path),
        containsAllInOrder(['image_profiles', 'image-sdxs-cpu.json']),
      );
      expect(
        p.split(validationProfileFile(_package, 'tiny-gguf-cpu').path),
        containsAllInOrder(['profiles', 'tiny-gguf-cpu.json']),
      );
      expect(
        () => validationProfileFile(_package, 'image-sdxs-vulkan'),
        throwsFormatException,
      );
      final both = p.join(scratch.path, 'package');
      for (final directory in ['profiles', 'image_profiles']) {
        File(p.join(both, 'assets', directory, 'twin.json'))
          ..createSync(recursive: true)
          ..writeAsStringSync('{}');
      }
      expect(
        () => validationProfileFile(both, 'twin'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('both a text and an image profile'),
          ),
        ),
      );
    });
  });

  group('bundle build', () {
    late String root;
    late List<(String, List<String>, String?)> commands;

    setUp(() {
      root = p.join(scratch.path, 'checkout');
      for (final path in [
        '.flutter-version',
        'hook/build.dart',
        'lib/src/hook/native_release_pins.dart',
        'scripts/fetch_webgpu_bridge_assets.sh',
        '$_package/pubspec.lock',
        '$_package/assets/profiles/tiny-gguf-cpu.json',
        '$_package/assets/image_profiles/image-sdxs-cpu.json',
        '$_package/assets/image_profiles/image-sdxs-metal.json',
        'example/chat_app/pubspec.lock',
        'example/chat_app/ios/Runner.xcodeproj/project.pbxproj',
      ]) {
        final target = File(p.join(root, path));
        target.parent.createSync(recursive: true);
        File(path).copySync(target.path);
      }
      commands = [];
    });

    Future<CommandResult> fake(
      String binary,
      List<String> args, {
      String? directory,
      Duration? timeout,
    }) async {
      commands.add((binary, args, directory));
      if (binary == 'git') {
        return CommandResult(0, args.first == 'rev-parse' ? _commit : '', '');
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
      final outputs = p.join(root, 'example/chat_app/build/app/outputs');
      final built = [
        if (binary == 'flutter' && args.take(2).join(' ') == 'build apk')
          p.join(outputs, 'flutter-apk', 'app-debug.apk'),
        if (binary.endsWith('gradlew') || binary.endsWith('gradlew.bat')) ...[
          p.join(outputs, 'flutter-apk', 'app-debug.apk'),
          p.join(
            outputs,
            'apk',
            'androidTest',
            'debug',
            'app-debug-androidTest.apk',
          ),
        ],
        if (binary == 'zip') args[1],
      ];
      for (final path in built) {
        File(path)
          ..createSync(recursive: true)
          ..writeAsStringSync(args.join(' '));
      }
      return const CommandResult(0, '', '');
    }

    List<String> defines(List<String> args) => [
      for (final arg in args)
        if (arg.startsWith('--dart-define=')) arg.substring(14),
    ];

    test(
      'Android compiles the image test with the exact clean source defines',
      () async {
        final output = p.join(scratch.path, 'android');
        await buildValidationBundle(
          root,
          'android',
          output,
          profile: 'image-sdxs-cpu',
          execute: fake,
        );
        final builds = [
          for (final (binary, args, _) in commands)
            if (binary == 'flutter' && args.first == 'build') args,
        ];
        expect(builds, hasLength(1), reason: 'no interactive qa-app build');
        final apk = builds.single;
        expect(apk[apk.indexOf('--target') + 1], imageGenerationTestTarget);
        expect(
          defines(apk),
          containsAll([
            'VALIDATION_COMMIT=$_commit',
            'VALIDATION_SOURCE_DIRTY=false',
            'VALIDATION_PROFILE=image-sdxs-cpu',
          ]),
        );
        final gradle = commands
            .singleWhere((command) => command.$1.contains('gradlew'))
            .$2;
        expect(gradle, contains('-Ptarget=$imageGenerationTestTarget'));
        final encoded = gradle
            .singleWhere((arg) => arg.startsWith('-Pdart-defines='))
            .substring('-Pdart-defines='.length)
            .split(',')
            .map((value) => utf8.decode(base64Decode(value)))
            .toList();
        expect(encoded, defines(apk));
        expect(File(p.join(output, 'qa-app.apk')).existsSync(), isFalse);
        expect(
          File(p.join(output, 'app.apk')).readAsStringSync(),
          gradle.join(' '),
        );
        final manifest = await verifyBundle(Directory(output));
        expect(manifest['profile'], 'image-sdxs-cpu');
        expect(manifest['source_commit'], _commit);
        expect(manifest['source_dirty'], isFalse);
        expect(manifest['test_target'], imageGenerationTestTarget);
        expect(manifest['stable_diffusion_tag'], stableDiffusionReleaseTag);
        expect(
          jsonDecode(File(p.join(output, 'profile.json')).readAsStringSync()),
          {..._profile('image-sdxs-cpu'), 'execution_path': 'public_api'},
        );
        final probe = _PreflightProbe();
        await RemoteController(
          Directory(p.join(scratch.path, 'runs')),
          probe,
          now: () => now,
          delay: (_) async {},
        ).run(plan('image-sdxs-cpu', sealed: Directory(output)));
        expect(probe.preflights, 1, reason: 'the upload check accepts it');
      },
    );

    test('text Android bundles keep the shared validation test', () async {
      final output = p.join(scratch.path, 'text');
      await buildValidationBundle(root, 'android', output, execute: fake);
      final targets = [
        for (final (binary, args, _) in commands)
          if (binary == 'flutter' && args.first == 'build')
            args[args.indexOf('--target') + 1],
      ];
      expect(targets, [
        'lib/validation_main.dart',
        'integration_test/validation_test.dart',
      ]);
      expect(
        commands.singleWhere((c) => c.$1.contains('gradlew')).$2,
        contains('-Ptarget=integration_test/validation_test.dart'),
      );
      final manifest = await verifyBundle(Directory(output));
      expect(manifest.containsKey('stable_diffusion_tag'), isFalse);
      expect(File(p.join(output, 'qa-app.apk')).existsSync(), isTrue);
    });

    test(
      'iOS compiles the image test with the exact clean source defines',
      () async {
        await buildValidationBundle(
          root,
          'ios',
          p.join(scratch.path, 'ios'),
          profile: 'image-sdxs-metal',
          execute: fake,
        );
        final config = commands
            .singleWhere(
              (command) =>
                  command.$1 == 'flutter' &&
                  command.$2.contains('--config-only'),
            )
            .$2;
        expect(
          config[config.indexOf('--target') + 1],
          imageGenerationTestTarget,
        );
        expect(
          defines(config),
          containsAll([
            'VALIDATION_COMMIT=$_commit',
            'VALIDATION_SOURCE_DIRTY=false',
          ]),
        );
      },
      skip: Platform.isMacOS ? false : 'Signing XCTest requires macOS/Xcode',
    );

    test('mismatched targets and extra inputs fail before any build', () async {
      for (final (target, profile, kit) in [
        ('ios', 'image-sdxs-cpu', null),
        ('android', 'image-sdxs-metal', null),
        ('desktop', 'image-sdxs-cpu', null),
        ('web', 'image-sdxs-cpu', null),
        ('android', 'image-sdxs-cpu', p.join(scratch.path, 'kit')),
      ]) {
        await expectLater(
          buildValidationBundle(
            root,
            target,
            p.join(scratch.path, 'rejected'),
            profile: profile,
            npuKit: kit,
            execute: fake,
          ),
          throwsA(anyOf(isUnsupportedError, isFormatException)),
          reason: '$target $profile $kit',
        );
      }
      expect(commands, isEmpty);
      expect(Directory(p.join(scratch.path, 'rejected')).existsSync(), false);
    });
  });

  group('Firebase upload', () {
    Future<Map<String, dynamic>> submit(RemotePlan selected) async {
      final probe = _PreflightProbe();
      final state = await RemoteController(
        Directory(p.join(scratch.path, 'runs')),
        probe,
        now: () => now,
        delay: (_) async {},
      ).run(selected);
      return {...state, 'preflights': probe.preflights};
    }

    test('accepts an image bundle only with its test target and pin', () async {
      await sealBundle('image-sdxs-cpu');
      expect((await submit(plan('image-sdxs-cpu')))['preflights'], 1);
      for (final (index, overrides) in [
        {'test_target': 'integration_test/validation_test.dart'},
        {'stable_diffusion_tag': null},
      ].indexed) {
        await sealBundle('image-sdxs-cpu', overrides: overrides);
        final selected = RemotePlan({
          ...plan('image-sdxs-cpu').json,
          'run_id': 'qa-image-$index',
        });
        final state = await submit(selected);
        expect(state['phase'], 'PREFLIGHT_FAILED', reason: '$overrides');
        expect(state['preflights'], 0, reason: '$overrides');
      }
    });

    test('rejects a bundled image profile with a changed model lock', () async {
      await sealBundle(
        'image-sdxs-cpu',
        editProfile: (profile) => profile['model']['sha256'] = 'f' * 64,
      );
      final state = await submit(plan('image-sdxs-cpu'));
      expect(state['phase'], 'PREFLIGHT_FAILED');
      expect(state['preflights'], 0);
    });

    test('rejects a cpu image profile inside an iOS bundle', () async {
      await sealBundle('image-sdxs-cpu', overrides: {'target': 'ios'});
      final state = await submit(
        plan('image-sdxs-cpu', target: 'firebase-ios'),
      );
      expect(state['phase'], 'PREFLIGHT_FAILED');
      expect(state['preflights'], 0);
    });

    test('pulls the image evidence directory on Android', () async {
      Future<List<String>> pulls(String id) async {
        final calls = <List<String>>[];
        await _OwnedMatrix(
          execute: (binary, args, {directory, timeout}) async {
            calls.add(args);
            return const CommandResult(
              0,
              '',
              'Test [matrix-one] has been created in the Google Cloud.\n',
            );
          },
        ).start(
          plan(
            id,
            target: id.endsWith('metal') ? 'firebase-ios' : 'firebase-android',
          ),
          (_) {},
        );
        return [
          for (final arg in calls.single)
            if (arg.startsWith('--directories-to-pull=')) arg,
        ];
      }

      await sealBundle('image-sdxs-cpu');
      expect(await pulls('image-sdxs-cpu'), [
        '--directories-to-pull=$androidImageEvidenceDirectory',
      ]);
      File(
        '$_package/assets/profiles/tiny-gguf-cpu.json',
      ).copySync(p.join(bundle.path, 'profile.json'));
      await writeBundleManifest(bundle, {'target': 'android'});
      expect(await pulls('tiny-gguf-cpu'), [
        '--directories-to-pull=$androidValidationDirectory',
      ]);
      await sealBundle('image-sdxs-metal');
      expect(await pulls('image-sdxs-metal'), isEmpty);
    });
  });

  group('collected image grading', () {
    late Directory run;
    setUp(() => run = Directory(p.join(scratch.path, 'run'))..createSync());

    Uint8List png(int width, int height) => encodePng(
      width: width,
      height: height,
      channels: 3,
      pixels: Uint8List(width * height * 3),
    );

    Map<String, Object?> receipt({String backend = 'CPU'}) {
      final model = _profile('image-sdxs-cpu')['model'] as Map;
      return {
        'source_commit': _commit,
        'source_dirty': false,
        'backend': backend,
        'runtime_tag': stableDiffusionReleaseTag,
        'model_lock': {
          for (final key in ['id', 'filename', 'sha256', 'bytes', 'revision'])
            key: model[key],
        },
        'seed': 42,
        'width': 512,
        'height': 512,
      };
    }

    Future<Directory> pulled({
      String runName = 'run-1791937895791226',
      Map<String, Object?>? metadata,
      Map<String, Object?> recorded = const {},
    }) async {
      final directory = Directory(
        p.join(
          run.path,
          'remote-results',
          'qa-image',
          'SC-51E-36-en-portrait',
          'artifacts',
          androidImageEvidenceDirectory.substring(1),
          runName,
        ),
      );
      await writeImageEvidence(
        directory: directory,
        generatedPng: png(512, 512),
        screenPng: png(8, 14),
        metadata: metadata ?? receipt(),
      );
      if (recorded.isNotEmpty) {
        final file = File(p.join(directory.path, imageEvidenceManifestName));
        file.writeAsStringSync(
          jsonEncode({
            ...jsonDecode(file.readAsStringSync()) as Map<String, dynamic>,
            ...recorded,
          }),
        );
      }
      return directory;
    }

    /// Exports the evidence as `xcresulttool export attachments` lays it out.
    Future<void> attached({
      List<String> names = const [
        'image_evidence.json',
        'image_generation_e2e.png',
        'image_generation_screen.png',
      ],
    }) async {
      final source = Directory(p.join(scratch.path, 'device-cache'));
      await writeImageEvidence(
        directory: source,
        generatedPng: png(512, 512),
        screenPng: png(8, 14),
        metadata: receipt(backend: 'MTL0'),
      );
      final exported = Directory(p.join(run.path, 'xctest-attachments-0'))
        ..createSync(recursive: true);
      final attachments = <Map<String, Object>>[];
      for (final (index, name) in names.indexed) {
        final uuid =
            '${'$index'.padLeft(8, '0')}-0000-4000-8000-${'$index'.padLeft(12, 'A')}';
        final extension = p.extension(name);
        File(
          p.join(source.path, name),
        ).copySync(p.join(exported.path, '$uuid$extension'));
        attachments.add({
          'exportedFileName': '$uuid$extension',
          'suggestedHumanReadableName':
              '${p.basenameWithoutExtension(name)}_0_$uuid$extension',
          'isAssociatedWithFailure': false,
        });
      }
      File(p.join(exported.path, 'manifest.json')).writeAsStringSync(
        jsonEncode([
          {'attachments': attachments, 'testIdentifier': 'RunnerTests'},
        ]),
      );
      Directory(p.join(run.path, 'remote-results')).createSync();
    }

    Future<bool> assess(RemotePlan selected) => assessCollectedRun(
      scratch.path,
      selected,
      run,
      execute: (binary, args, {directory, timeout}) =>
          throw StateError('Image grading runs no text report: $args'),
    );

    Map<String, dynamic> verdict() =>
        jsonDecode(
              File(
                p.join(run.path, 'report', 'image-verdict.json'),
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;

    test('verifies pulled Android evidence against the bundle', () async {
      await sealBundle('image-sdxs-cpu');
      final evidence = await pulled();
      expect(await assess(plan('image-sdxs-cpu')), isTrue);
      expect(verdict()['evidence_verified'], isTrue);
      expect(verdict()['kind'], 'image_generation_e2e');
      expect(
        verdict()['evidence_directory'],
        p.relative(evidence.path, from: run.path),
      );
      expect(verdict()['expected'], {
        for (final key in [
          'source_commit',
          'source_dirty',
          'backend',
          'runtime_tag',
          'model_lock',
        ])
          key: receipt()[key],
      });
    });

    test('rejects evidence that does not match the bundle', () async {
      const source = 'source does not match clean build';
      const identity = 'clean image build identity';
      final cases =
          <String, (Map<String, Object?>, Map<String, Object?>, String)>{
            'other commit': ({}, {'source_commit': 'b' * 40}, source),
            'dirty source': ({}, {'source_dirty': true}, source),
            'backend': ({}, {'backend': 'MTL0'}, 'backend mismatch'),
            'runtime tag': (
              {},
              {'runtime_tag': 'v0.0.0-1'},
              'runtime pin mismatch',
            ),
            'model lock': (
              {},
              {
                'model_lock': {
                  ...receipt()['model_lock'] as Map,
                  'sha256': '0' * 64,
                },
              },
              'model/profile lock mismatch',
            ),
            'seed': ({}, {'seed': 7}, 'seed/dimensions'),
            'dimensions': ({}, {'width': 256}, 'seed/dimensions'),
            'dirty bundle': ({'source_dirty': true}, {}, identity),
            'bundle without commit': ({'source_commit': null}, {}, identity),
            'bundle without pin': (
              {'stable_diffusion_tag': null},
              {},
              identity,
            ),
            'bundle at another commit': (
              {'source_commit': 'c' * 40},
              {},
              source,
            ),
          };
      for (final MapEntry(key: name, value: (bundled, recorded, reason))
          in cases.entries) {
        if (run.existsSync()) run.deleteSync(recursive: true);
        run.createSync();
        await sealBundle('image-sdxs-cpu', overrides: bundled);
        await pulled(recorded: recorded);
        expect(await assess(plan('image-sdxs-cpu')), isFalse, reason: name);
        expect(verdict()['evidence_verified'], isFalse, reason: name);
        expect(verdict()['reason'], contains(reason), reason: name);
      }
    });

    test('rejects altered, missing or repeated evidence runs', () async {
      await sealBundle('image-sdxs-cpu');
      Directory(p.join(run.path, 'remote-results')).createSync();
      expect(await assess(plan('image-sdxs-cpu')), isFalse);
      expect(verdict()['reason'], 'No image evidence was collected');

      final evidence = await pulled();
      final generated = File(p.join(evidence.path, 'image_generation_e2e.png'));
      final bytes = generated.readAsBytesSync();
      generated.writeAsBytesSync([...bytes]..[bytes.length - 20] ^= 1);
      expect(await assess(plan('image-sdxs-cpu')), isFalse);
      expect(verdict()['reason'], contains('image_generation_e2e.png'));

      evidence.deleteSync(recursive: true);
      await pulled(runName: 'run-1');
      await pulled(runName: 'run-2');
      expect(await assess(plan('image-sdxs-cpu')), isFalse);
      expect(verdict()['reason'], contains('More than one'));

      Directory(p.join(run.path, 'remote-results')).deleteSync(recursive: true);
      await pulled(runName: 'not-a-run');
      expect(await assess(plan('image-sdxs-cpu')), isFalse);
      expect(verdict()['reason'], 'No image evidence was collected');
    });

    test('rejects a plan or bundle other than the one uploaded', () async {
      await sealBundle('image-sdxs-cpu');
      await pulled();
      expect(
        await assess(
          RemotePlan({
            ...plan('image-sdxs-cpu').json,
            'profile': 'tiny-gguf-cpu',
          }),
        ),
        isFalse,
      );
      expect(
        await assess(plan('image-sdxs-cpu', target: 'firebase-ios')),
        isFalse,
      );
      expect(
        await assess(
          RemotePlan({
            ...plan('image-sdxs-cpu').json,
            'bundle_sha256': 'e' * 64,
          }),
        ),
        isFalse,
      );
      expect(await assess(plan('image-sdxs-cpu')), isTrue);
      final profile = File(p.join(bundle.path, 'profile.json'));
      profile.writeAsStringSync('${profile.readAsStringSync()} ');
      expect(await assess(plan('image-sdxs-cpu')), isFalse);
    });

    test('verifies exported iOS XCTest attachments', () async {
      await sealBundle('image-sdxs-metal');
      await attached();
      expect(await assess(plan('image-sdxs-metal')), isTrue);
      expect(verdict()['expected']['backend'], 'MTL0');
      expect(
        verdict()['evidence_directory'],
        p.join('report', 'image-evidence'),
      );
    });

    test('rejects incomplete, repeated or mixed iOS attachments', () async {
      for (final (name, names, alsoPulled) in [
        (
          'missing screen',
          ['image_evidence.json', 'image_generation_e2e.png'],
          false,
        ),
        (
          'repeated receipt',
          [
            'image_evidence.json',
            'image_evidence.json',
            'image_generation_e2e.png',
            'image_generation_screen.png',
          ],
          false,
        ),
        (
          'pulled and attached',
          [
            'image_evidence.json',
            'image_generation_e2e.png',
            'image_generation_screen.png',
          ],
          true,
        ),
      ]) {
        if (run.existsSync()) run.deleteSync(recursive: true);
        run.createSync();
        final cache = Directory(p.join(scratch.path, 'device-cache'));
        if (cache.existsSync()) cache.deleteSync(recursive: true);
        await sealBundle('image-sdxs-metal');
        await attached(names: names);
        if (alsoPulled) {
          await pulled(metadata: receipt(backend: 'MTL0'));
        }
        expect(await assess(plan('image-sdxs-metal')), isFalse, reason: name);
        expect(verdict()['evidence_verified'], isFalse, reason: name);
      }
    });

    test('text profiles still require a journal and the report', () async {
      File(
        '$_package/assets/profiles/tiny-gguf-cpu.json',
      ).copySync(p.join(bundle.path, 'profile.json'));
      await writeBundleManifest(bundle, {'target': 'android'});
      await pulled();
      expect(
        await assessCollectedRun(
          scratch.path,
          RemotePlan({
            ...plan('image-sdxs-cpu').json,
            'profile': 'tiny-gguf-cpu',
          }),
          run,
          execute: (binary, args, {directory, timeout}) =>
              throw StateError('No journal, so no report: $args'),
        ),
        isFalse,
      );
      expect(
        File(p.join(run.path, 'report', 'image-verdict.json')).existsSync(),
        isFalse,
      );
    });
  });
}
