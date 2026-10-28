import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun'), 'macOS with Xcode required')
class MacSetupTests(unittest.TestCase):
    def test_existing_state_for_another_cloud_folder_is_preserved(self):
        with tempfile.TemporaryDirectory(prefix='botw-state-test-') as tmp:
            root = Path(tmp); repo = root / 'guide'; (repo / 'tools').mkdir(parents=True)
            shutil.copyfile(ROOT / 'tools/configure_macos.py', repo / 'tools/configure_macos.py')
            app = root / 'Game.app'; (app / 'Contents').mkdir(parents=True)
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'org.macnativegames.botw', 'CFBundleShortVersionString': '1.6.0'}))
            profile = root / 'profile'; (profile / 'save').mkdir(parents=True); (profile / 'account.uid').write_bytes(b'fixture')
            cloud = root / 'drive/Zelda BOTW'; cloud.mkdir(parents=True); (cloud / 'ZeldaCloud.json').write_text(json.dumps({'id':'new-cloud'}))
            state = root / 'state'; state.mkdir(); state_file = state / 'state.json'; state_file.write_text(json.dumps({'cloudID':'old-cloud','base':'old-revision'}))
            command = [sys.executable, str(repo / 'tools/configure_macos.py'), '--game-app', str(app), '--profile', str(profile),
                       '--cloud-dir', str(cloud), '--state-dir', str(state), '--launcher', str(root / 'Play.app')]
            result = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(json.loads(state_file.read_text())['cloudID'], 'old-cloud')
            self.assertEqual((profile / 'account.uid').read_bytes(), b'fixture')
            self.assertFalse((repo / 'config.json').exists())

    def test_isolated_setup_and_running_game_guard(self):
        with tempfile.TemporaryDirectory(prefix='botw-guide-') as tmp:
            sandbox = Path(tmp); repo = sandbox / 'guide'
            for directory in ('cloud', 'tools'):
                (repo / directory).mkdir(parents=True)
            for name in ('CloudSaveCore.swift', 'CloudCLI.swift'):
                shutil.copyfile(ROOT / 'cloud' / name, repo / 'cloud' / name)
            for name in ('profile_launcher.m', 'configure_macos.py'):
                shutil.copyfile(ROOT / 'tools' / name, repo / 'tools' / name)
            app = sandbox / 'My BOTW.app'; (app / 'Contents/MacOS').mkdir(parents=True)
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'org.macnativegames.botw',
                                                                     'CFBundleShortVersionString': '1.6.0'}))
            profile = sandbox / 'profile'; slot = profile / 'save/00000000000000020000000000000001/0/game_data.sav'
            slot.parent.mkdir(parents=True); (profile / 'account.uid').write_bytes(bytes([1]+[0]*7+[2]+[0]*7)); slot.write_bytes(b'fixture')
            drive = sandbox / 'drive'; drive.mkdir()
            launcher = sandbox / 'apps/Play.app'; cloud = drive / 'Zelda BOTW'; state = sandbox / 'state'
            command = [sys.executable, str(repo / 'tools/configure_macos.py'), '--game-app', str(app), '--profile', str(profile),
                       '--cloud-dir', str(cloud), '--state-dir', str(state), '--launcher', str(launcher)]
            done = subprocess.run(command, capture_output=True, text=True, timeout=90)
            self.assertEqual(done.returncode, 0, done.stderr)
            info = json.loads(done.stdout); self.assertEqual(info['seed_status'], 'ready')
            self.assertEqual(slot.read_bytes(), b'fixture')
            binary = launcher / 'Contents/MacOS/LaunchZelda'
            check = subprocess.run([str(binary), '--check'], capture_output=True, text=True, check=True)
            argv = json.loads(check.stdout); self.assertEqual(argv[-1], str(app.resolve()))
            self.assertIn('TOTK_PROFILE_DIR=' + str(profile.resolve()), argv)
            repeated = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(repeated.returncode, 0)
            self.assertEqual(slot.read_bytes(), b'fixture')
            native = app / 'Contents/Resources/totk/build/totk-native'; native.parent.mkdir(parents=True)
            src = sandbox / 'fixture.c'; src.write_text('#include <unistd.h>\nint main(void) { sleep(20); return 0; }\n')
            subprocess.run(['xcrun', 'clang', str(src), '-o', str(native)], check=True, capture_output=True)
            game = subprocess.Popen([str(native)])
            try:
                time.sleep(.2); self.assertIsNone(game.poll())
                helper = repo / 'build/cloud-sync'; config = repo / 'cloud/config.json'
                for action in ('before', 'after', 'seed', 'resolve'):
                    cmd = [str(helper), action, str(config)] + (['00000000-0000-0000-0000-000000000000'] if action == 'resolve' else [])
                    r = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
                    self.assertNotEqual(r.returncode, 0, action)
                    self.assertEqual(json.loads(r.stdout)['status'], 'unavailable')
                self.assertEqual(slot.read_bytes(), b'fixture')
            finally:
                game.terminate(); game.wait(timeout=5)


if __name__ == '__main__': unittest.main()
