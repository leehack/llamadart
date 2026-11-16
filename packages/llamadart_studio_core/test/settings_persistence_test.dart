import 'dart:async';
import 'dart:convert';

import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

const _key = 'studio.settings.v1';

class _SettingsStore extends InMemoryKeyValueStore {
  bool reject = false;
  bool hold = false;
  final writes = <Completer<bool>>[];

  @override
  Future<void> writeString(String key, String value) async {
    if (key == _key) {
      if (hold) {
        final write = Completer<bool>();
        writes.add(write);
        if (!await write.future) throw StateError('Synthetic save failure');
      } else if (reject) {
        throw StateError('Synthetic private failure details');
      }
    }
    await super.writeString(key, value);
  }
}

void main() {
  test(
    'failed settings remain in session and Retry saves the latest values',
    () async {
      final kv = _SettingsStore();
      final shell = StudioShellController(keyValueStore: kv);
      addTearDown(shell.dispose);
      await shell.initialize();
      await shell.updateSettings((s) => s.copyWith(maxTokens: 100));
      kv.reject = true;
      await shell.updateSettings((s) => s.copyWith(maxTokens: 200));
      expect(shell.currentSettings.maxTokens, 200);
      expect(shell.state.savingSettings, isFalse);
      expect(shell.state.settingsSaveError, 'Settings not saved.');
      expect(shell.state.settingsSaveError, isNot(contains('private')));
      expect(
        (jsonDecode((await kv.readString(_key))!) as Map)['maxTokens'],
        100,
      );
      await shell.updateSettings((s) => s.copyWith(maxTokens: 300));
      kv.reject = false;
      await shell.retrySettingsSave();
      expect(shell.state.settingsSaveError, isNull);
      expect(
        (jsonDecode((await kv.readString(_key))!) as Map)['maxTokens'],
        300,
      );
    },
  );

  for (final olderFails in [true, false]) {
    test(
      'older save completion cannot replace the newest result: $olderFails',
      () async {
        final kv = _SettingsStore()..hold = true;
        final shell = StudioShellController(keyValueStore: kv);
        addTearDown(shell.dispose);
        await shell.initialize();
        final first = shell.updateSettings((s) => s.copyWith(maxTokens: 100));
        final second = shell.updateSettings((s) => s.copyWith(maxTokens: 200));
        expect(kv.writes, hasLength(2));
        expect(shell.state.savingSettings, isTrue);
        kv.writes[1].complete(olderFails);
        await second;
        expect(shell.currentSettings.maxTokens, 200);
        expect(shell.state.savingSettings, isFalse);
        final latestError = shell.state.settingsSaveError;
        expect(latestError == null, olderFails);
        kv.writes[0].complete(!olderFails);
        await first;
        expect(shell.currentSettings.maxTokens, 200);
        expect(shell.state.settingsSaveError, latestError);
        expect(shell.state.savingSettings, isFalse);
      },
    );
  }

  test('pending save completion after disposal does not publish', () async {
    final kv = _SettingsStore()..hold = true;
    final shell = StudioShellController(keyValueStore: kv);
    await shell.initialize();
    final save = shell.updateSettings((s) => s.copyWith(maxTokens: 100));
    await shell.dispose();
    kv.writes.single.complete(false);
    await save;
  });
}
