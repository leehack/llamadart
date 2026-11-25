// Snapshots the development docs for a release. Run from `website/`:
//
//   dart run tool/cut_version.dart 0.8.25
import 'dart:io';

import 'package:llamadart_website/src/tooling/version_cut.dart';

void main(List<String> args) {
  if (args.isEmpty || args.length > 2) {
    stderr.writeln(
      'Usage: dart run tool/cut_version.dart <MAJOR.MINOR.PATCH> [target-site-root]',
    );
    exit(64);
  }
  final version = args.first;
  final targetSiteRoot = args.length == 2 ? args.last : null;
  if (cutDocsVersion('.', version, targetSiteRoot: targetSiteRoot)) {
    stdout.writeln('[docs] Cut docs version $version.');
  } else {
    stdout.writeln('[docs] Version $version already exists; skipping.');
  }
}
