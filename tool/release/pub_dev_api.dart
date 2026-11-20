import 'dart:convert';
import 'dart:io';

/// The pub.dev endpoint describing [version] of [package], including the
/// pubspec it was published with.
Uri pubDevVersionUri(String package, String version) =>
    Uri.https('pub.dev', '/api/packages/$package/versions/$version');

/// A response body and status from pub.dev.
typedef PubDevResponse = ({int status, String body});

/// Fetches [uri], failing when the connection takes over 30 seconds, or the
/// response headers or [bodyTimeout] pass first.
Future<PubDevResponse> pubDevGet(
  Uri uri, {
  bool followRedirects = true,
  Duration bodyTimeout = const Duration(seconds: 60),
}) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
  try {
    final request = await client.getUrl(uri);
    request.followRedirects = followRedirects;
    final response = await request.close().timeout(const Duration(seconds: 60));
    final body = await response
        .transform(utf8.decoder)
        .join()
        .timeout(bodyTimeout);
    return (status: response.statusCode, body: body);
  } finally {
    client.close(force: true);
  }
}
