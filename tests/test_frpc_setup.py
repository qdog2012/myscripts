"""Check that the FRP credentials entered at startup are safely written to TOML."""
import os
from pathlib import Path
import pty
import select
import subprocess
import tempfile
import time
import tomllib
import unittest


SOURCE = Path(__file__).resolve().parents[1] / 'debian12-init.sh'
PREAMBLE = SOURCE.read_text().split('\n[[ $EUID -eq 0 ]]', 1)[0]


class FrpcSetupTests(unittest.TestCase):
    def test_prompt_and_config_preserve_token_without_echo(self):
        token = 'test \\ token "带空格" '
        with tempfile.TemporaryDirectory() as temp:
            config = Path(temp) / 'frpc.toml'
            master, slave = pty.openpty()
            try:
                proc = subprocess.Popen(
                    ['bash', '-c', PREAMBLE + '\nprompt_frpc_settings\nwrite_frpc_config "$1"',
                     'test-frpc', str(config)], stdin=slave, stdout=slave, stderr=slave)
                os.close(slave)
                slave = None
                output = bytearray()

                def enter_after(prompt, text):
                    start = len(output)
                    deadline = time.monotonic() + 5
                    while prompt not in output[start:]:
                        remaining = deadline - time.monotonic()
                        if remaining <= 0 or not select.select([master], [], [], remaining)[0]:
                            self.fail(f'Did not receive {prompt!r}. Output: {output!r}')
                        output.extend(os.read(master, 4096))
                    os.write(master, (text + '\n').encode())

                try:
                    enter_after(b'IPv4', '999.0.0.1')
                    enter_after(b'IPv4', '192.0.2.23')
                    enter_after('token（输入不回显）: '.encode(), token)
                    enter_after('本服务器名'.encode(), 'host-1.example.net')
                    self.assertEqual(proc.wait(timeout=5), 0)
                    self.assertNotIn(token.encode(), output)
                finally:
                    if proc.poll() is None:
                        proc.kill()
                        proc.wait()
            finally:
                os.close(master)
                if slave is not None:
                    os.close(slave)

            data = tomllib.loads(config.read_text())
            self.assertEqual(data['serverAddr'], '192.0.2.23')
            self.assertEqual(data['serverPort'], 9997)
            self.assertEqual(data['auth']['token'], token)
            self.assertEqual(data['transport']['protocol'], 'quic')
            self.assertEqual(config.stat().st_mode & 0o777, 0o600)
            for proxy, (suffix, port) in zip(data['proxies'],
                                            [('vnc', 5901), ('https', 18443), ('api', 443)],
                                            strict=True):
                self.assertEqual(proxy['name'], f'host-1.example.net_{suffix}')
                self.assertEqual(proxy['localPort'], port)
                self.assertEqual(proxy['localIP'], '127.0.0.1')
                self.assertEqual(proxy['secretKey'], token)

    def test_disabled_client_never_prompts_or_installs(self):
        result = subprocess.run(
            ['bash', '-c', PREAMBLE + '\nINSTALL_FRPC=0\nprompt_frpc_settings\ninstall_frpc'],
            stdin=subprocess.DEVNULL, capture_output=True, text=True, start_new_session=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout + result.stderr, '')
