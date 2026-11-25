import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

final _releaseVersion = RegExp(r'^\d+\.\d+\.\d+$');

/// Snapshots the development docs as release [version], in the layout
/// `docusaurus docs:version` produced: `docs/` is copied to
/// `versioned_docs/version-<version>/`, `sidebars.json` to
/// `versioned_sidebars/version-<version>-sidebars.json`, and the version is
/// inserted in descending version order in `versions.json`.
///
/// Writes the snapshot under [targetSiteRoot] when supplied, otherwise [siteRoot].
/// Returns false, changing nothing, when [version] is already published.
bool cutDocsVersion(String siteRoot, String version, {String? targetSiteRoot}) {
  if (!_releaseVersion.hasMatch(version)) {
    throw ArgumentError.value(version, 'version', 'must be MAJOR.MINOR.PATCH');
  }
  final outputRoot = targetSiteRoot ?? siteRoot;
  final versionsFile = File(p.join(outputRoot, 'versions.json'));
  final versions = (jsonDecode(versionsFile.readAsStringSync()) as List)
      .cast<String>();
  if (versions.contains(version)) return false;
  final parts = version.split('.').map(int.parse).toList();
  final index = versions.indexWhere((existing) {
    final existingParts = existing.split('.').map(int.parse).toList();
    for (var i = 0; i < parts.length; i++) {
      final comparison = parts[i].compareTo(existingParts[i]);
      if (comparison != 0) return comparison > 0;
    }
    return false;
  });
  versions.insert(index < 0 ? versions.length : index, version);

  final target = Directory(
    p.join(outputRoot, 'versioned_docs', 'version-$version'),
  );
  final sidebarTarget = File(
    p.join(outputRoot, 'versioned_sidebars', 'version-$version-sidebars.json'),
  );
  if (target.existsSync() || sidebarTarget.existsSync()) {
    throw StateError(
      'Snapshot files for $version exist but versions.json does not list it.',
    );
  }

  final source = Directory(p.join(siteRoot, 'docs'));
  for (final entity in source.listSync(recursive: true)) {
    if (entity is! File) continue;
    final destination = File(
      p.join(target.path, p.relative(entity.path, from: source.path)),
    );
    destination.parent.createSync(recursive: true);
    entity.copySync(destination.path);
  }

  final sidebars = jsonDecode(
    File(p.join(siteRoot, 'sidebars.json')).readAsStringSync(),
  );
  sidebarTarget
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(sidebars)}\n',
    );

  versionsFile.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(versions)}\n',
  );
  return true;
}
