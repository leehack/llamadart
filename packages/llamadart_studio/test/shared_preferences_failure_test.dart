@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio/src/app/local_coding_workspace.dart';
import 'package:llamadart_studio/src/app/shared_prefs_store.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

enum _Outcome { success, reject, fail }

class _ObservedStore extends SharedPreferencesStorePlatform {
  final data = <String, Object>{};
  final failure = StateError('Synthetic preference failure');
  final started = Completer<void>();
  _Outcome outcome = _Outcome.success;
  bool failReload = false;
  Completer<void>? gate;

  @override
  Future<Map<String, Object>> getAll() async {
    if (failReload) throw StateError('Synthetic reload failure');
    return Map.of(data);
  }

  Future<bool> _mutate(void Function() action) async {
    final attempt = outcome;
    if (!started.isCompleted) started.complete();
    if (gate != null) await gate!.future;
    if (attempt == _Outcome.fail) throw failure;
    if (attempt == _Outcome.reject) return false;
    action();
    return true;
  }

  @override
  Future<bool> setValue(String type, String key, Object value) =>
      _mutate(() => data[key] = value);

  @override
  Future<bool> remove(String key) => _mutate(() => data.remove(key));

  @override
  Future<bool> clear() => _mutate(data.clear);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferencesStorePlatform previous;
  late _ObservedStore platform;
  setUp(() {
    previous = SharedPreferencesStorePlatform.instance;
    SharedPreferences.resetStatic();
    platform = _ObservedStore();
    SharedPreferencesStorePlatform.instance = platform;
  });
  tearDown(() {
    SharedPreferencesStorePlatform.instance = previous;
    SharedPreferences.resetStatic();
  });

  for (final outcome in [_Outcome.reject, _Outcome.fail]) {
    test(
      'failed typed preferences preserve backing readback: $outcome',
      () async {
        final cases =
            <
              (
                String,
                Object,
                Future<void> Function(SharedPreferencesKeyValueStore),
                Future<Object?> Function(SharedPreferencesKeyValueStore),
              )
            >[
              (
                'string',
                'old',
                (s) => s.writeString('string', 'new'),
                (s) => s.readString('string'),
              ),
              ('int', 1, (s) => s.writeInt('int', 2), (s) => s.readInt('int')),
              (
                'double',
                0.1,
                (s) => s.writeDouble('double', 0.2),
                (s) => s.readDouble('double'),
              ),
              (
                'bool',
                false,
                (s) => s.writeBool('bool', true),
                (s) => s.readBool('bool'),
              ),
              (
                'remove',
                'keep',
                (s) => s.remove('remove'),
                (s) => s.readString('remove'),
              ),
            ];
        for (final item in cases) {
          platform.data['flutter.${item.$1}'] = item.$2;
        }
        final prefs = await SharedPreferences.getInstance();
        final store = SharedPreferencesKeyValueStore(prefs);
        platform.outcome = outcome;
        for (final item in cases) {
          await expectLater(
            item.$3(store),
            throwsA(
              outcome == _Outcome.fail
                  ? same(platform.failure)
                  : isA<LlamaContextException>(),
            ),
          );
          expect(await item.$4(store), item.$2);
          expect(platform.data['flutter.${item.$1}'], item.$2);
        }
        platform.outcome = _Outcome.success;
        await store.writeString('string', 'recovered');
        expect(await store.readString('string'), 'recovered');
        expect(platform.data['flutter.string'], 'recovered');
      },
    );

    test(
      'failed v2 root replacement reads the backing root: $outcome',
      () async {
        final temp = await Directory.systemTemp.createTemp('preferences_root_');
        addTearDown(() => temp.delete(recursive: true));
        final old = await Directory(
          '${temp.path}/coding_workspaces/workspace_old',
        ).create(recursive: true);
        final next = await Directory(
          '${temp.path}/coding_workspaces/workspace_new',
        ).create();
        const key = 'studio.coding.workspace_root.v2';
        final record = jsonEncode({
          'version': 2,
          'kind': 'appOwned',
          'id': 'workspace_old',
        });
        platform.data['flutter.$key'] = record;
        final prefs = await SharedPreferences.getInstance();
        final roots = createLocalCodingWorkspaceRootStore(
          keyValueStore: SharedPreferencesKeyValueStore(prefs),
          appDataDirectory: temp.path,
        );
        expect(await roots.readRoot(), old.path);
        platform.outcome = outcome;
        await expectLater(
          roots.writeRoot(next.path),
          throwsA(
            outcome == _Outcome.fail
                ? same(platform.failure)
                : isA<LlamaContextException>(),
          ),
        );
        expect(await roots.readRoot(), old.path);
        expect(platform.data['flutter.$key'], record);
      },
    );
  }

  test(
    'unavailable reload blocks poisoned reads until storage recovers',
    () async {
      platform.data['flutter.key'] = 'old';
      final prefs = await SharedPreferences.getInstance();
      final store = SharedPreferencesKeyValueStore(prefs);
      platform.outcome = _Outcome.fail;
      platform.failReload = true;
      await expectLater(
        store.writeString('key', 'new'),
        throwsA(same(platform.failure)),
      );
      expect(prefs.getString('key'), 'new');
      await expectLater(store.readString('key'), throwsStateError);
      platform.failReload = false;
      expect(
        await SharedPreferencesKeyValueStore(prefs).readString('key'),
        'old',
      );
    },
  );

  test('two adapters share pending-write and recovery ordering', () async {
    platform.data['flutter.key'] = 'old';
    final prefs = await SharedPreferences.getInstance();
    final writer = SharedPreferencesKeyValueStore(prefs);
    final reader = SharedPreferencesKeyValueStore(prefs);
    platform.outcome = _Outcome.reject;
    platform.gate = Completer<void>();
    addTearDown(() {
      if (!platform.gate!.isCompleted) platform.gate!.complete();
    });
    final write = expectLater(
      writer.writeString('key', 'new'),
      throwsA(isA<LlamaContextException>()),
    );
    await platform.started.future;
    var readCompleted = false;
    final read = reader.readString('key').then((value) {
      readCompleted = true;
      return value;
    });
    await Future<void>.delayed(Duration.zero);
    expect(readCompleted, isFalse);
    platform.gate!.complete();
    await write;
    expect(await read, 'old');
    expect(platform.data['flutter.key'], 'old');
  });
}
