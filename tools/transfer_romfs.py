#!/usr/bin/env python3
"""Transfer a verified BOTW 1.6.0 RomFS to one already-trusted iPhone over USB."""
import argparse
import asyncio
import hashlib
import fcntl
import json
import os
from pathlib import Path
import subprocess
import tempfile

PART = 1 << 30
CHUNK = 4 << 20
ROOT = Path(__file__).resolve().parent.parent


class DeviceUnavailable(RuntimeError):
    pass


def source_identity(image):
    s = image.stat()
    return (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns)


def digest(image):
    result = hashlib.sha256()
    with image.open('rb') as source:
        while chunk := source.read(CHUNK):
            result.update(chunk)
    return result.hexdigest()


def ensure_stopped(serial):
    env = dict(os.environ)
    candidate = Path('/Applications/Xcode.app/Contents/Developer')
    if not env.get('DEVELOPER_DIR') and candidate.is_dir():
        env['DEVELOPER_DIR'] = str(candidate)
    with tempfile.TemporaryDirectory(prefix='botw-process-') as tmp:
        report = Path(tmp) / 'processes.json'
        try:
            r = subprocess.run(['xcrun', 'devicectl', 'device', 'info', 'processes', '--device', serial,
                                '--search', '/TOTK.app/TOTK', '--json-output', str(report)],
                               env=env, capture_output=True, timeout=30)
        except subprocess.TimeoutExpired:
            raise DeviceUnavailable('Timed out checking the iPhone. Connect and unlock it.') from None
        if r.returncode or not report.is_file():
            raise DeviceUnavailable('Cannot verify iPhone processes. Connect and unlock the iPhone.')
        processes = json.loads(report.read_text()).get('result', {}).get('runningProcesses')
        if not isinstance(processes, list):
            raise RuntimeError('The device process response has an unexpected format; no transfer started.')
        if processes:
            raise RuntimeError('Save and fully close Zelda on iPhone before transferring game data.')


async def push_image(afc, image, expected, identity=None):
    directory = '/Documents/GameData'
    if not await afc.exists(directory):
        await afc.makedirs(directory)
    marker = directory + '/romfs.sha256'
    previous = (await afc.get_file_contents(marker)).decode().strip() if await afc.exists(marker) else ''
    size = image.stat().st_size
    parts = (size + PART - 1) // PART
    names = [directory + f'/romfs.bin.{i:03d}' for i in range(parts)]
    sizes = [min(PART, size - i * PART) for i in range(parts)]
    existing = [int((await afc.stat(name))['st_size']) if await afc.exists(name) else -1 for name in names]
    if previous == expected and existing == sizes:
        return {'status': 'already-present', 'parts': parts, 'bytes': size}
    if previous not in ('', expected, 'copying ' + expected):
        raise RuntimeError('A different image is on the phone; it was not overwritten.')
    if not previous and any(v >= 0 for v in existing):
        raise RuntimeError('An unrecognised partial image is on the phone; it was not overwritten.')
    await afc.set_file_contents(marker, ('copying ' + expected + '\n').encode())
    with image.open('rb') as source:
        for i, (name, length) in enumerate(zip(names, sizes)):
            if previous in (expected, 'copying ' + expected) and existing[i] == length:
                source.seek(length, 1); print(f'Part {i + 1}/{parts}: already present', flush=True); continue
            handle = await afc.fopen(name, 'w')
            try:
                left = length
                while left:
                    data = source.read(min(CHUNK, left))
                    if not data:
                        raise RuntimeError('The source image ended unexpectedly.')
                    await afc.fwrite(handle, data, chunk_size=CHUNK); left -= len(data)
            finally:
                await afc.fclose(handle)
            if int((await afc.stat(name))['st_size']) != length:
                raise RuntimeError('Part size differs; a retry can resume.')
            print(f'Part {i + 1}/{parts}: copied', flush=True)
    if identity is not None and source_identity(image) != identity:
        raise RuntimeError('The source changed during transfer; the incomplete marker was retained.')
    await afc.set_file_contents(marker, (expected + '\n').encode())
    if (await afc.get_file_contents(marker)).decode().strip() != expected:
        raise RuntimeError('The final transfer marker could not be read back.')
    return {'status': 'sizes-and-marker-verified', 'parts': parts, 'bytes': size,
            'full_device_hash_check': 'performed by the game on first launch'}


