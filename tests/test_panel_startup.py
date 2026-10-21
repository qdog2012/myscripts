"""Exercise the embedded OpenResty installer's real local 1Panel connection."""
import ast
from contextlib import contextmanager, redirect_stdout
import http.server
import io
import os
from pathlib import Path
import socket
import threading
import time
import types
import unittest
from unittest.mock import patch


SOURCE = Path(__file__).resolve().parents[1] / 'debian12-init.sh'


def bootstrap(port, clock=time):
    # Stop before password encryption or any app-store side effects.
    embedded = SOURCE.read_text().split("<<'PYTHON'\n", 1)[1].split('\nPYTHON', 1)[0]
    tree = ast.parse(embedded.split('\npublic_key = load_pem_public_key', 1)[0])
    tree.body = [node for node in tree.body if not (
        isinstance(node, ast.ImportFrom) and node.module.startswith('cryptography')
        or isinstance(node, ast.Import) and any(alias.name == 'time' for alias in node.names)
    )]
    environment = {
        'PANEL_PORT': str(port), 'PANEL_DATA_DIR': '/unused/1panel',
        'STREAM_CONFIG_DIR': '/unused/stream.d', 'OPENRESTY_HTTPS_PORT': '18443',
    }
    namespace = {'time': clock}
    with patch.dict(os.environ, environment), redirect_stdout(io.StringIO()):
        exec(compile(tree, str(SOURCE), 'exec'), namespace)
    return namespace['key_cookie']


@contextmanager
def panel(start_delay=0, unavailable_count=0):
    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path != '/admin':
                self.send_error(404)
                return
            self.server.attempts += 1
            if self.server.attempts <= unavailable_count:
                self.send_error(503)
                return
            self.send_response(200)
            self.send_header('Set-Cookie', 'panel_public_key=fixture-key; Path=/')
            self.end_headers()

        def log_message(self, *args):
            pass

    server = http.server.HTTPServer(('127.0.0.1', 0), Handler, bind_and_activate=False)
    server.server_bind()  # Reserve the port without listening yet: connection refused.
    server.attempts = 0
    stop = threading.Event()

    def serve():
        if not stop.wait(start_delay):
            server.server_activate()
            server.serve_forever(poll_interval=0.01)

    worker = threading.Thread(target=serve, daemon=True)
    worker.start()
    try:
        yield server
    finally:
        stop.set()
        if start_delay:
            worker.join(timeout=start_delay + 0.1)
        if worker.is_alive():
            server.shutdown()
        worker.join(timeout=2)
        server.server_close()


class PanelStartupTests(unittest.TestCase):
    def setUp(self):
        self.environment = patch.dict(os.environ, {
            name: '' for name in (
                'http_proxy', 'https_proxy', 'HTTP_PROXY', 'HTTPS_PROXY',
                'all_proxy', 'ALL_PROXY', 'no_proxy', 'NO_PROXY',
            )
        })
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def test_waits_for_panel_that_has_not_started_listening(self):
        with panel(start_delay=0.15) as server:
            self.assertEqual(bootstrap(server.server_port), 'fixture-key')

    def test_retries_temporary_http_unavailability(self):
        with panel(unavailable_count=1) as server:
            self.assertEqual(bootstrap(server.server_port), 'fixture-key')

    def test_local_panel_does_not_use_environment_http_proxy(self):
        with socket.socket() as unused_proxy, panel() as server:
            unused_proxy.bind(('127.0.0.1', 0))
            proxy = f'http://127.0.0.1:{unused_proxy.getsockname()[1]}'
            with patch.dict(os.environ, {'http_proxy': proxy}):
                self.assertEqual(bootstrap(server.server_port), 'fixture-key')

    def test_unreachable_panel_has_bounded_wait_and_actionable_error(self):
        ticks = iter(range(0, 1000, 30))
        clock = types.SimpleNamespace(monotonic=lambda: next(ticks), sleep=lambda _: None)
        with socket.socket() as unused:
            unused.bind(('127.0.0.1', 0))
            port = unused.getsockname()[1]
            with self.assertRaises(SystemExit) as caught:
                bootstrap(port, clock)
        message = str(caught.exception)
        self.assertIn(f'127.0.0.1:{port}', message)
        self.assertIn('systemctl status 1panel', message)
        self.assertIn('journalctl -u 1panel', message)
        self.assertIn('ss -lntp', message)


if __name__ == '__main__':
    unittest.main()
