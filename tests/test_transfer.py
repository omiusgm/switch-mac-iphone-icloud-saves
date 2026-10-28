import asyncio
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import transfer_romfs as t


class FakeAfc:
    def __init__(self, root, fail_write=None, source_to_change=None):
        self.root = Path(root); self.handles = {}; self.next = 1; self.writes = 0
        self.fail_write = fail_write; self.source_to_change = source_to_change
    def p(self, name): return self.root / name.lstrip('/')
    async def exists(self, name): return self.p(name).exists()
    async def makedirs(self, name): self.p(name).mkdir(parents=True, exist_ok=True)
    async def stat(self, name): return {'st_size': self.p(name).stat().st_size}
    async def set_file_contents(self, name, data): self.p(name).write_bytes(data)
    async def get_file_contents(self, name): return self.p(name).read_bytes()
    async def fopen(self, name, mode):
        handle = self.next; self.next += 1; self.handles[handle] = self.p(name).open(mode + 'b'); return handle
    async def fwrite(self, handle, data, chunk_size):
        self.writes += 1
        if self.writes == self.fail_write: raise OSError('simulated disconnect')
        if self.source_to_change:
            self.source_to_change.write_bytes(b'new source with a different length')
            self.source_to_change = None
        self.handles[handle].write(data)
    async def fclose(self, handle): self.handles.pop(handle).close()


class TransferTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.root = Path(self.tmp.name)
        self.image = self.root / 'image.bin'; self.image.write_bytes(b'example game image data')
        self.sha = t.digest(self.image); self.phone = self.root / 'phone'; self.phone.mkdir()
        self.part = patch.object(t, 'PART', 8); self.part.start()
    def tearDown(self): self.part.stop(); self.tmp.cleanup()
    def push(self, afc, identity=None): return asyncio.run(t.push_image(afc, self.image, self.sha, identity))
    def test_resume_and_skip(self):
        afc = FakeAfc(self.phone, fail_write=2)
        with self.assertRaises(OSError): self.push(afc)
        part = self.phone / 'Documents/GameData/romfs.bin.000'; stamp = part.stat().st_mtime_ns
        afc.fail_write = None; self.push(afc)
        self.assertEqual(part.stat().st_mtime_ns, stamp)
        pieces = sorted((self.phone / 'Documents/GameData').glob('romfs.bin.*'))
        self.assertEqual(b''.join(p.read_bytes() for p in pieces), self.image.read_bytes())
        self.assertEqual(self.push(afc)['status'], 'already-present')
    def test_unrecognised_image_is_preserved(self):
        folder = self.phone / 'Documents/GameData'; folder.mkdir(parents=True)
        (folder / 'romfs.sha256').write_text('different-image\n'); (folder / 'romfs.bin.000').write_bytes(b'old')
        with self.assertRaises(RuntimeError): self.push(FakeAfc(self.phone))
        self.assertEqual((folder / 'romfs.bin.000').read_bytes(), b'old')
    def test_changed_source_never_gets_complete_marker(self):
        identity = t.source_identity(self.image)
        with self.assertRaises(RuntimeError): self.push(FakeAfc(self.phone, source_to_change=self.image), identity)
        marker = (self.phone / 'Documents/GameData/romfs.sha256').read_text().strip()
        self.assertEqual(marker, 'copying ' + self.sha)
    def test_running_game_blocks_transfer(self):
        def fake_run(args, **kwargs):
            report = Path(args[args.index('--json-output') + 1])
            report.write_text(json.dumps({'result': {'runningProcesses': [{'processIdentifier': 123}]}}))
            return SimpleNamespace(returncode=0)
        with patch.object(t.subprocess, 'run', side_effect=fake_run):
            with self.assertRaises(RuntimeError): t.ensure_stopped('synthetic-device')
        self.assertEqual(list(self.phone.iterdir()), [])


if __name__ == '__main__': unittest.main()
