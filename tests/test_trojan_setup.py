"""Run the installer's input and credential handling without changing the host."""
import json
import fcntl
import os
from pathlib import Path
import pty
import subprocess
import tempfile
import termios
import unittest


SOURCE = Path(__file__).resolve().parents[1] / 'debian12-init.sh'


class TrojanSetupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.credentials = self.root / 'private/trojan'
        # Load real functions, stopping before OS checks and all installation.
        self.preamble = SOURCE.read_text().split('\n[[ $EUID -eq 0 ]]', 1)[0]
        self.preamble += f'\nTROJAN_CREDENTIALS_FILE={self.credentials}\n'

    def run_shell(self, body, answers=None, piped_stdin=False):
        if answers is None:
            return subprocess.run(
                ['bash', '-c', self.preamble + '\n' + body],
                stdin=subprocess.DEVNULL, text=True, capture_output=True,
                start_new_session=True, timeout=10)
        master, slave = pty.openpty()
        try:
            def controlling_terminal():
                os.setsid()
                fcntl.ioctl(slave, termios.TIOCSCTTY, 0)

            process = subprocess.Popen(
                ['bash', '-c', self.preamble + '\n' + body],
                stdin=subprocess.PIPE if piped_stdin else slave,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                preexec_fn=controlling_terminal if piped_stdin else None,
                pass_fds=(slave,) if piped_stdin else ())
            os.close(slave)
            slave = None
            os.write(master, answers.encode())
            stdout, stderr = process.communicate(timeout=10)
            return subprocess.CompletedProcess(process.args, process.returncode, stdout, stderr)
        finally:
            os.close(master)
            if slave is not None:
                os.close(slave)

    def test_reprompts_for_urls_ips_wildcards_and_normalizes_domain(self):
        result = self.run_shell(
            'prompt_trojan_domain\nprintf "DOMAIN=%s\\n" "$TROJAN_DOMAIN"',
            'https://proxy.example.org\n127.0.0.1\n*.example.org\nPROXY.Example.ORG.\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('DOMAIN=proxy.example.org', result.stdout)

    def test_missing_terminal_fails_before_installation(self):
        result = self.run_shell('prompt_trojan_domain\nprintf "INSTALLATION_STARTED\\n"')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('terminal', result.stderr.lower())
        self.assertNotIn('INSTALLATION_STARTED', result.stdout)
        self.assertFalse(self.credentials.exists())

    def test_reads_domain_from_terminal_when_script_stdin_is_a_pipe(self):
        result = self.run_shell(
            'prompt_trojan_domain\nprintf "DOMAIN=%s\\n" "$TROJAN_DOMAIN"',
            'pipe.example.net\n', piped_stdin=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('DOMAIN=pipe.example.net', result.stdout)

    def test_insecure_saved_credentials_are_rejected_before_sourcing(self):
        self.credentials.parent.mkdir()
        marker = self.root / 'sourced'
        self.credentials.write_text(f'touch {marker}\n')
        self.credentials.chmod(0o644)
        result = self.run_shell('prompt_trojan_domain')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('mode 600', result.stderr)
        self.assertFalse(marker.exists())

    def test_rerun_prompts_with_saved_domain_and_keeps_password(self):
        self.credentials.parent.mkdir()
        password = 'ab' * 24
        self.credentials.write_text(
            f'TROJAN_DOMAIN=old.example.org\nTROJAN_PASSWORD={password}\n')
        self.credentials.chmod(0o600)
        result = self.run_shell(
            'prompt_trojan_domain\nsave_trojan_credentials\n'
            'printf "DOMAIN=%s PASSWORD=%s\\n" "$TROJAN_DOMAIN" "$TROJAN_PASSWORD"',
            '\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('old.example.org', result.stderr)
        self.assertIn(f'DOMAIN=old.example.org PASSWORD={password}', result.stdout)
        self.assertEqual(self.credentials.stat().st_mode & 0o777, 0o600)

    def test_user_can_change_saved_domain_without_rotating_password(self):
        self.credentials.parent.mkdir()
        self.credentials.write_text(
            f'TROJAN_DOMAIN=old.example.org\nTROJAN_PASSWORD={"cd" * 24}\n')
        self.credentials.chmod(0o600)
        result = self.run_shell(
            'prompt_trojan_domain\nsave_trojan_credentials', 'new.example.net\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        saved = self.credentials.read_text()
        self.assertIn('TROJAN_DOMAIN=new.example.net', saved)
        self.assertIn('TROJAN_PASSWORD=' + 'cd' * 24, saved)

    def test_skip_does_not_require_a_terminal(self):
        result = self.run_shell('INSTALL_TROJAN=0\nprompt_trojan_domain\nprintf "SKIPPED\\n"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('SKIPPED', result.stdout)

    def test_generated_config_keeps_private_keys_in_systemd_credentials(self):
        config = self.root / 'etc/trojan/debian12-init.json'
        dropin = self.root / 'etc/systemd/system/trojan.service.d/credentials.conf'
        tls_dir = self.root / 'tls'
        result = self.run_shell(
            'TROJAN_DOMAIN=chosen.example.net\n'
            f'TROJAN_TLS_DIR={tls_dir}\n'
            'save_trojan_credentials\n'
            f'write_trojan_config {config} {dropin}\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        data = json.loads(config.read_text())
        password = data['password'][0]
        self.assertRegex(password, r'^[0-9a-f]{48}$')
        self.assertEqual(data['run_type'], 'server')
        self.assertEqual(data['local_addr'], '0.0.0.0')
        self.assertEqual(data['local_port'], 8443)
        self.assertEqual(data['ssl']['cert'], '/run/credentials/trojan.service/fullchain.pem')
        self.assertEqual(data['ssl']['key'], '/run/credentials/trojan.service/privkey.pem')
        self.assertEqual(config.stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.credentials.stat().st_mode & 0o777, 0o600)
        self.assertIn(f'LoadCredential=privkey.pem:{tls_dir}/server.key', dropin.read_text())
        self.assertIn(f'LoadCredential=config.json:{config}', dropin.read_text())

    def test_self_signed_certificate_supports_long_san_and_survives_rerun(self):
        tls_dir = self.root / 'tls'
        domain = 'a' * 63 + '.example.net'
        body = f'TROJAN_DOMAIN={domain}\nTROJAN_TLS_DIR={tls_dir}\ngenerate_trojan_certificate'
        result = self.run_shell(body)
        self.assertEqual(result.returncode, 0, result.stderr)
        cert = tls_dir / 'server.crt'
        key = tls_dir / 'server.key'
        original = cert.read_bytes()
        subprocess.run(['openssl', 'verify', '-CAfile', str(cert),
                        '-verify_hostname', domain, str(cert)],
                       check=True, capture_output=True)
        self.assertEqual(key.stat().st_mode & 0o777, 0o600)
        self.assertEqual(tls_dir.stat().st_mode & 0o777, 0o700)
        result = self.run_shell(body)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(cert.read_bytes(), original)

    def test_domain_change_regenerates_certificate_and_preserves_backup(self):
        tls_dir = self.root / 'tls'
        result = self.run_shell(
            f'TROJAN_TLS_DIR={tls_dir}\nTROJAN_DOMAIN=old.example.org\n'
            'generate_trojan_certificate')
        self.assertEqual(result.returncode, 0, result.stderr)
        original = (tls_dir / 'server.crt').read_bytes()
        result = self.run_shell(
            f'TROJAN_TLS_DIR={tls_dir}\nTROJAN_DOMAIN=new.example.net\n'
            'generate_trojan_certificate')
        self.assertEqual(result.returncode, 0, result.stderr)
        cert = tls_dir / 'server.crt'
        self.assertNotEqual(cert.read_bytes(), original)
        subprocess.run(['openssl', 'verify', '-CAfile', str(cert),
                        '-verify_hostname', 'new.example.net', str(cert)],
                       check=True, capture_output=True)
        backups = list(tls_dir.glob('backup-*/server.crt'))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), original)

    def test_mismatched_private_key_is_replaced_with_a_matching_pair(self):
        tls_dir = self.root / 'tls'
        body = f'TROJAN_TLS_DIR={tls_dir}\nTROJAN_DOMAIN=chosen.example.net\ngenerate_trojan_certificate'
        result = self.run_shell(body)
        self.assertEqual(result.returncode, 0, result.stderr)
        cert = tls_dir / 'server.crt'
        key = tls_dir / 'server.key'
        original = cert.read_bytes()
        subprocess.run(['openssl', 'genrsa', '-out', str(key), '2048'],
                       check=True, capture_output=True)
        result = self.run_shell(body)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotEqual(cert.read_bytes(), original)
        public_cert = subprocess.check_output(['openssl', 'x509', '-in', str(cert), '-noout', '-pubkey'])
        public_key = subprocess.check_output(['openssl', 'pkey', '-in', str(key), '-pubout'])
        self.assertEqual(public_cert, public_key)


if __name__ == '__main__':
    unittest.main()
