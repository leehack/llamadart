import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_chat_example/validation/host_native.dart';
import 'package:llamadart_validation/llamadart_validation.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'the staged host verifies the exact process-private file without fallback',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'validation-staged-',
      );
      addTearDown(() => directory.delete(recursive: true));
      const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        pathProvider,
        (call) async => directory.path,
      );
      addTearDown(() => messenger.setMockMethodCallHandler(pathProvider, null));

      const bytes = [1, 3, 5, 7];
      final data =
          jsonDecode(
                await rootBundle.loadString(
                  'packages/llamadart_validation/assets/profiles/gemma4-litert-gpu.json',
                ),
              )
              as Map<String, dynamic>;
      final lock = data['model'] as Map<String, dynamic>;
      lock['bytes'] = bytes.length;
      lock['sha256'] = sha256.convert(bytes).toString();
      final profile = ValidationProfile.fromJson(data);

      final host = createHost(androidStagedModel: true);
      await host.start('staged-fixture');
      addTearDown(host.finish);
      final cache = Directory(
        p.join(directory.path, 'validation', 'models', profile.modelHash),
      );
      final downloaded = File(p.join(cache.path, profile.filename))
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(bytes);
      final staged = File(p.join(cache.path, pid.toString(), profile.filename));

      await expectLater(
        host.prepare(profile),
        throwsA(isA<FileSystemException>()),
      );
      staged
        ..parent.createSync()
        ..writeAsBytesSync([0, 3, 5, 7]);
      await expectLater(host.prepare(profile), throwsFormatException);
      expect(downloaded.readAsBytesSync(), bytes);

      staged.writeAsBytesSync(bytes);
      final model = await host.prepare(profile);
      expect(model.path, staged.path);
      expect(model.evidence, containsPair('source', 'android_staged'));
      expect(model.evidence, containsPair('verified', true));
      expect(model.evidence, containsPair('sha256', profile.modelHash));
      expect(model.evidence, containsPair('download_ms', 0));
    },
  );
}
