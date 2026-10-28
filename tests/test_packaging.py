from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import zipfile
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'overlays'))
import package_ipa as p


class PackagingTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.root = Path(self.tmp.name)
        app = self.root / 'payload/Payload/TOTK.app'; app.mkdir(parents=True)
        (app / 'Info.plist').write_text('fixture')
        self.binary = app / 'TOTK'; self.binary.write_bytes(b'executable'); self.binary.chmod(0o755)
        self.output = self.root / 'output.ipa'; self.output.write_bytes(b'old artifact')
    def tearDown(self): self.tmp.cleanup()
    def test_archive_preserves_executable_mode(self):
        p.package(self.root / 'payload', self.output)
        with zipfile.ZipFile(self.output) as z:
            self.assertEqual(z.read('Payload/TOTK.app/TOTK'), b'executable')
            self.assertEqual((z.getinfo('Payload/TOTK.app/TOTK').external_attr >> 16) & 0o777, 0o755)
    def test_failure_preserves_existing_output(self):
        with patch.object(zipfile.ZipFile, 'write', side_effect=OSError('simulated failure')):
            with self.assertRaises(OSError): p.package(self.root / 'payload', self.output)
        self.assertEqual(self.output.read_bytes(), b'old artifact')
        self.assertFalse(self.output.with_suffix('.partial.ipa').exists())
    def test_unexpected_symlink_is_not_followed(self):
        (self.root / 'payload/Payload/TOTK.app/link').symlink_to(self.root)
        with self.assertRaises(ValueError): p.package(self.root / 'payload', self.output)
        self.assertEqual(self.output.read_bytes(), b'old artifact')
    def test_existing_partial_is_preserved(self):
        partial = self.output.with_suffix('.partial.ipa'); partial.write_bytes(b'other build')
        with self.assertRaises(FileExistsError): p.package(self.root / 'payload', self.output)
        self.assertEqual(partial.read_bytes(), b'other build')
        self.assertEqual(self.output.read_bytes(), b'old artifact')


if __name__ == '__main__': unittest.main()
