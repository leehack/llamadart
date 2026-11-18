// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

/// Reports picker and filesystem failures while leaving cancellation silent.
Future<void> runStudioFileAction(
  BuildContext context,
  String action,
  Future<void> Function() operation,
) async {
  try {
    await operation();
  } catch (error) {
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text('$action: ${humanizeStudioError(error)}')),
    );
  }
}
