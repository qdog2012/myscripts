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
                    ['bash', '-c', PREAMBLE + '\nunset SERVER_PREFIX\nprompt_frpc_settings\nprompt_server_prefix\n'
                     'printf "%s\\n" "$SERVER_HOSTNAME" > "$1.hostname"\nwrite_frpc_config "$1"',
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
                    enter_after('服务器前缀'.encode(), 'invalid_name')
                    enter_after('服务器前缀'.encode(), 'us3')
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

            self.assertEqual(Path(f'{config}.hostname').read_text(), 'us3-server\n')
            data = tomllib.loads(config.read_text())
            self.assertEqual(data['serverAddr'], '192.0.2.23')
            self.assertEqual(data['serverPort'], 9997)
            self.assertEqual(data['auth']['token'], token)
            self.assertEqual(data['transport']['protocol'], 'quic')
            self.assertEqual(config.stat().st_mode & 0o777, 0o600)
            key = data['proxies'][0]['secretKey']
            self.assertRegex(key, r'^[A-Za-z0-9+/]{32}$')
            self.assertNotEqual(key, token)
            for proxy, (suffix, port) in zip(data['proxies'],
                                            [('vnc', 5901), ('https', 18443), ('api', 443)],
                                            strict=True):
                self.assertEqual(proxy['name'], f'us3_{suffix}')
                self.assertEqual(proxy['localPort'], port)
                self.assertEqual(proxy['localIP'], '127.0.0.1')
                self.assertEqual(proxy['secretKey'], key)

    def test_replaces_legacy_token_as_stcp_key_and_reuses_new_key(self):
        with tempfile.TemporaryDirectory() as temp:
            previous = Path(temp) / 'previous.toml'
            output = Path(temp) / 'next.toml'
            old_token = 'A' * 32
            previous.write_text(
                f'auth.token = "{old_token}"\n' +
                f'[[proxies]]\ntype = "stcp"\nsecretKey = "{old_token}"\n' * 3)

            def generate(new_token):
                command = PREAMBLE + '''
FRPC_SERVER_IP=192.0.2.24
SERVER_PREFIX=rerun
FRPC_TOKEN=$3
write_frpc_config "$1" "$2"
'''
                result = subprocess.run(
                    ['bash', '-c', command, 'test-frpc', str(output), str(previous), new_token],
                    capture_output=True, text=True, timeout=5)
                self.assertEqual(result.returncode, 0, result.stderr)
                return tomllib.loads(output.read_text())

            migrated = generate('new-frps-token')
            key = migrated['proxies'][0]['secretKey']
            self.assertRegex(key, r'^[A-Za-z0-9+/]{32}$')
            self.assertNotEqual(key, old_token)
            previous.write_bytes(output.read_bytes())

            updated = generate('rotated-frps-token')
            self.assertEqual(updated['auth']['token'], 'rotated-frps-token')
            self.assertEqual([proxy['secretKey'] for proxy in updated['proxies']], [key] * 3)

    def test_printed_visitor_config_matches_local_proxies_and_key(self):
        with tempfile.TemporaryDirectory() as temp:
            config = Path(temp) / 'frpc.toml'
            script = PREAMBLE + '''
FRPC_SERVER_IP=192.0.2.24
SERVER_PREFIX=example-3
FRPC_TOKEN='test-frps-auth-token'
write_frpc_config "$1"
print_frpc_visitors "$1"
'''
            result = subprocess.run(
                ['bash', '-c', script, 'test-frpc', str(config)],
                capture_output=True, text=True, timeout=5)
            self.assertEqual(result.returncode, 0, result.stderr)
            local = tomllib.loads(config.read_text())
            keys = {proxy['name']: proxy['secretKey'] for proxy in local['proxies']}
            self.assertEqual(tomllib.loads(result.stdout)['visitors'], [
                {'name': name, 'type': 'stcp', 'serverName': name, 'secretKey': keys[name],
                 'bindAddr': '0.0.0.0', 'bindPort': port}
                for name, port in [('example-3_vnc', 9108), ('example-3_api', 4005),
                                   ('example-3_https', 9205)]
            ])
            self.assertNotIn(local['auth']['token'], result.stdout)

    def test_disabled_client_never_prompts_or_installs(self):
        result = subprocess.run(
            ['bash', '-c', PREAMBLE + '\nINSTALL_FRPC=0\nprompt_frpc_settings\ninstall_frpc'],
            stdin=subprocess.DEVNULL, capture_output=True, text=True, start_new_session=True, timeout=5)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout + result.stderr, '')
