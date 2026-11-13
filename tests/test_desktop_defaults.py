"""Check locale inheritance and the cloud-assistant watchdog shutdown order."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parents[1] / 'debian12-init.sh'


class DesktopDefaultsTests(unittest.TestCase):
    def test_chrome_launches_in_english_without_overriding_regional_dates(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            fake_chrome = root / 'chrome'
            fake_chrome.write_text(
                '#!/usr/bin/python3\nimport json,os,sys\n'
                'names=("LANG","LANGUAGE","LC_MESSAGES","LC_TIME","LC_ALL")\n'
                'print(json.dumps({"args":sys.argv[1:],"env":{name:os.environ[name] for name in names if name in os.environ}}))\n')
            fake_chrome.chmod(0o755)
            launcher = SOURCE.read_text().split("<<'CHROME'\n", 1)[1].split('\nCHROME', 1)[0]
            launcher = launcher.replace('/usr/bin/google-chrome-stable', str(fake_chrome))
            environment = dict(os.environ, HOME=temp, XDG_CONFIG_HOME=str(root / 'config'),
                               LANG='zh_CN.UTF-8', LANGUAGE='zh_CN:zh',
                               LC_MESSAGES='zh_CN.UTF-8', LC_ALL='zh_CN.UTF-8',
                               LC_TIME='de_DE.UTF-8')
            result = subprocess.run(
                ['sh', '-c', launcher, 'chrome-low-resource', 'https://example.net/a b'],
                env=environment, capture_output=True, text=True, check=True)
            data = json.loads(result.stdout)
            self.assertEqual(data['env']['LANG'], 'en_US.UTF-8')
            self.assertEqual(data['env']['LANGUAGE'], 'en_US:en')
            self.assertEqual(data['env']['LC_MESSAGES'], 'en_US.UTF-8')
            self.assertNotIn('LC_ALL', data['env'])
            self.assertEqual(data['env']['LC_TIME'], 'de_DE.UTF-8')
            self.assertIn('--lang=en-US', data['args'])
            self.assertEqual(data['args'][-1], 'https://example.net/a b')

    def test_stops_assistant_watchdog_before_main_agent_and_keeps_unrelated_services(self):
        preamble = SOURCE.read_text().split('\n[[ $EUID -eq 0 ]]', 1)[0]
        backend = r'''
declare -A active=( [AssistDaemon.service]=1 [aliyun.service]=1 [cloudmonitor.service]=1 [aegis.service]=1 [ssh.service]=1 )
declare -A enabled=( [AssistDaemon.service]=1 [aliyun.service]=1 [cloudmonitor.service]=1 [aegis.service]=1 [ssh.service]=1 )
systemctl() {
    local unit=${!#}
    case "$1" in
        show) if [[ -v active[$unit] ]]; then printf 'loaded\n'; else printf 'not-found\n'; fi ;;
        disable)
            # Model the real watchdog: the assistant cannot remain stopped while
            # AssistDaemon is still running.
            if [[ $unit == aliyun.service && ${active[AssistDaemon.service]} == 1 ]]; then return 1; fi
            active[$unit]=0; enabled[$unit]=0 ;;
        is-active) [[ ${active[$unit]:-0} == 1 ]] ;;
        is-enabled) [[ ${enabled[$unit]:-0} == 1 ]] ;;
        *) return 2 ;;
    esac
}
disable_cloud_agents
for unit in AssistDaemon.service aliyun.service cloudmonitor.service aegis.service ssh.service; do
    printf 'STATE %s %s %s\n' "$unit" "${active[$unit]}" "${enabled[$unit]}"
done
printf 'WARNINGS %s\n' "${#CLOUD_AGENT_WARNINGS[@]}"
'''
        result = subprocess.run(['bash', '-c', preamble + '\n' + backend],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        for unit in ('AssistDaemon.service', 'aliyun.service', 'cloudmonitor.service'):
            self.assertIn(f'STATE {unit} 0 0', result.stdout)
        self.assertIn('STATE aegis.service 1 1', result.stdout)
        self.assertIn('STATE ssh.service 1 1', result.stdout)
        self.assertIn('WARNINGS 0', result.stdout)


if __name__ == '__main__':
    unittest.main()
