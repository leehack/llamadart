import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

/// Downloads a locked artifact and hashes each chunk as it arrives, so the
/// check never holds the whole file.
///
/// Throws on a status other than 200, on more or fewer bytes than
/// `lock['bytes']`, on a SHA-256 other than `lock['sha256']`, and on a
/// stream error such as a closed [client].
Future<void> verifyLockedDownload(
  http.Client client,
  Map<String, dynamic> lock,
) async {
  final response = await client.send(
    http.Request('GET', Uri.parse(lock['url'] as String)),
  );
  if (response.statusCode != 200) {
    throw StateError('Model download HTTP mismatch');
  }
  final expected = lock['bytes'] as int;
  var received = 0;
  final digest = _DigestSink();
  final input = sha256.startChunkedConversion(digest);
  await for (final chunk in response.stream) {
    received += chunk.length;
    if (received > expected) throw StateError('Model size exceeded');
    input.add(chunk);
  }
  input.close();
  if (received != expected || '${digest.value}' != lock['sha256']) {
    throw const FormatException('Model checksum/size mismatch');
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
