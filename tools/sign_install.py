#!/usr/bin/env python3
"""Sign and install the locally built BOTW 1.6.0 IPA with an Apple development team."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import zipfile

from transfer_romfs import ensure_stopped
from verify_ipa import digest

ROOT = Path(__file__).resolve().parent.parent
ENTITLEMENT = 'com.apple.developer.kernel.increased-memory-limit'


def personal_teams():
    path = Path.home() / 'Library/Preferences/com.apple.dt.Xcode.plist'
    if not path.is_file():
        return []
    data = plistlib.loads(path.read_bytes()).get('IDEProvisioningTeamByIdentifier', {})
    return sorted({entry['teamID'] for group in data.values() if isinstance(group, list)
                   for entry in group if isinstance(entry, dict) and entry.get('isFreeProvisioningTeam')
                   and re.fullmatch('[A-Z0-9]{10}', entry.get('teamID', ''))})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ipa', required=True, type=Path)
    parser.add_argument('--receipt', required=True, type=Path, help='local verification receipt from verify_ipa.py')
    parser.add_argument('--device', required=True, help='device name or identifier shown by Xcode Device Hub')
    parser.add_argument('--upstream', type=Path, default=ROOT / 'MacNativeGames')
    parser.add_argument('--team', help='development team ID when automatic selection is ambiguous')
    parser.add_argument('--bundle-id', help='retain a previously used identifier when renewing')
    parser.add_argument('--game-closed', action='store_true')
    args = parser.parse_args()
    if not args.game_closed:
        parser.error('Save and fully close Zelda on iPhone, then pass --game-closed.')
    ipa, upstream = args.ipa.expanduser().resolve(), args.upstream.expanduser().resolve()
    receipt = json.loads(args.receipt.expanduser().read_text())
    stat = ipa.stat()
    if receipt.get('status') != 'pass' or not receipt.get('cloud_saves_integrated') or receipt.get('game_version') != '1.6.0' or receipt.get('ipa_size') != stat.st_size:
        raise ValueError('The IPA has not passed the required local verification.')
    with ipa.open('rb') as source:
        if digest(source) != receipt.get('sha256'):
            raise ValueError('The IPA no longer matches its verified SHA-256.')
    if ipa.stat().st_mtime_ns != stat.st_mtime_ns:
        raise ValueError('The IPA changed during verification.')
    with zipfile.ZipFile(ipa) as archive:
        info = plistlib.loads(archive.read('Payload/TOTK.app/Info.plist'))
        if info.get('CFBundleIdentifier') != 'org.macnativegames.botw' or info.get('CFBundleShortVersionString') != '1.6.0':
            raise ValueError('Expected an unsigned BOTW 1.6.0 IPA from this overlay.')
        settings = plistlib.loads(archive.read('Payload/TOTK.app/Settings.bundle/Root.plist'))
        if not any(x.get('Key') == 'BOTWCloudChooseFolder' for x in settings['PreferenceSpecifiers']):
            raise ValueError('The IPA does not include the iCloud setup option.')
    tools = upstream / 'games/totk/ios/tools'
    sys.path.insert(0, str(tools))
    import install_device as official
    from xcode_dir import developer_dir
    env = dict(os.environ, DEVELOPER_DIR=developer_dir(), PYTHONUNBUFFERED='1')
    os.environ.update(env)
    device = official.pick_device(args.device)
    if device.get('hardwareProperties', {}).get('platform') != 'iOS':
        raise RuntimeError('Select an iPhone or iPad.')
    if device.get('deviceProperties', {}).get('developerModeStatus') == 'disabled':
        raise RuntimeError('Enable Developer Mode on the iPhone and confirm the restart.')
    udid = device['hardwareProperties']['udid']
    ensure_stopped(udid)
    try:
        cert_teams = official.teams()
    except subprocess.CalledProcessError:
        cert_teams = []
    choices = cert_teams or personal_teams()
    team = args.team or (choices[0] if len(choices) == 1 else '')
    if not re.fullmatch('[A-Z0-9]{10}', team):
        raise RuntimeError('Sign in to Xcode and select a single Personal Team, or pass --team explicitly.')
    bundle = args.bundle_id or 'org.macnativegames.botw.' + team.lower()
    if not bundle.startswith('org.macnativegames.botw.') or not re.fullmatch('[A-Za-z0-9.-]+', bundle):
        raise ValueError('Unexpected bundle identifier; no account changes made.')
    print('Xcode may create a development certificate and register this app and device with Apple.', flush=True)
    profile, _ = official.profile(team, bundle, udid)
    data = subprocess.run(['security', 'cms', '-D', '-i', str(profile)], capture_output=True, check=True).stdout
    provision = plistlib.loads(data)
    if not provision.get('Entitlements', {}).get(ENTITLEMENT):
        raise RuntimeError('This team did not grant Increased Memory Limit. No game was installed; see the guide.')
    print('Installing the signed app. Keep the device connected and unlocked.', flush=True)
    command = [sys.executable, str(tools / 'install_device.py'), str(ipa), '--device', args.device,
               '--team', team, '--bundle-id', bundle]
    # The upstream installer may print the device and team IDs locally; redact them from this wrapper's output.
    process = subprocess.Popen(command, cwd=upstream, env=env, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True, bufsize=1)
    for line in process.stdout:
        print(line.replace(udid, '[device-id]').replace(team, '[team-id]'), end='', flush=True)
    if process.wait():
        raise RuntimeError('The upstream installer failed. Check its output before retrying.')
    with tempfile.TemporaryDirectory(prefix='botw-app-check-') as tmp:
        report = Path(tmp) / 'apps.json'
        try:
            subprocess.run(['xcrun', 'devicectl', 'device', 'info', 'apps', '--device', udid,
                            '--search', bundle, '--json-output', str(report)], env=env, capture_output=True, check=True, timeout=30)
        except subprocess.TimeoutExpired:
            raise RuntimeError('Install returned, but readback timed out; check the device before retrying.') from None
        except subprocess.CalledProcessError:
            raise RuntimeError('Install returned, but readback failed; check the device before retrying.') from None
        apps = json.loads(report.read_text()).get('result', {}).get('apps', [])
    if len([a for a in apps if a.get('bundleIdentifier') == bundle and a.get('version') == '1.6.0']) != 1:
        raise RuntimeError('Install returned success, but the installed app version could not be read back. Check before retrying.')
    print('BOTW 1.6.0 installation verified. Keep the same Apple account, team and bundle identifier for renewals.', flush=True)


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
