#!/usr/bin/env python3
"""Verify the source-only workflow's completed BOTW 1.6.0 IPA before signing."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import plistlib
import re
import struct
import zipfile


def digest(stream):
    h = hashlib.sha256()
    while chunk := stream.read(4 << 20): h.update(chunk)
    return h.hexdigest()


def verify(ipa, work):
    ipa, work = Path(ipa).resolve(), Path(work).resolve()
    before = ipa.stat(); prefix = 'Payload/TOTK.app/'
    with zipfile.ZipFile(ipa) as z:
        entries = z.infolist(); names = [i.filename for i in entries]
        if len(entries) > 200000 or len(names) != len(set(names)):
            raise ValueError('Unexpected number of entries or duplicate paths.')
        for name in names:
            p = PurePosixPath(name)
            if p.is_absolute() or '..' in p.parts or '\\' in name or not name.startswith('Payload/'):
                raise ValueError('Unsafe archive path.')
            if p.suffix.lower() in ('.keys', '.nsp', '.nca'):
                raise ValueError('Raw keys or game packages must not be packaged in the IPA.')
        info = plistlib.loads(z.read(prefix + 'Info.plist'))
        if info.get('CFBundleIdentifier') != 'org.macnativegames.botw' or info.get('CFBundleShortVersionString') != '1.6.0':
            raise ValueError('Expected the unsigned BOTW 1.6.0 app from the pinned overlay.')
        if not info.get('UIFileSharingEnabled') or not info.get('LSSupportsOpeningDocumentsInPlace'):
            raise ValueError('App file sharing is unavailable.')
        settings = plistlib.loads(z.read(prefix + 'Settings.bundle/Root.plist'))
        if not any(x.get('Key') == 'BOTWCloudChooseFolder' for x in settings['PreferenceSpecifiers']):
            raise ValueError('The iCloud folder setup setting is missing.')
        executable = prefix + info['CFBundleExecutable']
        wanted = [b'BOTWCloudController', b'prepareWithPresenter:profile:completion:']; found = set()
        with z.open(executable) as binary:
            header = binary.read(8)
            if len(header) != 8 or struct.unpack('<II', header) != (0xfeedfacf, 0x100000c):
                raise ValueError('The executable is not an arm64 Mach-O.')
            tail = header
            while chunk := binary.read(4 << 20):
                block = tail + chunk; found.update(value for value in wanted if value in block); tail = block[-256:]
        if len(found) != len(wanted): raise ValueError('The iCloud controller is missing from the executable.')
        if any(name.startswith(prefix + 'GameData/romfs/romfs.bin') for name in names):
            raise ValueError('The large game image must be outside the IPA in this workflow.')
        seed = prefix + 'GameData/shader-seed/'
        if z.getinfo(seed + 'seed-manifest.json').file_size > 64 << 20: raise ValueError('Shader manifest is too large.')
        manifest = json.loads(z.read(seed + 'seed-manifest.json')); files = manifest['files']
        libraries = [name for name in files if name.endswith('.metallib')]
        if not libraries or manifest.get('ios_metallibs') != len(libraries) or manifest.get('ios_sdk') != 'iphoneos':
            raise ValueError('The iPhone shader libraries are incomplete.')
        for index, (name, expected) in enumerate(files.items(), 1):
            if PurePosixPath(name).name != name or name in ('.', '..') or '\\' in name or not re.fullmatch('[0-9a-f]{64}', expected):
                raise ValueError('Unsafe shader entry or digest.')
            with z.open(seed + name) as source:
                if digest(source) != expected: raise ValueError('Shader digest mismatch: ' + name)
            if index % 10000 == 0: print(f'Checked shader files: {index}', flush=True)
        aoc = work / 'totk/extracted/botw160/aoc'
        local_packs = sorted(p.name for p in aoc.iterdir() if p.is_dir() and (p / 'romfs.bin').is_file()) if aoc.is_dir() else []
        bundled_packs = sorted({name[len(prefix + 'GameData/aoc/'):].split('/')[0] for name in names if name.startswith(prefix + 'GameData/aoc/')})
        if local_packs != bundled_packs: raise ValueError('Bundled DLC packs do not match the work folder.')
        for pack in local_packs:
            for name in ('romfs.bin', 'runtime-index.bin'):
                with (aoc / pack / name).open('rb') as source: expected = digest(source)
                with z.open(prefix + f'GameData/aoc/{pack}/{name}') as source:
                    if digest(source) != expected: raise ValueError('DLC data does not match the work folder.')
        fonts = sorted((work / 'totk/extracted/firmware/shared-fonts').glob('*.bfttf'))
        if len(fonts) != 6: raise ValueError('The work folder does not contain all six system fonts.')
        for font in fonts:
            with font.open('rb') as source: expected = digest(source)
            with z.open(prefix + 'GameData/shared-fonts/' + font.name) as source:
                if digest(source) != expected: raise ValueError('System font does not match the work folder.')
        for name in ('pso_list.tsv', 'pso_title.tsv'): z.getinfo(seed + name)
    after = ipa.stat()
    if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
        raise ValueError('The IPA changed during verification.')
    with ipa.open('rb') as source: sha = digest(source)
    return {'status': 'pass', 'game_version': '1.6.0', 'cloud_saves_integrated': True,
            'ipa_size': after.st_size, 'ipa_mtime_ns': after.st_mtime_ns, 'sha256': sha,
            'shader_files_verified': len(files), 'iphone_metallibs': len(libraries),
            'dlc_packs_verified': len(local_packs), 'game_image_is_external': True}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--ipa', type=Path, required=True)
    parser.add_argument('--work', type=Path, required=True, help='the iOS build work folder')
    parser.add_argument('--receipt', type=Path, help='optional local receipt; keep it private')
    args = parser.parse_args()
    try:
        report = verify(args.ipa, args.work)
        if args.receipt:
            args.receipt.parent.mkdir(parents=True, exist_ok=True)
            args.receipt.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n'); args.receipt.chmod(0o600)
        print(json.dumps(report, ensure_ascii=False, indent=2))
    except (OSError, ValueError, KeyError, zipfile.BadZipFile) as error:
        raise SystemExit(str(error))
