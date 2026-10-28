#!/usr/bin/env python3
"""Read this app's installation, iCloud status and game-image verification record."""
import argparse
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
PROOF_RECORD = struct.Struct('<16s65s7xQQQqqqqqq')


def proof_matches(blob, expected_hash, expected_size):
    if not blob or len(blob) % PROOF_RECORD.size:
        return False
    parts = [PROOF_RECORD.unpack_from(blob, offset) for offset in range(0, len(blob), PROOF_RECORD.size)]
    expected = expected_hash.encode('ascii')
    return (all(row[0].rstrip(b'\0') == b'TOTKRFS-PROOF-1' and row[1].rstrip(b'\0') == expected for row in parts)
            and sum(row[4] for row in parts) == expected_size)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--upstream', type=Path, default=ROOT / 'MacNativeGames')
    parser.add_argument('--device', help='iPhone name or device identifier, when multiple devices are paired')
    parser.add_argument('--bundle-id', help='bundle identifier, when multiple BOTW copies are installed')
    args = parser.parse_args()
    env = dict(os.environ)
    candidate = Path('/Applications/Xcode.app/Contents/Developer')
    if not env.get('DEVELOPER_DIR') and candidate.is_dir(): env['DEVELOPER_DIR'] = str(candidate)
    with tempfile.TemporaryDirectory(prefix='botw-phone-status-') as tmp:
        root = Path(tmp)
        def query(name, command):
            path = root / (name + '.json')
            try:
                result = subprocess.run(['xcrun', 'devicectl', *command, '--json-output', str(path)],
                                        env=env, capture_output=True, timeout=30)
            except subprocess.TimeoutExpired:
                raise RuntimeError('Apple device query timed out; check the connection and unlock the phone.') from None
            if result.returncode or not path.is_file():
                raise RuntimeError('Apple device query failed; check the connection and unlock the phone.')
            return json.loads(path.read_text()).get('result', {})
        devices = query('devices', ['list', 'devices']).get('devices', [])
        devices = [d for d in devices if d.get('hardwareProperties', {}).get('platform') == 'iOS' and
                   (not args.device or args.device in (d.get('deviceProperties', {}).get('name'),
                    d.get('identifier'), d.get('hardwareProperties', {}).get('udid')))]
        if not devices: raise RuntimeError('No matching paired iPhone/iPad is available to CoreDevice.')
        if len(devices) != 1: raise RuntimeError('Select exactly one paired iPhone/iPad using --device.')
        serial = devices[0]['hardwareProperties']['udid']
        apps = query('apps', ['device', 'info', 'apps', '--device', serial, '--search', 'macnativegames.botw']).get('apps', [])
        apps = [a for a in apps if 'macnativegames.botw' in a.get('bundleIdentifier', '') and
                (not args.bundle_id or a['bundleIdentifier'] == args.bundle_id)]
        if len(apps) != 1: raise RuntimeError('Select exactly one installed BOTW app using --bundle-id.')
        app = apps[0]; bundle = app['bundleIdentifier']
        if app.get('version') != '1.6.0': raise RuntimeError('The installed game is not BOTW 1.6.0.')
        def copy(source, name):
            dest = root / name
            try:
                r = subprocess.run(['xcrun', 'devicectl', 'device', 'copy', 'from', '--device', serial,
                                    '--domain-type', 'appDataContainer', '--domain-identifier', bundle,
                                    '--source', source, '--destination', str(dest)], env=env, capture_output=True, timeout=30)
            except subprocess.TimeoutExpired:
                return None
            return dest if r.returncode == 0 and dest.is_file() else None
        status_file = copy('Documents/cloud-status.json', 'cloud.json')
        status = json.loads(status_file.read_text()) if status_file else {}
        proof = copy('Documents/.romfs-verified-parts-v1', 'romfs.bin')
        pin = json.loads((args.upstream.expanduser().resolve() / 'games/botw/assets/expected-v1.6.0.json').read_text())
        verified = proof_matches(proof.read_bytes(), pin['romfs']['sha256'], pin['romfs']['size']) if proof else False
        print(json.dumps({'model': devices[0].get('hardwareProperties', {}).get('marketingName'),
                          'ios': devices[0].get('deviceProperties', {}).get('osVersionNumber'),
                          'app_version': app.get('version'),
                          'game_image_full_hash_record': ('present' if verified else 'invalid' if proof else 'not readable'),
                          'phone_icloud_status': status.get('status', 'not readable'),
                          'phone_icloud_phase': status.get('phase', 'not readable'),
                          'phone_revision': status.get('revision')}, ensure_ascii=False, indent=2))
        print('The proof records a previous full hash check; a later data change requires another check.')
        print('Phone status alone does not prove that the Mac has received the same revision.')


if __name__ == '__main__':
    try:
        main()
    except (OSError, RuntimeError, ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
