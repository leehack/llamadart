@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../../tool/testing/validation/bundle.dart';
import '../../../tool/testing/validation/npu.dart';

void main() {
  late Directory root;
  late Directory kit;
  late File model;
  late File dispatch;
  late Map<String, dynamic> manifest;
  const id = 'npu-tensor-g5';

  Future<Map<String, dynamic>> inspect() =>
      inspectNpuInputs(root.path, id, kitPath: kit.path, modelPath: model.path);
  void save() => File(
    p.join(kit.path, 'npu-kit.json'),
  ).writeAsStringSync(jsonEncode(manifest));
  String status(Map<String, dynamic> report, String id) =>
      (report['checks'] as List).cast<Map>().singleWhere(
            (check) => check['id'] == id,
          )['status']
          as String;

  setUp(() {
    root = Directory.systemTemp.createTempSync('npu-input-test-');
    kit = Directory(p.join(root.path, 'kit'))..createSync();
    model = File(p.join(root.path, 'model.litertlm'))
      ..writeAsStringSync('fixture model');
    final header = List<int>.filled(20, 0)
      ..setRange(0, 6, [0x7f, 0x45, 0x4c, 0x46, 2, 1])
      ..[18] = 183;
    dispatch = File(p.join(kit.path, 'libLiteRtDispatch_GoogleTensor.so'))
      ..writeAsBytesSync(header);
    final profile =
        jsonDecode(
              File(
                'packages/llamadart_validation/assets/profiles/$id.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    profile['model']['bytes'] = model.lengthSync();
    // Fixture checks filesystem behavior with a tiny ELF header; real binary
    // qualification is deliberately outside this model-free unit test.
    (profile['npu_target']['libraries'] as Map).remove(
      'libLlamadartVendor_GoogleTensor.so',
    );
    profile['npu_target']['libraries'][p.basename(dispatch.path)]['sha256'] =
        sha256.convert(dispatch.readAsBytesSync()).toString();
    profile['model']['sha256'] = sha256
        .convert(model.readAsBytesSync())
        .toString();
    final profileFile = File(
      p.join(
        root.path,
        'packages/llamadart_validation/assets/profiles/$id.json',
      ),
    );
    profileFile.parent.createSync(recursive: true);
    profileFile.writeAsStringSync(jsonEncode(profile));
    final pins = File(
      p.join(root.path, 'lib/src/hook/native_release_pins.dart'),
    );
    pins.parent.createSync(recursive: true);
    pins.writeAsStringSync("const liteRtLmVersion = '$npuRuntimeTag';");
    manifest = {
      'schema_version': 1,
      'target': 'Google_Tensor_G5',
      'runtime_tag': npuRuntimeTag,
      'litert_revision': npuLiteRtRevision,
      'dispatch_header_sha256': npuDispatchHeaderHash,
      'libraries': {
        p.basename(dispatch.path): {
          'bytes': dispatch.lengthSync(),
          'sha256': sha256.convert(dispatch.readAsBytesSync()).toString(),
        },
      },
    };
    save();
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('gated CPU profiles require local-file support before remote use', () {
    final profile =
        jsonDecode(
              File(
                'packages/llamadart_validation/assets/profiles/gemma3-litert-cpu.json',
              ).readAsStringSync(),
            )
            as Map;
    expect(
      () => requireExecutableValidationProfile(profile),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('desktop runner with --model'),
        ),
      ),
    );
    expect(
      () => requireExecutableValidationProfile(
        profile,
        supportsLocalModelPath: true,
      ),
      returnsNormally,
    );
    expect(
      () => requireExecutableValidationProfile({
        'backend': 'cpu',
        'model': {'access': 'public'},
      }),
      returnsNormally,
    );
  });

  test('gated CPU mobile builds fail before any build command', () async {
    final profile = File(
      p.join(
        root.path,
        'packages/llamadart_validation/assets/profiles/gemma3-litert-cpu.json',
      ),
    );
    profile.writeAsStringSync(
      File(
        'packages/llamadart_validation/assets/profiles/gemma3-litert-cpu.json',
      ).readAsStringSync(),
    );
    for (final target in ['android', 'ios', 'ios-inputs', 'web']) {
      var invoked = false;
      await expectLater(
        buildValidationBundle(
          root.path,
          target,
          p.join(root.path, 'output-$target'),
          profile: 'gemma3-litert-cpu',
          execute: (binary, args, {directory, timeout}) async {
            invoked = true;
            throw StateError('Build command must not run');
          },
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('Mobile/remote model transfer is not implemented'),
          ),
        ),
      );
      expect(invoked, false);
    }
  });

  test(
    'matching input inventory never qualifies or permits dispatch',
    () async {
      final report = await inspect();
      expect(report['inputs_verified'], true);
      expect(report['qualified'], false);
      expect(report['dispatch_allowed'], false);
      expect(report['status'], 'NOT_RUN');
      expect(report['remaining'], isNotEmpty);
      expect(jsonEncode(report), isNot(contains(root.path)));
    },
  );

  test(
    'absent model and kit are actionable, not a download or success',
    () async {
      final report = await inspectNpuInputs(root.path, id);
      expect(status(report, 'model'), 'NOT_RUN');
      expect(status(report, 'kit_identity'), 'NOT_RUN');
      expect(report['inputs_verified'], false);
    },
  );

  test('wrong SoC, revision, header or runtime invalidates the kit', () async {
    for (final key in [
      'target',
      'runtime_tag',
      'litert_revision',
      'dispatch_header_sha256',
    ]) {
      final original = manifest[key];
      manifest[key] = 'incompatible';
      save();
      final report = await inspect();
      expect(status(report, 'kit_identity'), 'NOT_RUN', reason: key);
      expect(report['inputs_verified'], false, reason: key);
      manifest[key] = original;
    }
  });

  test('runtime pin drift requires a new dependency audit', () async {
    File(
      p.join(root.path, 'lib/src/hook/native_release_pins.dart'),
    ).writeAsStringSync("const liteRtLmVersion = '0.18.0';");
    expect(status(await inspect(), 'runtime_pin'), 'NOT_RUN');
  });

  test(
    'undeclared or unrelated libraries cannot enter a verified kit',
    () async {
      File(p.join(kit.path, 'libUnexpected.so')).writeAsStringSync('extra');
      expect(status(await inspect(), 'kit_library_inventory'), 'NOT_RUN');
      File(p.join(kit.path, 'libUnexpected.so')).deleteSync();
      manifest['libraries']['libUnexpected.so'] = {'bytes': 1, 'sha256': 'bad'};
      save();
      expect(status(await inspect(), 'kit_library_inventory'), 'NOT_RUN');
    },
  );

  test('corrupted, missing or symlinked library fails input checks', () async {
    for (final mutation in ['corrupt', 'missing', 'symlink']) {
      if (dispatch.existsSync()) dispatch.deleteSync();
      if (mutation == 'corrupt') dispatch.writeAsStringSync('bad');
      if (mutation == 'symlink') Link(dispatch.path).createSync(model.path);
      final report = await inspect();
      expect(
        status(report, 'library:${p.basename(dispatch.path)}'),
        'NOT_RUN',
        reason: mutation,
      );
    }
  });

  test(
    'matching hash cannot disguise a host/DSP architecture mismatch',
    () async {
      final bytes = dispatch.readAsBytesSync()..[18] = 164;
      dispatch.writeAsBytesSync(bytes);
      manifest['libraries'][p.basename(dispatch.path)]['sha256'] = sha256
          .convert(bytes)
          .toString();
      final profileFile = File(
        p.join(
          root.path,
          'packages/llamadart_validation/assets/profiles/$id.json',
        ),
      );
      final profile = jsonDecode(profileFile.readAsStringSync()) as Map;
      profile['npu_target']['libraries'][p.basename(dispatch.path)]['sha256'] =
          manifest['libraries'][p.basename(dispatch.path)]['sha256'];
      profileFile.writeAsStringSync(jsonEncode(profile));
      save();
      expect(
        status(await inspect(), 'library:${p.basename(dispatch.path)}'),
        'NOT_RUN',
      );
    },
  );

  test('a caller-supplied hash cannot replace the locked probe', () async {
    final bytes = [...dispatch.readAsBytesSync(), 1];
    dispatch.writeAsBytesSync(bytes);
    manifest['libraries'][p.basename(dispatch.path)] = {
      'bytes': bytes.length,
      'sha256': sha256.convert(bytes).toString(),
    };
    save();
    expect(
      status(await inspect(), 'library:${p.basename(dispatch.path)}'),
      'NOT_RUN',
    );
  });

  test('model size and SHA256 must both match', () async {
    model.writeAsStringSync('fixture Model');
    expect(status(await inspect(), 'model'), 'NOT_RUN');
    model.writeAsStringSync('short');
    expect(status(await inspect(), 'model'), 'NOT_RUN');
  });

  test('NPU build rejected before SDK or build commands', () async {
    var calls = 0;
    await expectLater(
      buildValidationBundle(
        root.path,
        'android',
        p.join(root.path, 'out'),
        profile: id,
        execute: (binary, arguments, {directory, timeout}) async {
          calls++;
          throw StateError('must not reach build executor');
        },
      ),
      throwsA(isA<StateError>().having((e) => '$e', 'reason', contains('NPU'))),
    );
    expect(calls, 0);
  });
}
