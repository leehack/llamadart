import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Serves hook downloads from in-memory [responses] keyed by URL.
///
/// Any other URL answers 404, which the hook does not retry, so a test can
/// never fall through to the network. Every requested URL is appended to
/// [requests].
final class RuntimeBundleHttpFixture {
  /// Creates a fixture serving [responses].
  RuntimeBundleHttpFixture(this.responses);

  /// Response bodies keyed by URL.
  final Map<String, List<int>> responses;

  /// URLs the hook requested, in order.
  final List<String> requests = [];

  /// A client factory for `withRuntimeBundleHttpClientForTesting`.
  http.Client createClient() => MockClient((request) async {
    final url = request.url.toString();
    requests.add(url);
    final body = responses[url];
    if (body == null) {
      return http.Response('not found', 404);
    }
    return http.Response.bytes(body, 200);
  });
}

/// A `SHA256SUMS` body listing the SHA-256 of each archive in [archives].
String sha256SumsFor(Map<String, List<int>> archives) => [
  for (final MapEntry(key: name, value: bytes) in archives.entries)
    '${sha256.convert(bytes)}  $name',
  '',
].join('\n');
