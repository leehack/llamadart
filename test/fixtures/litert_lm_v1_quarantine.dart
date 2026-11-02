import 'dart:ffi';
import 'dart:io';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/litert_lm/litert_lm_v1_runtime.dart';

Future<void> main(List<String> args) async {
  final library = DynamicLibrary.open(args.single);
  void call(String name, int value) =>
      library.lookupFunction<Void Function(Int), void Function(int)>(
        'fixture_$name',
      )(value);
  int count(String name) =>
      library.lookupFunction<Int Function(), int Function()>('fixture_$name')();
  final runtime = LiteRtLmV1Runtime(library);
  runtime.load('/secret/models/m.litertlm', cacheDir: '/secret/cache');
  final conversation = runtime.openConversation();
  final turn = conversation.sendText('quarantine');
  final failure = turn.done.then<void>(
    (_) => throw StateError('drain succeeded unexpectedly'),
    onError: (Object error) {
      if (error is! LlamaModelException) throw error;
    },
  );
  call('fail', 19);
  call('emit', 2);
  await failure;
  for (final operation in <void Function()>[
    conversation.close,
    () => conversation.sendText('reuse'),
    runtime.dispose,
    () => runtime.load('/model', cacheDir: '/cache'),
    runtime.openConversation,
  ]) {
    try {
      operation();
      throw StateError('quarantine escaped');
    } on LlamaStateException {
      /* expected */
    }
  }
  // Even an unexpected callback after failed drain must find a live callback
  // and free both strings. This is why no timeout can close its resources.
  call('emit', 4);
  await Future<void>.delayed(const Duration(milliseconds: 20));
  if (count('live') != 2 ||
      count('proxies') != 1 ||
      count('copies') != 0 ||
      count('deleted') != 0) {
    throw StateError('quarantine lifetime counters failed');
  }
  stdout.writeln('quarantine controls passed');
  exit(
    0,
  ); // The quarantined native callback intentionally keeps its isolate alive.
}
