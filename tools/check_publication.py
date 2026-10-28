#!/usr/bin/env python3
"""Check candidate Git files for obvious secrets, personal paths and game artifacts."""
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
FORBIDDEN_SUFFIXES = {'.nsp', '.nsz', '.xci', '.xcz', '.nca', '.keys', '.bfttf', '.sav', '.ipa', '.p12', '.pfx', '.mobileprovision'}
CHECKS = {
    'personal macOS path': re.compile(r'/' + r'Users' + r'/[^/\s]+/'),
    'private-key block': re.compile(r'-----BEGIN (?:RSA |EC |OPENSSH |ENCRYPTED )?PRIVATE KEY-----'),
    'GitHub token': re.compile(r'\b(?:gh[pousr]_[A-Za-z0-9_]{30,}|github_pat_[A-Za-z0-9_]{30,})\b'),
    'console key value': re.compile(r'(?im)^\s*(?:master_key_\w+|key_area_key_\w+|titlekek_\w+|header_key|title_key)\s*=\s*[0-9a-f]{16,}'),
}


def main():
    raw = subprocess.run(['git', 'ls-files', '--cached', '--others', '--exclude-standard', '-z'],
                         cwd=ROOT, capture_output=True, check=True).stdout
    paths = sorted({Path(p) for p in raw.decode().split('\0') if p})
    problems = []
    for relative in paths:
        path = ROOT / relative
        if path.is_symlink() or not path.is_file():
            problems.append((str(relative), 'link or non-file')); continue
        if relative.suffix.lower() in FORBIDDEN_SUFFIXES or path.stat().st_size > 512 * 1024:
            problems.append((str(relative), 'game/credential file or oversized artifact')); continue
        try: text = path.read_text(encoding='utf-8')
        except UnicodeError:
            problems.append((str(relative), 'non-text artifact')); continue
        if '\0' in text: problems.append((str(relative), 'binary content'))
        for label, pattern in CHECKS.items():
            if pattern.search(text): problems.append((str(relative), label))
    if problems:
        for name, reason in problems: print(f'{name}: {reason}')
        return 1
    print(f'Publication scan passed for {len(paths)} candidate text files. Review content and history as well.')
    return 0


if __name__ == '__main__': sys.exit(main())
