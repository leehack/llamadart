@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_test/flutter_test.dart';
import 'package:laya_command_bar_example/src/intents.dart';
import 'package:laya_command_bar_example/src/laya.dart';
import 'package:laya_command_bar_example/src/store.dart';

void main() {
  final storage = globalContext['localStorage'] as JSObject;
  void clear(String key) =>
      storage.callMethod<JSAny?>('removeItem'.toJS, key.toJS);

  test('a browser store has no folder and uses the published head', () {
    final store = AppStore(null);
    expect(store.downloads, isNull);
    expect(store.commandHeadPath, isNull);
    expect(store.commandHead(), same(publishedCommandHead));
    expect(store.labels.path, 'laya/labels.jsonl');
  });

  test('the label log keeps picked rows in localStorage', () async {
    const key = 'laya-test/labels.jsonl';
    clear(key);
    addTearDown(() => clear(key));
    final log = LabelLog(key);
    expect(await log.corrections(), isEmpty);
    await log.add({'text': 'buy milk', 'intent': 'task', 'source': 'reader'});
    await log.add({
      'text': 'dark on',
      'intent': 'settings',
      'source': 'picked',
    });

    expect(await LabelLog(key).corrections(), [
      (CommandIntent.settings, 'dark on'),
    ]);
    final stored =
        (storage.callMethod<JSAny?>('getItem'.toJS, key.toJS) as JSString)
            .toDart;
    expect(stored.split('\n').where((l) => l.isNotEmpty), hasLength(2));
  });
}
