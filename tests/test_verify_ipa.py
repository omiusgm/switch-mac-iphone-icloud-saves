import hashlib
import json
from pathlib import Path
import plistlib
import struct
import tempfile
import unittest
import zipfile
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import verify_ipa as v


class IPAVerificationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.root = Path(self.tmp.name)
        self.work = self.root / 'work'; self.ipa = self.root / 'fixture.ipa'
        self.prefix = 'Payload/TOTK.app/'
        self.files = {
            self.prefix + 'Info.plist': plistlib.dumps({'CFBundleIdentifier': 'org.macnativegames.botw',
                'CFBundleShortVersionString': '1.6.0', 'CFBundleExecutable': 'TOTK',
                'UIFileSharingEnabled': True, 'LSSupportsOpeningDocumentsInPlace': True}),
            self.prefix + 'Settings.bundle/Root.plist': plistlib.dumps({'PreferenceSpecifiers': [{'Key': 'BOTWCloudChooseFolder'}]}),
            self.prefix + 'TOTK': struct.pack('<II', 0xfeedfacf, 0x100000c) + b'BOTWCloudController prepareWithPresenter:profile:completion:',
        }
        seed = self.prefix + 'GameData/shader-seed/'
        shader = {'sample_b.metal': b'synthetic source', 'sample_b.metallib': b'synthetic library'}
        manifest = {'ios_sdk': 'iphoneos', 'ios_metallibs': 1,
                    'files': {n: hashlib.sha256(data).hexdigest() for n, data in shader.items()}}
        self.files[seed + 'seed-manifest.json'] = json.dumps(manifest).encode()
        for n, data in shader.items(): self.files[seed + n] = data
        for name in ('pso_list.tsv', 'pso_title.tsv'): self.files[seed + name] = b'fixture'
        font_dir = self.work / 'totk/extracted/firmware/shared-fonts'; font_dir.mkdir(parents=True)
        for i in range(6):
            name = f'{i}-font.bfttf'; data = f'font{i}'.encode(); (font_dir / name).write_bytes(data)
            self.files[self.prefix + 'GameData/shared-fonts/' + name] = data
    def tearDown(self): self.tmp.cleanup()
    def write(self):
        with zipfile.ZipFile(self.ipa, 'w') as z:
            for name, data in self.files.items(): z.writestr(name, data)
    def test_complete_package(self):
        self.write(); result = v.verify(self.ipa, self.work)
        self.assertEqual(result['status'], 'pass')
        self.assertEqual(result['iphone_metallibs'], 1)
        self.assertEqual(result['dlc_packs_verified'], 0)
    def test_modified_shader_rejected(self):
        self.files[self.prefix + 'GameData/shader-seed/sample_b.metallib'] = b'bad'
        self.write()
        with self.assertRaises(ValueError): v.verify(self.ipa, self.work)
    def test_archive_traversal_rejected(self):
        self.files['Payload/TOTK.app/../escape'] = b'x'; self.write()
        with self.assertRaises(ValueError): v.verify(self.ipa, self.work)
    def test_cloud_controller_required(self):
        self.files[self.prefix + 'TOTK'] = struct.pack('<II', 0xfeedfacf, 0x100000c)
        self.write()
        with self.assertRaises(ValueError): v.verify(self.ipa, self.work)


if __name__ == '__main__': unittest.main()
