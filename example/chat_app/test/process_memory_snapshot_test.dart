import 'package:flutter_test/flutter_test.dart';

import '../integration_test/support/process_memory_snapshot.dart';

const _meminfo = '''
Applications Memory Usage (in Kilobytes):
Uptime: 5234567 Realtime: 5234567

** MEMINFO in pid 18724 [com.example.llamadart_chat_example] **
                   Pss  Private  Private  SwapPss      Rss     Heap     Heap     Heap
                 Total    Dirty    Clean    Dirty    Total     Size    Alloc     Free
                ------   ------   ------   ------   ------   ------   ------   ------
  Native Heap   183204   183140        0       61   185216   232448   201737    24042
  Dalvik Heap     3441     3340        0        9     9108    11370     5685     5685
        Stack     1180     1180        0        0     1196
    Other dev      124        0      124        0      488
     .so mmap    21877     1168    16296        2    71536
   Other mmap   614836       44   614236        0   615104
      Gfx dev   204800   204800        0        0   204800
   EGL mtrack    30720    30720        0        0    30720
    GL mtrack  1843200  1843200        0        0  1843200
      Unknown     1213     1196        0        0     1664
        TOTAL  2904667  2268788   630656       72  2963032   243818   207422    29727

 App Summary
                       Pss(KB)                        Rss(KB)
                        ------                         ------
           Java Heap:     6984                          17020
         Native Heap:   183140                         185216
                Code:    17508                          88124
               Stack:     1180                           1196
            Graphics:  2078720                        2078720
       Private Other:   615564
              System:     1571
             Unknown:                                  592756

           TOTAL PSS:  2904667            TOTAL RSS:  2963032       TOTAL SWAP PSS:       72

 Objects
               Views:       17         ViewRootImpl:        1
''';

