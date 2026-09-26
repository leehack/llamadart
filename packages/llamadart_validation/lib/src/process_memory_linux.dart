import 'dart:io';

/// Names the Linux and Android footprint counter.
const linuxFootprintSource = '/proc/self/status RssAnon + VmSwap';

/// `RssAnon` plus `VmSwap` in bytes from `/proc/<pid>/status` text, or null
/// unless both lines are present with a `kB` value.
///
/// Kernels before 4.5 have no `RssAnon` line.
int? linuxFootprintFrom(String status) {
  int? kib(String field) {
    final match = RegExp(
      '^$field:\\s*(\\d+) kB\$',
      multiLine: true,
    ).firstMatch(status);
    return match == null ? null : int.parse(match.group(1)!);
  }

  final anonymous = kib('RssAnon');
  final swapped = kib('VmSwap');
  return anonymous == null || swapped == null
      ? null
      : (anonymous + swapped) * 1024;
}

/// This process's `RssAnon` plus `VmSwap` in bytes, or null when
/// `/proc/self/status` cannot be read or lacks either line.
int? readLinuxFootprint() =>
    linuxFootprintFrom(File('/proc/self/status').readAsStringSync());
