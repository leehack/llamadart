import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Opens workspace-relative [relativePath] through the Coding file browser.
///
/// A folder tap lists its children asynchronously, so each row is awaited
/// through [waitFor] before [tap] targets it.
Future<void> openCodingBrowserFile(
  String relativePath, {
  required Future<void> Function(String key) tap,
  required Future<void> Function(bool Function() done, String phase) waitFor,
}) async {
  final segments = relativePath.split('/');
  for (var depth = 1; depth <= segments.length; depth++) {
    final key = 'coding_file_${segments.take(depth).join('/')}';
    await waitFor(
      () => find.byKey(Key(key)).evaluate().isNotEmpty,
      'file browser row $key',
    );
    await tap(key);
  }
}
