"""Package the completed Payload deterministically, retaining executable modes and verifying the entry list."""
from pathlib import Path
import argparse
import os
import zipfile


def package(payload, output):
    payload, output = Path(payload).resolve(), Path(output).resolve()
    paths = list(payload.rglob('*'))
    for path in paths:
        if path.is_symlink() or not (path.is_file() or path.is_dir()):
            raise ValueError('Unexpected link or special file in the application: ' + str(path.relative_to(payload)))
    files = sorted(path for path in paths if path.is_file())
    if not files or not (payload / 'Payload/TOTK.app/Info.plist').is_file():
        raise ValueError('No complete application payload')
    temporary = output.with_suffix('.partial.ipa')
    output.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, 'wb') as stream:
            with zipfile.ZipFile(stream, 'w', compression=zipfile.ZIP_STORED, allowZip64=True, strict_timestamps=False) as archive:
                for index, path in enumerate(files, 1):
                    archive.write(path, path.relative_to(payload).as_posix())
                    if index % 20000 == 0:
                        print(f'Packed app files: {index}/{len(files)}', flush=True)
        with zipfile.ZipFile(temporary) as archive:
            if len(archive.namelist()) != len(files):
                raise ValueError('Archive entry count does not match the payload')
        os.replace(temporary, output)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise
    print(f'IPA packaged: {output.stat().st_size} bytes; {len(files)} files', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('payload', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    package(args.payload, args.output)
