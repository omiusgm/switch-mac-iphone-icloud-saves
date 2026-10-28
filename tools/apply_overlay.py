#!/usr/bin/env python3
"""Apply the BOTW 1.6.0 overlay only to the exact, compatible upstream commit."""
import argparse
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent
COMMIT = 'ea1ce3b2be23540c4d67df95695f8c70f66cd8e0'
PATCH = ROOT / 'overlays/macnativegames-botw160.patch'
TRACKED = ['build_app.py', 'games/totk/Makefile', 'games/totk/ios/Settings.bundle/Root.plist',
           'games/totk/ios/Sources/main.m', 'games/totk/ios/project.yml', 'games/totk/ios/tools/build_ipa.py']
FILES = {
    ROOT / 'cloud/CloudSaveCore.swift': 'games/totk/ios/Sources/CloudSaveCore.swift',
    ROOT / 'cloud/BOTWCloudController.swift': 'games/totk/ios/Sources/BOTWCloudController.swift',
    ROOT / 'overlays/package_ipa.py': 'games/totk/ios/tools/package_ipa.py',
}


def run(*args, cwd, check=True):
    return subprocess.run(args, cwd=cwd, text=True, capture_output=True, check=check)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('upstream', type=Path, help='separate MacNativeGames checkout')
    parser.add_argument('--check', action='store_true', help='check only; do not change the checkout')
    args = parser.parse_args()
    upstream = args.upstream.expanduser().resolve()
    head = run('git', 'rev-parse', 'HEAD', cwd=upstream).stdout.strip()
    if head != COMMIT:
        raise RuntimeError(f'Expected upstream commit {COMMIT}; found {head}. Use a separate pinned checkout.')
    forward = run('git', 'apply', '--check', str(PATCH), cwd=upstream, check=False).returncode == 0
    reverse = run('git', 'apply', '--reverse', '--check', str(PATCH), cwd=upstream, check=False).returncode == 0
    if not forward and not reverse:
        raise RuntimeError('The upstream files differ from the expected patch. No changes made.')
    staged = run('git', 'diff', '--cached', '--quiet', '--', *TRACKED, cwd=upstream, check=False).returncode
    working = run('git', 'diff', '--binary', '--', *TRACKED, cwd=upstream).stdout.encode()
    if staged != 0 or (forward and working) or (reverse and not forward and working != PATCH.read_bytes()):
        raise RuntimeError('The targeted upstream files have other local edits. No changes made.')
    for src, destination in FILES.items():
        target = upstream / destination
        if not target.resolve().is_relative_to(upstream):
            raise RuntimeError(f'Overlay destination escapes the checkout: {destination}. No changes made.')
        if target.is_symlink() or (target.exists() and (not target.is_file() or target.read_bytes() != src.read_bytes())):
            raise RuntimeError(f'Existing overlay file differs: {destination}. No changes made.')
    if args.check:
        missing = [destination for destination in FILES.values() if not (upstream / destination).exists()]
        if reverse and not forward and missing:
            print('Patch is present, but overlay files still need to be copied.')
        else:
            print('Overlay already applied and compatible.' if reverse and not forward else 'Overlay can be applied cleanly.')
        return
    if forward:
        run('git', 'apply', str(PATCH), cwd=upstream)
    for src, destination in FILES.items():
        target = upstream / destination
        if not target.exists():
            target.parent.mkdir(parents=True, exist_ok=True)
            with src.open('rb') as source, target.open('xb') as output:
                shutil.copyfileobj(source, output)
    print('BOTW 1.6.0 overlay ready. Existing game files and saves were not accessed.')


if __name__ == '__main__':
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
