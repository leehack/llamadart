import 'package:flutter_test/flutter_test.dart';
import 'package:laya_command_bar_example/src/intents.dart';
import 'package:laya_command_bar_example/src/sources.dart';

import 'support.dart';

IntentSource source(List<String> log) => IntentSource(
  reader: (t) async => readingOf(CommandIntent.search, 1, text: t),
  enter: 0.5,
  label: 'Test',
  dispose: () async => log.add('disposed'),
);

void main() {
  test('loads once and reports the loaded source', () async {
    var loads = 0;
    final log = <String>[];
    final option = SourceOption('A', 'a', (_) async {
      loads++;
      return source(log);
    });
    final first = option.load((_, _) {});
    final second = option.load((_, _) {});
    expect(identical(await first, await second), isTrue);
    expect(loads, 1);
    expect(option.loaded, same(await first));

    await option.dispose();
    expect(log, ['disposed']);
    expect(option.loaded, isNull);
  });

  test('a failed load can be retried', () async {
    var loads = 0;
    final option = SourceOption('A', 'a', (_) async {
      if (++loads == 1) throw StateError('offline');
      return source([]);
    });
    await expectLater(option.load((_, _) {}), throwsStateError);
    expect(option.loaded, isNull);
    await option.load((_, _) {});
    expect(loads, 2);
    expect(option.loaded, isNotNull);
  });
}
