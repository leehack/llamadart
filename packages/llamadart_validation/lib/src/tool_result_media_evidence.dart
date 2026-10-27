import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'case_catalog.dart';
import 'manifest.dart';

/// Image fixture [color] as `{png_base64, sha256}`; the bytes are rechecked
/// against their locked hash.
Map<String, dynamic> toolResultMediaImage(String color) {
  final image = ((toolResultMediaFixture['images'] as Map)[color] as Map)
      .cast<String, dynamic>();
  if ('${sha256.convert(base64Decode(image['png_base64'] as String))}' !=
      image['sha256']) {
    throw StateError(
      'Tool-result media fixture $color does not match its hash',
    );
  }
  return image;
}

/// Colors in fixture order; each answer must name its own color and not the
/// other, so a constant guess cannot pass both.
List<String> get toolResultMediaColors =>
    ((toolResultMediaFixture['images'] as Map).keys).cast<String>().toList();

/// Rechecks the recorded requests and answers instead of trusting `passed`
/// flags: the image reached the request as a tool-result part, the model had
/// called the tool itself, and each answer names its photo's color only.
bool validToolResultMediaCaseEvidence(
  String id,
  Map<String, dynamic> record,
  ValidationProfile profile,
) {
  if (id != 'M01.tool_result_image' || profile.toolResultProjector == null) {
    return false;
  }
  const fixture = toolResultMediaFixture;
  final media = record['tool_result_media'];
  if (media is! List || !media.contains('image')) return false;
  final call = record['call'];
  if (call is! Map ||
      call['tool_choice'] != 'required' ||
      call['stream_completed'] != true ||
      call['completion_order_valid'] != true ||
      call['reconstructed_name'] != fixture['tool'] ||
      canonicalJson(call['finish_reasons']) != canonicalJson(['tool_calls'])) {
    return false;
  }
  final colors = toolResultMediaColors;
  final trials = record['trials'];
  if (trials is! List || trials.length != colors.length) return false;
  for (var index = 0; index < colors.length; index++) {
    final color = colors[index];
    final trial = trials[index];
    if (trial is! Map ||
        trial['color'] != color ||
        trial['stream_completed'] != true ||
        trial['completion_order_valid'] != true ||
        trial['tool_choice'] != null ||
        trial['tool_call_deltas'] is! List ||
        (trial['tool_call_deltas'] as List).isNotEmpty ||
        !_textFinish(trial['finish_reasons'])) {
      return false;
    }
    final answer = '${trial['content']}'.toLowerCase();
    if (!answer.contains(color) ||
        colors.any((other) => other != color && answer.contains(other))) {
      return false;
    }
    if (!_toolTurnCarriesImage(trial['messages'], color)) return false;
  }
  return true;
}

bool _textFinish(Object? reasons) =>
    canonicalJson(reasons) == canonicalJson(['stop']) ||
    canonicalJson(reasons) == canonicalJson(['length']);

bool _toolTurnCarriesImage(Object? messages, String color) {
  if (messages is! List || messages.length != 3) return false;
  final tool = messages[2];
  if (tool is! Map ||
      tool['role'] != 'tool' ||
      tool['tool_call_id'] != toolResultMediaFixture['call_id'] ||
      tool['content'] is! List) {
    return false;
  }
  final images = (tool['content'] as List)
      .whereType<Map>()
      .where((part) => part['type'] == 'image_url')
      .toList();
  if (images.length != 1) return false;
  final url = (images.single['image_url'] as Map?)?['url'];
  return url is String &&
      url.endsWith(';base64,${toolResultMediaImage(color)['png_base64']}');
}
