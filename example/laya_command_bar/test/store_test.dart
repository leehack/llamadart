import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:laya_command_bar_example/src/intents.dart';
import 'package:laya_command_bar_example/src/laya.dart';
import 'package:laya_command_bar_example/src/store.dart';
import 'package:llamadart/llamadart.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('labels'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('corrections are the picked rows, oldest first', () async {
    final log = LabelLog('${dir.path}/labels.jsonl');
    expect(await log.corrections(), isEmpty);
    await log.add({'text': 'buy milk', 'intent': 'task', 'source': 'reader'});
    await log.add({
      'text': 'dark on',
      'intent': 'settings',
      'source': 'picked',
    });
    await log.add({'text': 'hi', 'intent': 'nonsense', 'source': 'picked'});
    await File(
      log.path,
    ).writeAsString('not json\n[1]\n', mode: FileMode.append);
    await log.add({'text': 'tell bo', 'intent': 'message', 'source': 'picked'});
    expect(await log.corrections(), [
      (CommandIntent.settings, 'dark on'),
      (CommandIntent.message, 'tell bo'),
    ]);
  });

  test('a command head saved in the folder replaces the published one', () {
    final store = AppStore(dir.path);
    expect(store.commandHead(), same(publishedCommandHead));
    expect(publishedCommandHead.kind, ModelSourceKind.huggingFace);
    expect(publishedCommandHead.fileName, commandHeadFile);

    File(store.commandHeadPath).writeAsStringSync('head');
    final local = store.commandHead();
    expect(local.kind, ModelSourceKind.path);
    expect(local.path, store.commandHeadPath);
  });
}
