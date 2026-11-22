#!/usr/bin/env python3
"""Проверки build/install без Xcode, подписи и изменений Keychain."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1]
SHA1 = 'A' * 40
SHA256 = 'B' * 64


class BuildWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / 'scripts').mkdir()
        shutil.copy(SOURCE / 'build-ownshot.sh', self.root / 'scripts')
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.home = self.root / 'home'
        self.home.mkdir()
        self.log = self.root / 'calls'
        self.identity = {'fingerprintSHA1': SHA1, 'fingerprintSHA256': SHA256}
        self.pin = self.root / '.local-signing/identity.json'
        self.pin.parent.mkdir()
        self.pin.write_text(json.dumps(self.identity))
        self.env = dict(os.environ, PATH=f'{self.bin}:{os.environ["PATH"]}', HOME=str(self.home),
                        CALLS=str(self.log), SHA1=SHA1, SHA256=SHA256)
        self.mock('uname', 'echo "${2:-Darwin}"')
        self.mock('identity-helper', 'echo "inspect" >> "$CALLS"; test "${FAIL_INSPECT:-0}" = 0 || exit 1; cat "$(dirname "$0")/identity.json"')
        shutil.copy(self.bin / "identity-helper", self.pin.parent / "identity-helper")
        self.mock('xcodebuild', '''echo "xcodebuild $*" >> "$CALLS"
while [[ $# -gt 0 ]]; do
  case "$1" in -derivedDataPath) derived="$2"; shift;; -configuration) config="$2"; shift;; esac
  shift
done
app="$derived/Build/Products/$config/OwnShot.app"
mkdir -p "$app/Contents"
printf '%s' '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>dev.nikoko.ownshot</string></dict></plist>' > "$app/Contents/Info.plist"
''')
        self.mock('codesign', '''echo "codesign $*" >> "$CALLS"
if [[ "$1" == --verify ]]; then
  test "${FAIL_VERIFY:-0}" = 0 || exit 1
  if [[ "$*" == *.ownshot-install.* && "${FAIL_STAGED:-0}" == 1 ]]; then exit 1; fi
fi
if [[ "$*" == *--extract-certificates* ]]; then
  for arg in "$@"; do
    if [[ "$arg" == --extract-certificates=* ]]; then touch "${arg#--extract-certificates=}"0; exit 0; fi
  done
  exit 1
fi
if [[ "$*" == *-r-* ]]; then echo "designated => identifier \\"dev.nikoko.ownshot\\" and certificate leaf = H\\"${DR_SHA1:-$SHA1}\\""; fi
''')
        self.mock('openssl', '''if [[ "$*" == *-sha256* ]]; then echo "fingerprint=${CERT_SHA256:-$SHA256}"; else echo "fingerprint=$SHA1"; fi''')
        self.mock('ditto', 'echo ditto >> "$CALLS"; cp -R "$1" "$2"')
        self.mock('open', 'echo open >> "$CALLS"')
        self.mock('lsregister', 'echo "lsregister $*" >> "$CALLS"')
        self.mock('pluginkit', 'echo "pluginkit $*" >> "$CALLS"')
        # Проверка установки не должна обращаться к реальному реестру macOS.
        script = self.root / 'scripts/build-ownshot.sh'
        source = script.read_text().replace(
            '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister',
            str(self.bin / 'lsregister')).replace('/usr/bin/pluginkit', str(self.bin / 'pluginkit'))
        script.write_text(source)
        self.installed = self.home / 'Applications/OwnShot.app'
        self.installed.mkdir(parents=True)
        (self.installed / 'previous').write_text('keep')

    def mock(self, name, body):
        path = self.bin / name
        path.write_text('#!/bin/bash\nset -e\n' + body + '\n')
        path.chmod(0o755)

    def run_build(self, *args, **env):
        return subprocess.run(['bash', str(self.root / 'scripts/build-ownshot.sh'), *args],
                              env=dict(self.env, **env), text=True, capture_output=True)

    def calls(self):
        return self.log.read_text() if self.log.exists() else ''

    def test_missing_pin_stops_before_build_without_new_identity(self):
        self.pin.unlink()
        result = self.run_build('--install')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), '')
        self.assertTrue((self.installed / 'previous').exists())

    def test_missing_key_stops_before_xcode_without_fallback(self):
        result = self.run_build('--install', FAIL_INSPECT='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls().strip(), 'inspect')
        self.assertTrue((self.installed / 'previous').exists())

    def test_invalid_signature_never_replaces_installed_app(self):
        result = self.run_build('--install', FAIL_VERIFY='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('ditto', self.calls())
        self.assertTrue((self.installed / 'previous').exists())

    def test_other_certificate_never_replaces_installed_app(self):
        result = self.run_build('--install', CERT_SHA256='C' * 64)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('ditto', self.calls())
        self.assertTrue((self.installed / 'previous').exists())

    def test_staged_signature_failure_keeps_previous_install(self):
        result = self.run_build('--install', FAIL_STAGED='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('ditto', self.calls())
        self.assertTrue((self.installed / 'previous').exists())

    def test_changed_designated_requirement_never_installs(self):
        result = self.run_build('--install', DR_SHA1='C' * 40)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('ditto', self.calls())
        self.assertTrue((self.installed / 'previous').exists())

    def test_verified_build_uses_pinned_identity_without_install_by_default(self):
        result = self.run_build()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('CODE_SIGN_IDENTITY=' + SHA1, self.calls())
        self.assertNotIn('--sign -', self.calls())
        self.assertNotIn('--ensure', self.calls())
        self.assertNotIn('ditto', self.calls())
        self.assertIn(SHA1, (self.pin.parent / 'Signing.xcconfig').read_text())

    def test_default_installed_build_optimizes_live_pixel_processing(self):
        result = self.run_build()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('-configuration Release', self.calls())

    def test_install_checks_staged_app_before_replacing(self):
        result = self.run_build('--run', '--configuration', 'Release')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.installed / 'previous').exists())
        self.assertTrue((self.installed / 'Contents/Info.plist').exists())
        self.assertIn('open', self.calls())
        self.assertEqual(self.calls().count('--verify --deep --strict'), 2)

    def residual_registry(self, persistent=False):
        residual = str(self.root.resolve() / '.build/xcode-derived-data/Build/Products/Release/OwnShot.app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app')
        state = self.root / 'registry-state'
        self.mock('lsregister', f'''echo "lsregister $*" >> "$CALLS"
if [[ "$1" == -dump ]]; then
  if [[ ! -f "{state}" ]]; then
    touch "{state}"
    echo 'path: {residual} (0x123)'
  elif [[ "{int(persistent)}" == 1 || ! -f "{state}.removed" ]]; then
    echo 'path: {residual} (0x123)'
  fi
elif [[ "$1" == -u && "$2" == "{residual}" && -f "{state}" ]]; then
  touch "{state}.removed"
fi
''')
        return residual

    def test_install_retries_exact_residual_registration_then_verifies(self):
        residual = self.residual_registry()
        result = self.run_build('--install')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('lsregister -u ' + residual, self.calls())
        self.assertGreaterEqual(self.calls().count('lsregister -dump'), 2)
        self.assertIn('lsregister -f ' + str(self.installed.resolve()), self.calls())

    def test_persistent_residual_registration_still_fails_without_launch(self):
        residual = self.residual_registry(persistent=True)
        result = self.run_build('--run')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(residual, result.stderr)
        self.assertEqual(self.calls().count('lsregister -u ' + residual), 1)
        self.assertNotIn('lsregister -f ', self.calls())
        self.assertNotIn('\nopen\n', '\n' + self.calls())



if __name__ == '__main__':
    unittest.main()
