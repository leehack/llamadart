/// Names the resident set probe so a report states what produced its numbers.
const residentSetSource = 'unavailable: dart:io is absent on this platform';

/// Always null: no resident set probe exists without `dart:io`.
int? residentSetBytes() => null;
