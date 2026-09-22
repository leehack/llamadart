import 'dart:io';

/// Names the resident set probe so a report states what produced its numbers.
const residentSetSource = 'dart:io ProcessInfo.currentRss';

/// Whole-process resident bytes, or null when the probe reports nothing usable.
///
/// The value covers native allocations as well as the Dart heap. It is not
/// comparable across operating systems: each counts shared and mapped pages
/// its own way.
int? residentSetBytes() {
  try {
    final bytes = ProcessInfo.currentRss;
    return bytes > 0 ? bytes : null;
  } catch (_) {
    return null;
  }
}
