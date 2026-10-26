#!/usr/bin/env python3
"""Run local-only LiteRT Web history and matching published-runtime controls."""
import argparse
import hashlib
import json
import pathlib
import subprocess
import threading

from serve_static_with_headers import CoiStaticHandler, ThreadingTcpServer


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model-path', required=True)
    parser.add_argument('--backend', choices=['cpu', 'gpu'], default='cpu')
    args = parser.parse_args()
    model = pathlib.Path(args.model_path).resolve(strict=True)
    with model.open('rb') as source:
        digest = hashlib.file_digest(source, 'sha256').hexdigest()
    manifest = dict(model='http://127.0.0.1:5198/model.litertlm',
                    sha256=digest, bytes=model.stat().st_size, backend=args.backend)

    class Handler(CoiStaticHandler):
        cors_origin = '*'

        def translate_path(self, path):
            if path.split('?', 1)[0] == '/model.litertlm':
                return str(model)
            return super().translate_path(path)

        def do_GET(self):
            if self.path == '/manifest.json':
                data = json.dumps(manifest).encode()
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            elif self.path.split('?', 1)[0] == '/model.litertlm':
                super().do_GET()
            else:
                self.send_error(404)

        def copyfile(self, source, outputfile):
            try:
                super().copyfile(source, outputfile)
            except (BrokenPipeError, ConnectionResetError):
                # A rejected model or cancelled request closes its range fetch.
                pass

        def log_message(self, *_):
            pass

    with ThreadingTcpServer(('127.0.0.1', 5198), Handler) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            print('LITERT_TEXT_HISTORY_INPUT ' + json.dumps(manifest), flush=True)
            return subprocess.call([
                'dart', 'test', '-p', 'chrome-webgpu', '--run-skipped',
                '-t', 'local-only',
                'test/e2e/backends/litert_lm_text_history_web_e2e_test.dart',
            ])
        finally:
            server.shutdown()
            thread.join()


if __name__ == '__main__':
    raise SystemExit(main())
