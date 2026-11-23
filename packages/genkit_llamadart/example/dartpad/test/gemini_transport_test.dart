import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:genkit_llamadart_dartpad_example/main.dart';
import 'package:http/http.dart' as http;

void main() {
  testWidgets('Gemini uses the browser-compatible streaming endpoint', (
    tester,
  ) async {
    final client = _SseClient();
    addTearDown(client.finish);
    await _startGemini(tester, client);

    final request = client.request!;
    expect(request.method, 'POST');
    expect(
      request.url.toString(),
      'https://generativelanguage.googleapis.com/v1beta/models/'
      'gemini-3.1-flash-lite:streamGenerateContent?alt=sse',
    );
    expect(
      request.headers.keys.map((header) => header.toLowerCase()),
      unorderedEquals(['content-type', 'x-goog-api-client', 'x-goog-api-key']),
    );
    expect(request.headers['x-goog-api-key'] == _dummyKey, isTrue);
    expect(request.body.contains(_dummyKey), isFalse);
    expect(jsonDecode(request.body)['store'], isFalse);
    expect(find.text('A fox'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Gemini Stop aborts the HTTP request after a text chunk', (
    tester,
  ) async {
    final client = _SseClient();
    addTearDown(client.finish);
    await _startGemini(tester, client);
    expect(find.text('A fox'), findsOneWidget);

    await tester.tap(find.text('Stop'));
    await tester.pump();
    expect(client.aborted, isTrue);
    expect(find.text('Stopped.'), findsOneWidget);
    expect(find.text('A fox'), findsOneWidget);
  });
}

const _dummyKey = 'fixture-only-credential';

Future<void> _startGemini(WidgetTester tester, _SseClient client) async {
  await tester.pumpWidget(const GenkitDartPadApp());
  await tester.tap(find.text('Gemini'));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.widgetWithText(TextField, 'Gemini API key'),
    _dummyKey,
  );
  await tester.pump();
  await tester.tap(find.text('Connect'));
  await tester.pumpAndSettle();
  final generate = tester
      .widget<FilledButton>(find.widgetWithText(FilledButton, 'Generate'))
      .onPressed!;
  http.runWithClient(generate, () => client);
  await tester.pumpAndSettle();
}

class _SseClient extends http.BaseClient {
  final _body = StreamController<List<int>>();
  http.Request? request;
  bool aborted = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    this.request = request as http.Request;
    final abort = request is http.AbortableRequest
        ? request.abortTrigger
        : null;
    if (abort != null) {
      unawaited(
        abort.then((_) {
          aborted = true;
          if (!_body.isClosed) {
            _body.addError(http.RequestAbortedException(request.url));
          }
          finish();
        }),
      );
    }
    final event = request.url.path.endsWith('/interactions')
        ? '{"event_type":"step.delta","index":0,"delta":{"type":"text","text":"A fox"}}'
        : '{"candidates":[{"content":{"role":"model","parts":[{"text":"A fox"}]},"finishReason":"STOP"}]}';
    _body.add(utf8.encode('data: $event\n\n'));
    return http.StreamedResponse(_body.stream, 200);
  }

  void finish() => unawaited(_body.close());
}
