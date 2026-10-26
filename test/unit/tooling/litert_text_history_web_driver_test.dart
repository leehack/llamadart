@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

import 'support/bounded_process.dart';

void main() {
  test(
    'Web history driver serves model input and propagates child status',
    () async {
      final result = await runBoundedProcess(
        Platform.isWindows ? 'python' : 'python3',
        ['-B', '-c', _exerciseDriver],
        timeout: const Duration(seconds: 20),
      );
      expect(result.exitCode, 37, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stdout, contains('LITERT_TEXT_HISTORY_INPUT '));
      expect(result.stdout, contains('DRIVER_HTTP_CONTRACT_PASSED'));
    },
  );
}

const _exerciseDriver = r'''
import hashlib
import json
import pathlib
import runpy
import sys
import tempfile
import unittest
import urllib.error
import urllib.request
from unittest.mock import patch

sys.path.insert(0, str(pathlib.Path('tool/testing').resolve()))
import serve_static_with_headers

check = unittest.TestCase()
servers = []
real_server = serve_static_with_headers.ThreadingTcpServer

def ephemeral_server(address, handler):
    check.assertEqual(address, ('127.0.0.1', 5198))
    server = real_server(('127.0.0.1', 0), handler)
    servers.append(server)
    return server

payload = b'\x00tiny LiteRT-LM fixture\xff\x10'

def child(command):
    check.assertEqual(command, [
        'dart', 'test', '-p', 'chrome-webgpu', '--run-skipped',
        '-t', 'local-only',
        'test/e2e/backends/litert_lm_text_history_web_e2e_test.dart',
    ])
    check.assertEqual(len(servers), 1)
    host, port = servers[0].server_address
    base = f'http://{host}:{port}'

    def fetch(path, byte_range=None):
        headers = {} if byte_range is None else {'Range': byte_range}
        request = urllib.request.Request(base + path, headers=headers)
        try:
            return urllib.request.urlopen(request, timeout=5)
        except urllib.error.HTTPError as response:
            return response

    def isolation_headers(response):
        check.assertEqual(response.headers['Cross-Origin-Opener-Policy'], 'same-origin')
        check.assertEqual(response.headers['Cross-Origin-Embedder-Policy'], 'credentialless')
        check.assertEqual(response.headers['Cross-Origin-Resource-Policy'], 'cross-origin')
        check.assertEqual(response.headers['Access-Control-Allow-Origin'], '*')

    with fetch('/manifest.json') as response:
        check.assertEqual(response.status, 200)
        check.assertEqual(response.headers['Content-Type'], 'application/json')
        isolation_headers(response)
        data = response.read()
        check.assertEqual(int(response.headers['Content-Length']), len(data))
        manifest = json.loads(data)
    check.assertEqual(manifest['backend'], 'cpu', 'manifest backend')
    check.assertEqual(manifest['bytes'], len(payload), 'manifest model size')
    check.assertEqual(manifest['sha256'], hashlib.sha256(payload).hexdigest())
    check.assertEqual(manifest['model'], 'http://127.0.0.1:5198/model.litertlm')

    with fetch('/model.litertlm?cache=fixture') as response:
        check.assertEqual(response.status, 200)
        isolation_headers(response)
        check.assertEqual(response.headers['Accept-Ranges'], 'bytes')
        check.assertEqual(int(response.headers['Content-Length']), len(payload))
        check.assertEqual(response.read(), payload)

    for byte_range, start, end in [
        ('bytes=2-7', 2, 7),
        ('bytes=-4', len(payload) - 4, len(payload) - 1),
        ('bytes=5-', 5, len(payload) - 1),
        ('bytes=2-999', 2, len(payload) - 1),
    ]:
        with fetch('/model.litertlm', byte_range) as response:
            check.assertEqual(response.status, 206)
            isolation_headers(response)
            check.assertEqual(response.headers['Accept-Ranges'], 'bytes')
            check.assertEqual(response.headers['Content-Range'],
                              f'bytes {start}-{end}/{len(payload)}')
            check.assertEqual(int(response.headers['Content-Length']), end - start + 1)
            check.assertEqual(response.read(), payload[start:end + 1])

    with fetch('/model.litertlm', f'bytes={len(payload)}-') as response:
        check.assertEqual(response.status, 416)
        isolation_headers(response)
        check.assertEqual(response.headers['Content-Range'], f'bytes */{len(payload)}')
        check.assertEqual(response.headers['Content-Length'], '0')
        check.assertEqual(response.read(), b'')
    with fetch('/pubspec.yaml') as response:
        check.assertEqual(response.status, 404)
    print('DRIVER_HTTP_CONTRACT_PASSED', flush=True)
    return 37

with tempfile.TemporaryDirectory(prefix='litert_web_driver_') as scratch:
    model = pathlib.Path(scratch) / 'tiny.litertlm'
    model.write_bytes(payload)
    sys.argv = ['litert_text_history_web_e2e.py', '--model-path', str(model)]
    # Keep the real server/handler while avoiding the model E2E's fixed port.
    with patch.object(serve_static_with_headers, 'ThreadingTcpServer', ephemeral_server):
        with patch('subprocess.call', side_effect=child) as call:
            try:
                runpy.run_path('tool/testing/litert_text_history_web_e2e.py',
                               run_name='__main__')
            except SystemExit as result:
                call.assert_called_once()
                raise
''';
