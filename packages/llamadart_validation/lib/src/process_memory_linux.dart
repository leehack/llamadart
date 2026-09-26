import 'dart:io';

/// Names the Linux and Android footprint counter.
const linuxFootprintSource = '/proc/self/status RssAnon + RssShmem + VmSwap';

/// `RssAnon` plus `RssShmem` plus `VmSwap` in bytes from `/proc/<pid>/status`
/// text, or null unless all three lines are present with a `kB` value.
///
/// Kernels before 4.5 have no `RssAnon` or `RssShmem` line.
int? linuxFootprintFrom(String status) {
  int? kib(String field) {
    final match = RegExp(
      '^$field:\\s*(\\d+) kB\$',
      multiLine: true,
    ).firstMatch(status);
    return match == null ? null : int.parse(match.group(1)!);
  }

  final anonymous = kib('RssAnon');
  final shared = kib('RssShmem');
  final swapped = kib('VmSwap');
  return anonymous == null || shared == null || swapped == null
      ? null
      : (anonymous + shared + swapped) * 1024;
}

/// This process's `RssAnon` plus `RssShmem` plus `VmSwap` in bytes, or null
/// when `/proc/self/status` cannot be read or lacks any of those lines.
int? readLinuxFootprint() =>
    linuxFootprintFrom(File('/proc/self/status').readAsStringSync());
