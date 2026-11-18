import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_studio/src/app/shared_prefs_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../integration_test/support/mobile_default_inputs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('namespace reads/writes/removes only its real adapter prefix', () async {
    SharedPreferences.setMockInitialValues({'studio.settings': 'ordinary'});
    final prefs = await SharedPreferences.getInstance();
    final realAdapter = SharedPreferencesKeyValueStore(prefs);
    final a = NamespacedAcceptanceStore(realAdapter, 'a');
    final b = NamespacedAcceptanceStore(realAdapter, 'b');
    expect(await a.readString('studio.settings'), isNull);
    await a.writeString('studio.settings', 'isolated');
    await a.writeInt('i', 2);
    await a.writeDouble('d', 0.7);
    await a.writeBool('b', true);
    expect(await a.readString('studio.settings'), 'isolated');
    expect(await a.readInt('i'), 2);
    expect(await a.readDouble('d'), 0.7);
    expect(await a.readBool('b'), true);
    expect(await b.readString('studio.settings'), isNull);
    await b.writeString('studio.settings', 'other');
    await a.remove('studio.settings');
    expect(await a.readString('studio.settings'), isNull);
    await a.removeWrittenKeys();
    expect(prefs.getKeys(), {'studio.settings', '${b.prefix}studio.settings'});
    expect(prefs.getString('studio.settings'), 'ordinary');
    expect(await b.readString('studio.settings'), 'other');
    for (final bad in ['', '../escape', 'a.b', 'a/b', 'a b']) {
      expect(
        () => NamespacedAcceptanceStore(realAdapter, bad),
        throwsArgumentError,
      );
    }
  });

  Map<String, dynamic> manifest() =>
      jsonDecode(jsonEncode({'schema': 1, 'assets': mobileDefaultAssets}))
          as Map<String, dynamic>;

  test(
    'manifest rejects paths, URLs, missing projector and changed identities',
    () {
      validateMobileDefaultManifest(manifest());
      final first = mobileDefaultAssets.keys.first;
      final mutations = <Map<String, dynamic>>[
        manifest()..['url'] = 'https://example.invalid/model',
        manifest()..['schema'] = 2,
        manifest()..['schema'] = true,
        manifest()..['assets'].remove(mobileDefaultAssets.keys.last),
        manifest()..['assets']['$first/../escape'] = {'bytes': 1},
        manifest()..['assets'][first]['sha256'] = '0' * 64,
        manifest()..['assets'][first]['bytes'] = 1,
        manifest()..['assets'][first]['bytes'] = 532517120.0,
        manifest()..['assets'][first]['url'] = 'https://example.invalid/model',
      ];
      for (final value in mutations) {
        expect(
          () => validateMobileDefaultManifest(value),
          throwsFormatException,
        );
      }
    },
  );

  test('directory rejects extra inputs, symlinks, malformed and oversized manifest', () async {
    final root = await Directory.systemTemp.createTemp(
      'mobile-default-inputs-',
    );
    addTearDown(() => root.delete(recursive: true));
    for (final name in mobileDefaultAssets.keys) {
      await File('${root.path}/$name').writeAsString('metadata-only test');
    }
    final file = File('${root.path}/manifest.json');
    await file.writeAsString(jsonEncode(manifest()));
    await validateMobileDefaultDirectory(root);
    final extra = File('${root.path}/nomic.gguf');
    await extra.create();
    await expectLater(
      validateMobileDefaultDirectory(root),
      throwsFormatException,
    );
    await extra.delete();
    final primary = File('${root.path}/${mobileDefaultAssets.keys.first}');
    await primary.delete();
    await Link(primary.path).create(file.path);
    await expectLater(
      validateMobileDefaultDirectory(root),
      throwsFormatException,
    );
    await Link(primary.path).delete();
    await primary.writeAsString('metadata-only test');
    await file.writeAsString('{broken');
    await expectLater(
      validateMobileDefaultDirectory(root),
      throwsFormatException,
    );
    await file.writeAsString(' ' * 4097);
    await expectLater(
      validateMobileDefaultDirectory(root),
      throwsFormatException,
    );
  });
}
