import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
COMMIT = 'ea1ce3b2be23540c4d67df95695f8c70f66cd8e0'
SOURCE = Path(os.environ.get('MNG_TEST_REPO', ROOT / 'MacNativeGames')).expanduser()


class OverlayTests(unittest.TestCase):
    @unittest.skipUnless((SOURCE / '.git').exists(), 'Set MNG_TEST_REPO or clone the pinned upstream first')
    def test_conflicting_file_is_preserved_and_clean_overlay_is_idempotent(self):
        with tempfile.TemporaryDirectory(prefix='botw-overlay-test-') as tmp:
            clone = Path(tmp) / 'upstream'
            subprocess.run(['git', 'clone', '--quiet', '--shared', '--no-checkout', str(SOURCE), str(clone)], check=True)
            subprocess.run(['git', 'checkout', '--quiet', '--detach', COMMIT], cwd=clone, check=True)
            dest = clone / 'games/totk/ios/Sources/CloudSaveCore.swift'
            dest.write_text('user changes')
            command = [sys.executable, str(ROOT / 'tools/apply_overlay.py'), str(clone)]
            refused = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(refused.returncode, 0)
            self.assertEqual(dest.read_text(), 'user changes')
            self.assertEqual(subprocess.run(['git', 'diff', '--quiet'], cwd=clone).returncode, 0)
            dest.unlink()
            subprocess.run(command, check=True, capture_output=True)
            self.assertEqual(dest.read_bytes(), (ROOT / 'cloud/CloudSaveCore.swift').read_bytes())
            again = subprocess.run(command, capture_output=True, text=True)
            self.assertEqual(again.returncode, 0, again.stderr)
            subprocess.run([*command, '--check'], check=True, capture_output=True)
            main = clone / 'games/totk/ios/Sources/main.m'
            main.write_text(main.read_text() + '\n// synthetic user edit\n')
            refused = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(refused.returncode, 0)
            self.assertIn('synthetic user edit', main.read_text())


if __name__ == '__main__': unittest.main()
