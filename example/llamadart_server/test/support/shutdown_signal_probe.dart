import 'dart:io';

import 'package:llamadart_server/src/bootstrap/shutdown_signal.dart';

Future<void> main() async {
  final stopped = waitForShutdownSignal();
  stdout.writeln('ready');
  await stopped;
  stdout.writeln('stopped');
}
