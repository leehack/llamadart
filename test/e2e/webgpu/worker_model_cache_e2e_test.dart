@TestOn('browser')
@Tags(['local-only', 'e2e'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:test/test.dart';
import 'package:web/web.dart'
    show ErrorEvent, MessageEvent, Worker, WorkerOptions;

void main() {
  for (final mode in ['absolute', 'relative']) {
    test('app-owned worker stores and reuses $mode model URLs', () async {
      final script = Uri.base.resolve(
        '../../../build/web_lazy_grammar/worker_model_cache.js?modelUrl=$mode',
      );
      final worker = Worker(
        script.toString().toJS,
        WorkerOptions(type: 'module'),
      );
      try {
        final result = Completer<String>();
        worker.onmessage = ((MessageEvent event) {
          if (!result.isCompleted) {
            result.complete((event.data as JSString).toDart);
          }
        }).toJS;
        worker.onerror = ((ErrorEvent event) {
          if (!result.isCompleted) {
            result.completeError(StateError(event.message));
          }
        }).toJS;
        final body = await result.future.timeout(const Duration(seconds: 90));
        final report = jsonDecode(body) as Map<String, dynamic>;
        expect(report['error'], isNull);
        final loads = (report['loads'] as List<dynamic>)
            .cast<Map<String, dynamic>>();
        expect(loads, hasLength(2));
        expect(loads.first['tokens'], isNotEmpty);
        expect(loads.last['tokens'], loads.first['tokens']);
        expect(loads.first['notes'], contains('model_cache_stored'));
        expect(loads.last['notes'], contains('model_cache_hit'));
      } finally {
        worker.terminate();
      }
    }, timeout: const Timeout(Duration(minutes: 2)));
  }
}
