import 'dart:io';
import 'package:llamadart/src/setup_utils.dart';

void main(List<String> args) async {
  final force = args.contains('--force') || args.contains('-f');

  print('========================================');
  print('llamadart Setup');
  print('========================================');

  try {
    await SetupUtils.setup(force: force);
    print('\nSetup completed successfully.');
  } catch (e) {
    print('\nSetup failed: $e');
    exit(1);
  }
}
