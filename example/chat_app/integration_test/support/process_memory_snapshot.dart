/// Parsers for the arguments and per-step records of the LiteRT-LM reload
/// memory E2E. They take runner arguments and the text of `/proc` files,
/// `dumpsys` output and model output, so a host test can check them without a
/// device.
library;

/// [value] as trimmed text, or null when it is missing or blank: a runner that
/// passes an optional argument as an empty string means the default.
String? optionalArgument(Object? value) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? null : text;
}

/// The `kB` values of [keys] in `/proc/meminfo`-style [text]
/// (`Name:   123 kB`), which is also the format of `/proc/<pid>/status` and
/// `/proc/<pid>/smaps_rollup`. Keys without such a line are left out.
Map<String, int> parseProcKb(String text, Iterable<String> keys) {
  final wanted = keys.toSet();
  final values = <String, int>{};
  for (final line in text.split('\n')) {
    final separator = line.indexOf(':');
    if (separator <= 0) continue;
    final key = line.substring(0, separator).trim();
    if (!wanted.contains(key)) continue;
    final match = RegExp(
      r'^\s*(\d+)\s*kB',
    ).firstMatch(line.substring(separator + 1));
    if (match != null) values[key] = int.parse(match.group(1)!);
  }
  return values;
}

/// Mapped size in kB and mapping count per category of `/proc/<pid>/maps`
/// [text]. `kgsl` is Adreno GPU memory mapped into the process, `mali` its Arm
/// counterpart, `dmabuf` shared graphics buffers, and `model` every mapping
/// whose path contains one of [modelPathFragments] (the model file and the
/// caches the runtime names after it).
Map<String, int> summarizeMaps(
  String text, {
  Iterable<String> modelPathFragments = const [],
}) {
  final fragments = modelPathFragments.where((value) => value.isNotEmpty);
  final summary = <String, int>{'count': 0};
  void add(String category, int kb) {
    summary['${category}_kb'] = (summary['${category}_kb'] ?? 0) + kb;
    summary['${category}_count'] = (summary['${category}_count'] ?? 0) + 1;
  }

  final pattern = RegExp(
    r'^([0-9a-f]+)-([0-9a-f]+)\s+\S+\s+\S+\s+\S+\s+\S+\s*(.*)$',
  );
  for (final line in text.split('\n')) {
    final match = pattern.firstMatch(line);
    if (match == null) continue;
    summary['count'] = summary['count']! + 1;
    final kb =
        (int.parse(match.group(2)!, radix: 16) -
            int.parse(match.group(1)!, radix: 16)) ~/
        1024;
    final path = match.group(3)!;
    if (path.contains('kgsl')) {
      add('kgsl', kb);
    } else if (path.contains('mali')) {
      add('mali', kb);
    } else if (path.contains('dmabuf')) {
      add('dmabuf', kb);
    } else if (fragments.any(path.contains)) {
      add('model', kb);
    }
  }
  return summary;
}

/// How many open descriptors point at each kind of target, from the link
/// targets of `/proc/<pid>/fd`. Sockets, pipes and anonymous inodes are grouped
/// by type, files by base name with digit runs collapsed to `#`, so a
/// descriptor kind that grows with every engine stands out. Only the [limit]
/// most common kinds are kept.
Map<String, int> summarizeDescriptorTargets(
  Iterable<String> targets, {
  int limit = 12,
}) {
  final counts = <String, int>{};
  for (final target in targets) {
    final bracket = target.indexOf(':[');
    final kind = target.startsWith('anon_inode:')
        ? target
        : bracket > 0
        ? target.substring(0, bracket)
        : target.substring(target.lastIndexOf('/') + 1);
    final key = kind.replaceAll(RegExp(r'\d+'), '#');
    counts[key] = (counts[key] ?? 0) + 1;
  }
  final ordered = counts.entries.toList()
    ..sort((a, b) {
      final byCount = b.value.compareTo(a.value);
      return byCount != 0 ? byCount : a.key.compareTo(b.key);
    });
  return {for (final entry in ordered.take(limit)) entry.key: entry.value};
}

