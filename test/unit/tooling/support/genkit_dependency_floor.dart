import 'package:pub_semver/pub_semver.dart';
import 'package:yaml/yaml.dart';

Version genkitLlamadartFloor(String pubspec) {
  final manifest = loadYaml(pubspec);
  final dependencies = manifest is YamlMap ? manifest['dependencies'] : null;
  final constraintText = dependencies is YamlMap
      ? dependencies['llamadart']
      : null;
  if (constraintText is! String) {
    throw const FormatException('Expected a version constraint for llamadart');
  }

  final constraint = VersionConstraint.parse(constraintText);
  if (constraint case VersionRange(
    min: final Version floor,
    includeMin: true,
  )) {
    return floor;
  }
  throw const FormatException(
    'Expected an inclusive lower bound for llamadart',
  );
}