async def transfer(image, expected, selected_serial, selected_bundle, identity):
    from pymobiledevice3.usbmux import list_devices
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.installation_proxy import InstallationProxyService
    from pymobiledevice3.services.house_arrest import HouseArrestService
    devices = [d for d in await list_devices() if d.connection_type == 'USB' and
               (not selected_serial or d.serial == selected_serial)]
    if len(devices) != 1:
        raise DeviceUnavailable('Connect exactly one unlocked iPhone via USB, or specify --serial.')
    serial = devices[0].serial
    ensure_stopped(serial)
    lockdown = await create_using_usbmux(serial=serial, autopair=False, connection_type='USB')
    try:
        if not lockdown.paired or not lockdown.session_id:
            raise DeviceUnavailable('Existing device trust is required; confirm trust in Finder on the iPhone.')
        async with InstallationProxyService(lockdown) as proxy:
            apps = await proxy.browse(attributes=['CFBundleIdentifier', 'CFBundleShortVersionString'])
        matches = [a for a in apps if 'macnativegames.botw' in str(a.get('CFBundleIdentifier', '')) and
                   (not selected_bundle or a.get('CFBundleIdentifier') == selected_bundle)]
        if len(matches) != 1 or matches[0].get('CFBundleShortVersionString') != '1.6.0':
            raise RuntimeError('Exactly one matching installed BOTW 1.6.0 app is required; use --bundle-id if needed.')
        async with await HouseArrestService.create(lockdown, matches[0]['CFBundleIdentifier'], documents_only=True) as afc:
            return await push_image(afc, image, expected, identity)
    finally:
        await lockdown.close()


async def run(args):
    from pymobiledevice3.exceptions import ConnectionTerminatedError, ConnectionFailedError, NoDeviceConnectedError
    image = args.image.expanduser().resolve()
    expected_file = args.upstream.expanduser().resolve() / 'games/botw/assets/expected-v1.6.0.json'
    expected = json.loads(expected_file.read_text())['romfs']['sha256']
    before = source_identity(image)
    print('Verifying the local game image; this can take time…', flush=True)
    if digest(image) != expected or source_identity(image) != before:
        raise ValueError('Source image does not match the pinned BOTW 1.6.0 digest; phone unchanged.')
    for attempt in range(1, 7):
        if source_identity(image) != before:
            raise RuntimeError('Source image changed during transfer; retry after verifying it again.')
        try:
            result = await transfer(image, expected, args.serial, args.bundle_id, before)
            if source_identity(image) != before:
                raise RuntimeError('Source image changed during transfer; do not launch the game.')
            print(json.dumps(result, ensure_ascii=False, indent=2)); return
        except (DeviceUnavailable, ConnectionTerminatedError, ConnectionFailedError, NoDeviceConnectedError, ConnectionError, OSError):
            if attempt == 6:
                raise
            print(f'Connection interrupted. Retrying ({attempt + 1}/6); keep the phone unlocked.', flush=True)
            await asyncio.sleep(5)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--image', type=Path, required=True, help='romfs.bin extracted by the pinned builder')
    parser.add_argument('--upstream', type=Path, default=ROOT / 'MacNativeGames')
    parser.add_argument('--serial', help='optional device identifier; do not post it publicly')
    parser.add_argument('--bundle-id', help='optional bundle identifier when multiple copies are installed')
    parser.add_argument('--game-closed', action='store_true', help='confirm Zelda is fully closed')
    args = parser.parse_args()
    if not args.game_closed:
        parser.error('Save, fully close the game on iPhone and pass --game-closed.')
    try:
        locks = Path.home() / 'Library/Application Support/BOTW-iCloud/locks'
        locks.mkdir(parents=True, exist_ok=True, mode=0o700)
        fd = os.open(locks / 'romfs-transfer.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'a') as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise RuntimeError('Another BOTW transfer is already running.')
            asyncio.run(run(args))
    except Exception as error:
        raise SystemExit(str(error))