/// The PSS rows this harness tracks from `dumpsys meminfo <package>` output,
/// in kB. Category rows (`Native Heap`, `Gfx dev`, `EGL mtrack`, `GL mtrack`,
/// `Other dev`) carry the `Pss Total` column; `summary_*` rows come from the
/// `App Summary` block, where graphics memory reported by the device's
/// memtrack HAL is its own line. Rows the device does not print are left out.
Map<String, int> parseDumpsysMeminfo(String text) {
  final values = <String, int>{};
  const categories = {
    'Native Heap': 'native_heap_pss_kb',
    'Gfx dev': 'gfx_dev_pss_kb',
    'EGL mtrack': 'egl_mtrack_pss_kb',
    'GL mtrack': 'gl_mtrack_pss_kb',
    'Other dev': 'other_dev_pss_kb',
  };
  const summaries = {
    'Native Heap': 'summary_native_heap_kb',
    'Graphics': 'summary_graphics_kb',
    'TOTAL PSS': 'summary_total_pss_kb',
    'TOTAL RSS': 'summary_total_rss_kb',
    'TOTAL SWAP PSS': 'summary_total_swap_pss_kb',
  };
  for (final line in text.split('\n')) {
    for (final MapEntry(:key, :value) in categories.entries) {
      final match = RegExp(
        '^\\s*${RegExp.escape(key)}\\s+(\\d+)(?:\\s|\$)',
      ).firstMatch(line);
      if (match != null) values.putIfAbsent(value, () => int.parse(match[1]!));
    }
    for (final MapEntry(:key, :value) in summaries.entries) {
      final match = RegExp(
        '(?:^|\\s)${RegExp.escape(key)}:\\s+(\\d+)(?:\\s|\$)',
      ).firstMatch(line);
      if (match != null) values.putIfAbsent(value, () => int.parse(match[1]!));
    }
  }
  return values;
}

/// Per-process and device-wide GPU memory in bytes from
/// `dumpsys gpu --gpumem` output, or an empty map when the device prints no
/// snapshot (the kernel's GPU memory tracepoint is optional).
Map<String, int> parseDumpsysGpuMem(String text, int pid) {
  final values = <String, int>{};
  final global = RegExp(r'Global total:\s*(\d+)').firstMatch(text);
  if (global != null) values['gpumem_global_bytes'] = int.parse(global[1]!);
  final process = RegExp('Proc $pid total:\\s*(\\d+)').firstMatch(text);
  if (process != null) values['gpumem_process_bytes'] = int.parse(process[1]!);
  return values;
}

/// What a `generate` step records about [text]: its length in code points,
/// three signals that tell readable output from a broken decode without
/// judging the answer, and its first [limit] code points. The signals are the
/// share of printable ASCII (tab and line breaks included), the number of
/// U+FFFD replacement characters, and how many whitespace-separated words are
/// distinct: one token repeated up to the output limit is one distinct word.
Map<String, Object> describeGeneratedText(String text, {int limit = 400}) {
  final runes = text.runes.toList();
  final printable = runes.where(
    (rune) =>
        (rune >= 0x20 && rune < 0x7f) ||
        rune == 0x09 ||
        rune == 0x0a ||
        rune == 0x0d,
  );
  final words = text.split(RegExp(r'\s+')).where((word) => word.isNotEmpty);
  return {
    'length': runes.length,
    'printable_ascii': runes.isEmpty
        ? 1.0
        : (printable.length * 1000 ~/ runes.length) / 1000,
    'replacement_characters': runes.where((rune) => rune == 0xfffd).length,
    'words': words.length,
    'distinct_words': words.toSet().length,
    'text': String.fromCharCodes(runes.take(limit)),
  };
}

/// How much the memory left after each delete grew across reloads.
///
/// [settledAfterDelete] holds one reading per completed iteration, taken after
/// the engine was deleted; [baseline] is the reading before the first engine
/// and [peak] the largest reading while an engine was alive. `engineCost` is
/// what one live engine adds over the baseline. `retainedAfterFirst` is what
/// the first delete left behind, and `growthPerReload` the average growth per
/// later reload, measured from the second reading: a runtime may keep caches
/// that it fills during the first reload and reuses afterwards, which is not
/// memory kept per engine.
({int engineCost, int growthPerReload, int retainedAfterFirst})
reloadAccumulation({
  required int baseline,
  required int peak,
  required List<int> settledAfterDelete,
}) {
  if (settledAfterDelete.length < 3) {
    throw ArgumentError.value(
      settledAfterDelete,
      'settledAfterDelete',
      'needs at least three completed iterations',
    );
  }
  return (
    engineCost: peak - baseline,
    growthPerReload:
        (settledAfterDelete.last - settledAfterDelete[1]) ~/
        (settledAfterDelete.length - 2),
    retainedAfterFirst: settledAfterDelete.first - baseline,
  );
}
