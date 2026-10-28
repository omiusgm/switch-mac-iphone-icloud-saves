#!/usr/bin/env python3
"""Build the cloud helper and create a separate Mac launcher for an existing BOTW 1.6.0 app."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def main():
    home = Path.home()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--game-app', type=Path, default=home / 'Applications/Breath of the Wild.app')
    parser.add_argument('--profile', type=Path, default=home / 'Library/Application Support/MacNativeGames/BotW/profile')
    parser.add_argument('--cloud-dir', type=Path, default=home / 'Library/Mobile Documents/com~apple~CloudDocs/Zelda BOTW')
    parser.add_argument('--state-dir', type=Path, default=home / 'Library/Application Support/MacNativeGames/BotW/cloud')
    parser.add_argument('--launcher', type=Path, default=home / 'Applications/Play BOTW with iCloud.app')
    args = parser.parse_args()
    game, profile, cloud, state, launcher = (p.expanduser().resolve() for p in
        (args.game_app, args.profile, args.cloud_dir, args.state_dir, args.launcher))
    info = plistlib.loads((game / 'Contents/Info.plist').read_bytes())
    if info.get('CFBundleIdentifier') != 'org.macnativegames.botw':
        raise ValueError('The selected app is not the expected MacNativeGames BOTW app.')
    if info.get('CFBundleShortVersionString') != '1.6.0':
        raise ValueError('This sync workflow supports BOTW 1.6.0 only.')
    if not (profile / 'account.uid').is_file() or not (profile / 'save').is_dir():
        raise ValueError('No complete Mac profile. Launch the Mac game and create a save first.')
    if launcher.exists() or launcher.is_symlink():
        raise FileExistsError('Launcher already exists. Choose a new --launcher path; nothing was overwritten.')
    if not cloud.parent.is_dir():
        raise ValueError('iCloud Drive is not available at the selected location.')
    existing_state = state / 'state.json'
    if existing_state.exists():
        previous = json.loads(existing_state.read_text())
        marker = cloud / 'ZeldaCloud.json'
        marker_id = json.loads(marker.read_text()).get('id') if marker.is_file() else None
        if (previous.get('cloudID') and previous['cloudID'] != marker_id) or (previous.get('base') and not previous.get('cloudID')):
            raise RuntimeError('The existing sync state belongs to another cloud folder. Preserve it and choose a separate --state-dir.')
    cloud_cfg = {'profile': str(profile), 'cloud': str(cloud), 'state': str(state / 'state.json'),
                 'backups': str(state / 'backups'), 'game_app': str(game)}
    cfg_path, setup_path = ROOT / 'cloud/config.json', ROOT / 'config.json'
    for path, desired in [(cfg_path, cloud_cfg)]:
        if path.exists() and json.loads(path.read_text()) != desired:
            raise FileExistsError(f'{path} already has different settings; nothing was overwritten.')
    if setup_path.exists():
        raise FileExistsError(f'{setup_path} already exists. Preserve it and use a separate guide checkout.')
    build = ROOT / 'build'; build.mkdir(exist_ok=True)
    launcher.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='botw-cloud-setup-', dir=launcher.parent) as tmp:
        temporary = Path(tmp); helper = temporary / 'cloud-sync'; temporary_config = temporary / 'cloud-config.json'
        temporary_config.write_text(json.dumps(cloud_cfg, ensure_ascii=False, indent=2) + '\n')
        subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-O', '-parse-as-library',
                        str(ROOT / 'cloud/CloudSaveCore.swift'), str(ROOT / 'cloud/CloudCLI.swift'), '-o', str(helper)], check=True)
        result = subprocess.run([str(helper), 'seed', str(temporary_config)], text=True, capture_output=True)
        if result.returncode:
            raise RuntimeError('Cloud seed stopped: ' + result.stdout.strip())
        report = json.loads(result.stdout)
        if report.get('status') not in ('ready', 'imported', 'conflict'):
            raise RuntimeError('No usable save was seeded: ' + result.stdout.strip())
        bundle = temporary / 'launcher.app'; binary = bundle / 'Contents/MacOS/LaunchZelda'; binary.parent.mkdir(parents=True)
        resources = bundle / 'Contents/Resources'; resources.mkdir()
        app_info = {'CFBundleIdentifier': 'org.macnativegames.botw.cloudhelper', 'CFBundleName': 'Play BOTW with iCloud',
                    'CFBundleExecutable': 'LaunchZelda', 'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1',
                    'LSUIElement': True, 'BOTWSetupConfig': str(setup_path)}
        icon_name = info.get('CFBundleIconFile', '')
        if icon_name:
            icon = game / 'Contents/Resources' / (icon_name if icon_name.endswith('.icns') else icon_name + '.icns')
            if icon.is_file():
                shutil.copyfile(icon, resources / 'AppIcon.icns'); app_info['CFBundleIconFile'] = 'AppIcon.icns'
        (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps(app_info))
        subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-O2', str(ROOT / 'tools/profile_launcher.m'),
                        '-framework', 'Cocoa', '-o', str(binary)], check=True)
        subprocess.run(['codesign', '--force', '--sign', '-', str(bundle)], check=True)
        subprocess.run(['codesign', '--verify', '--strict', str(bundle)], check=True)
        cfg_path.write_text(json.dumps(cloud_cfg, ensure_ascii=False, indent=2) + '\n'); cfg_path.chmod(0o600)
        final_helper = build / 'cloud-sync'; shutil.copyfile(helper, final_helper); final_helper.chmod(0o755)
        setup = {'app': str(game), 'launch_env': {'TOTK_PROFILE_DIR': str(profile)},
                 'cloud_saves': {'enabled': True, 'helper': str(final_helper), 'config': str(cfg_path)}}
        setup_path.write_text(json.dumps(setup, ensure_ascii=False, indent=2) + '\n'); setup_path.chmod(0o600)
        os.rename(bundle, launcher)
    print(json.dumps({'status': 'ready', 'launcher': str(launcher), 'cloud_folder': str(cloud),
                      'seed_status': report['status'], 'backup_folder': str(state / 'backups')}, ensure_ascii=False, indent=2))
    if report['status'] == 'conflict':
        print('Two save histories exist; choose the desired copy in the launcher. Both are retained.')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
