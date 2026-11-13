"""Exercise SSH config migration and rollback using isolated config files."""
import json
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parents[1] / 'debian12-init.sh'


class SSHSetupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='ssh-setup-test-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.main = self.root / 'sshd_config'
        self.includes = self.root / 'sshd_config.d'
        self.includes.mkdir()
        self.backup = self.root / 'backup'
        self.preamble = SOURCE.read_text().split('\n[[ $EUID -eq 0 ]]', 1)[0]

    def run_migration(self, mode='configure', backup=None):
        return subprocess.run(
            ['bash', '-c', self.preamble + '\nrewrite_ssh_port ' + ' '.join(
                shlex.quote(str(arg)) for arg in (
                    mode, self.main, backup or self.backup, 2424))],
            text=True, capture_output=True, timeout=10)

    def test_replaces_ports_in_includes_and_explicit_listen_addresses(self):
        included = self.includes / 'cloud.conf'
        nested = self.root / 'nested.conf'
        included.write_text(f'Port 2222\nInclude "{nested}"\nPasswordAuthentication no\n')
        nested.write_text('pOrT=2200\nListenAddress [::1]:2200\n')
        self.main.write_text(
            f'Port 22\nInclude {self.includes}/*.conf\n'
            'ListenAddress 127.0.0.1:22\nPermitRootLogin prohibit-password\n'
            'Match User backup\n    PasswordAuthentication no\n')
        result = self.run_migration()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('\nPort 2424\n', self.main.read_text())
        self.assertIn('ListenAddress 127.0.0.1:2424', self.main.read_text())
        self.assertIn('ListenAddress [::1]:2424', nested.read_text())
        self.assertIn('PermitRootLogin prohibit-password', self.main.read_text())
        self.assertIn('Match User backup\n    PasswordAuthentication no', self.main.read_text())
        self.assertIn('PasswordAuthentication no', included.read_text())
        active = []
        for file in (self.main, included, nested):
            for line in file.read_text().splitlines():
                tokens = shlex.split(line.replace('=', ' '), comments=True)
                if tokens and tokens[0].lower() == 'port':
                    active.append(tokens[1])
        self.assertEqual(active, ['2424'])

    def test_restore_recovers_all_original_files_and_permissions(self):
        included = self.includes / 'cloud.conf'
        originals = {
            self.main: f'Include {included}\nPort 22\n'.encode(),
            included: b'Port 2222\nPasswordAuthentication no\n',
        }
        for file, data in originals.items():
            file.write_bytes(data)
            file.chmod(0o640)
        self.assertEqual(self.run_migration().returncode, 0)
        result = self.run_migration('restore')
        self.assertEqual(result.returncode, 0, result.stderr)
        for file, data in originals.items():
            self.assertEqual(file.read_bytes(), data)
            self.assertEqual(file.stat().st_mode & 0o777, 0o640)

    def test_rerun_does_not_accumulate_port_lines_or_rewrite_unchanged_files(self):
        self.main.write_text('# original config\nPort 22\n')
        self.assertEqual(self.run_migration().returncode, 0)
        first = self.main.read_bytes()
        second_backup = self.root / 'second-backup'
        result = self.run_migration(backup=second_backup)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.main.read_bytes(), first)
        self.assertEqual(json.loads((second_backup / 'manifest.json').read_text()), [])

    def test_malformed_include_aborts_before_any_file_is_changed(self):
        original = 'Port 22\nInclude "unterminated\n'
        self.main.write_text(original)
        result = self.run_migration()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('No closing quotation', result.stderr)
        self.assertEqual(self.main.read_text(), original)

    def test_port_dependent_auth_policy_aborts_without_changing_any_config(self):
        included = self.includes / 'auth.conf'
        self.main.write_text(f'Port 22\nInclude {included}\n')
        included.write_text('PasswordAuthentication no\nMatch LocalPort 22\n    PasswordAuthentication yes\n')
        original = {file: file.read_bytes() for file in (self.main, included)}
        result = self.run_migration()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Match LocalPort', result.stderr)
        for file, data in original.items():
            self.assertEqual(file.read_bytes(), data)


if __name__ == '__main__':
    unittest.main()