void main() {
  test('treats a missing or blank runner argument as unset', () {
    expect(optionalArgument(null), isNull);
    expect(optionalArgument(''), isNull);
    expect(optionalArgument('  \n'), isNull);
    expect(optionalArgument(' cpu+gpu '), 'cpu+gpu');
    expect(optionalArgument(4), '4');
  });

  test('reads the requested kB lines of a /proc status file', () {
    const status = '''
Name:	chat_example
VmHWM:	 2101244 kB
VmRSS:	  612340 kB
RssAnon:	  401200 kB
RssFile:	  210000 kB
RssShmem:	    1140 kB
VmSwap:	   73912 kB
Threads:	64
''';

    expect(parseProcKb(status, const ['VmRSS', 'RssAnon', 'VmSwap', 'Pss']), {
      'VmRSS': 612340,
      'RssAnon': 401200,
      'VmSwap': 73912,
    });
  });

  test('sums GPU, shared-buffer and model mappings by path', () {
    const maps = '''
70000000-70100000 rw-s 00000000 00:05 1234                       /dev/kgsl-3d0
70100000-70500000 rw-s 00100000 00:05 1234                       /dev/kgsl-3d0
71000000-71200000 rw-s 00000000 00:0b 99                         /dmabuf:gralloc
72000000-96000000 r--p 00000000 fe:2f 4321                       /data/user/0/app/cache/link/Qwen3-0.6B.litertlm
96000000-96400000 r--s 00000000 fe:2f 4400                       /data/user/0/app/cache/Qwen3-0.6B.litertlm_1_2_mldrift_weight_cache.bin
7ffc0000-7ffe0000 rw-p 00000000 00:00 0                          [stack]
''';

    expect(
      summarizeMaps(maps, modelPathFragments: const ['Qwen3-0.6B.litertlm']),
      {
        'count': 6,
        'kgsl_kb': 5120,
        'kgsl_count': 2,
        'dmabuf_kb': 2048,
        'dmabuf_count': 1,
        'model_kb': 593920,
        'model_count': 2,
      },
    );
  });

  test('groups open descriptors by kind and keeps the most common', () {
    expect(
      summarizeDescriptorTargets(const [
        'socket:[48213]',
        'socket:[48977]',
        'pipe:[5021]',
        'anon_inode:sync_file',
        'anon_inode:sync_file',
        'anon_inode:sync_file',
        'anon_inode:[eventfd]',
        '/dev/kgsl-3d0',
        '/dev/kgsl-3d0',
        '/data/user/0/app/cache/Qwen3-0.6B.litertlm_1783120680_614236160_mldrift_weight_cache.bin',
      ], limit: 4),
      {
        'anon_inode:sync_file': 3,
        'kgsl-#d#': 2,
        'socket': 2,
        'Qwen#-#.#B.litertlm_#_#_mldrift_weight_cache.bin': 1,
      },
    );
  });

  test('reads graphics and total PSS from dumpsys meminfo', () {
    expect(parseDumpsysMeminfo(_meminfo), {
      'native_heap_pss_kb': 183204,
      'other_dev_pss_kb': 124,
      'gfx_dev_pss_kb': 204800,
      'egl_mtrack_pss_kb': 30720,
      'gl_mtrack_pss_kb': 1843200,
      'summary_native_heap_kb': 183140,
      'summary_graphics_kb': 2078720,
      'summary_total_pss_kb': 2904667,
      'summary_total_rss_kb': 2963032,
      'summary_total_swap_pss_kb': 72,
    });
  });

  test('leaves out dumpsys rows the device does not print', () {
    // Android 16 emulator: no memtrack rows, and no SwapPss column.
    const emulator = '''
** MEMINFO in pid 5456 [com.example.llamadart_chat_example] **
                   Pss  Private  Private     Swap      Rss     Heap     Heap     Heap
                 Total    Dirty    Clean    Dirty    Total     Size    Alloc     Free
                ------   ------   ------   ------   ------   ------   ------   ------
  Native Heap   296259   296216        0        0   300116   360976   303871    52809
    Other dev        4        0        4        0      316
   Other mmap   676268        4   673468        0   680116
        TOTAL  1188845   429612   730752        0  1334984   366216   306491    55429

 App Summary
                       Pss(KB)                        Rss(KB)
                        ------                         ------
         Native Heap:   296216                         300116
            Graphics:        0                              0

           TOTAL PSS:  1188845            TOTAL RSS:  1334984      TOTAL SWAP (KB):        0
''';

    expect(parseDumpsysMeminfo(emulator), {
      'native_heap_pss_kb': 296259,
      'other_dev_pss_kb': 4,
      'summary_native_heap_kb': 296216,
      'summary_graphics_kb': 0,
      'summary_total_pss_kb': 1188845,
      'summary_total_rss_kb': 1334984,
    });
    expect(
      parseDumpsysMeminfo(
        'No process found for: com.example.llamadart_chat_example',
      ),
      isEmpty,
    );
  });

  test('reads this process and the device total from dumpsys gpu', () {
    const gpumem = '''
Memory snapshot for GPU 0:
Global total: 2291724288
Proc 1203 total: 104857600
Proc 18724 total: 2078720000
''';

    expect(parseDumpsysGpuMem(gpumem, 18724), {
      'gpumem_global_bytes': 2291724288,
      'gpumem_process_bytes': 2078720000,
    });
    expect(parseDumpsysGpuMem('Memory snapshot for GPU 0:\n', 18724), isEmpty);
  });

  test('describes generated text without judging the answer', () {
    expect(describeGeneratedText('Paris.\n'), {
      'length': 7,
      'printable_ascii': 1.0,
      'replacement_characters': 0,
      'words': 1,
      'distinct_words': 1,
      'text': 'Paris.\n',
    });

    final repeated = describeGeneratedText(
      List.filled(32, 'gether').join(' '),
      limit: 10,
    );
    expect(repeated['length'], 223);
    expect(repeated['words'], 32);
    expect(repeated['distinct_words'], 1);
    expect(repeated['text'], 'gether get');

    // A code point outside the BMP is one character and is never split.
    final broken = describeGeneratedText('a\u{fffd}\u{1f600}\u4e2d', limit: 3);
    expect(broken['length'], 4);
    expect(broken['printable_ascii'], 0.25);
    expect(broken['replacement_characters'], 1);
    expect(broken['text'], 'a\u{fffd}\u{1f600}');

    expect(describeGeneratedText('')['printable_ascii'], 1.0);
  });

  test('separates memory kept once from memory kept per engine', () {
    // A cache filled during the second engine and reused afterwards.
    final reused = reloadAccumulation(
      baseline: 431552,
      peak: 2866416,
      settledAfterDelete: const [490304, 1509600, 1509632, 1509616],
    );
    expect(reused.engineCost, 2434864);
    expect(reused.retainedAfterFirst, 58752);
    expect(reused.growthPerReload, 8);

    final stacked = reloadAccumulation(
      baseline: 330000,
      peak: 6540000,
      settledAfterDelete: const [2404000, 4444000, 6490000],
    );
    expect(stacked.growthPerReload, 2046000);

    expect(
      () => reloadAccumulation(
        baseline: 1,
        peak: 4,
        settledAfterDelete: const [2, 3],
      ),
      throwsArgumentError,
    );
  });
}
