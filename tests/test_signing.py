import hashlib
import json
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
import sign_install as s


class SigningTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.root = Path(self.tmp.name)
        self.ipa = self.root / 'fixture.ipa'; self.receipt = self.root / 'receipt.json'
    def tearDown(self): self.tmp.cleanup()
    def args(self): return ['sign_install.py', '--ipa', str(self.ipa), '--receipt', str(self.receipt), '--device', 'test phone', '--game-closed']
    def test_personal_team_selection_is_explicit_and_filtered(self):
        prefs = self.root / 'Library/Preferences/com.apple.dt.Xcode.plist'; prefs.parent.mkdir(parents=True)
        prefs.write_bytes(plistlib.dumps({'IDEProvisioningTeamByIdentifier': {'account': [
            {'teamID': 'ABC123XYZ9', 'isFreeProvisioningTeam': True},
            {'teamID': 'OTHER12345', 'isFreeProvisioningTeam': False},
        ]}}))
        with patch.object(Path, 'home', return_value=self.root):
            self.assertEqual(s.personal_teams(), ['ABC123XYZ9'])
    def test_changed_ipa_stops_before_device_or_account_actions(self):
        self.ipa.write_bytes(b'local artifact')
        self.receipt.write_text(json.dumps({'status':'pass','cloud_saves_integrated':True,'game_version':'1.6.0',
                                            'ipa_size':self.ipa.stat().st_size,'sha256':'0'*64}))
        with patch.object(sys, 'argv', self.args()), patch.object(s.subprocess, 'run') as run:
            with self.assertRaises(ValueError): s.main()
            run.assert_not_called()
    def test_ipa_without_cloud_setting_stops_before_account_actions(self):
        with zipfile.ZipFile(self.ipa, 'w') as z:
            z.writestr('Payload/TOTK.app/Info.plist', plistlib.dumps({'CFBundleIdentifier':'org.macnativegames.botw','CFBundleShortVersionString':'1.6.0'}))
            z.writestr('Payload/TOTK.app/Settings.bundle/Root.plist', plistlib.dumps({'PreferenceSpecifiers':[]}))
        self.receipt.write_text(json.dumps({'status':'pass','cloud_saves_integrated':True,'game_version':'1.6.0',
            'ipa_size':self.ipa.stat().st_size,'sha256':hashlib.sha256(self.ipa.read_bytes()).hexdigest()}))
        with patch.object(sys, 'argv', self.args()), patch.object(s.subprocess, 'run') as run:
            with self.assertRaises(ValueError): s.main()
            run.assert_not_called()


if __name__ == '__main__': unittest.main()
