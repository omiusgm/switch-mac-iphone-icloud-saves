#!/usr/bin/env python3
"""Check patch application against pinned source blobs in disposable directories."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent
UPSTREAM = "ea1ce3b2be23540c4d67df95695f8c70f66cd8e0"
PUBLISHED = "0550c96dcc35703e777df58b114ee3828d5ba03a"


def git_blob(repo, commit, path):
    return subprocess.run(["git", "-C", str(repo), "show", commit + ":" + path],
                          check=True, capture_output=True).stdout


def verify(upstream):
    for name in ["touch-backend", "touch-ui-reference"]:
        expected = json.loads((ROOT / ("patches/" + name + "-files.json")).read_text())
        with tempfile.TemporaryDirectory(prefix="botw-source-patch-") as temp:
            work = Path(temp)
            for relative, hashes in expected.items():
                if hashes["before_sha256"] is None:
                    continue
                raw = git_blob(upstream, UPSTREAM, relative)
                assert hashlib.sha256(raw).hexdigest() == hashes["before_sha256"], relative
                target = work / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(raw)
            patch = ROOT / ("patches/" + name + ".patch")
            subprocess.run(["git", "apply", "--check", str(patch)],
                           cwd=work, check=True, capture_output=True)
            subprocess.run(["git", "apply", str(patch)],
                           cwd=work, check=True, capture_output=True)
            for relative, hashes in expected.items():
                assert hashlib.sha256((work / relative).read_bytes()).hexdigest() == hashes["after_sha256"], relative
        print("PASS " + name + ": git apply --check and exact output hashes on pinned source")
    published_repo = ROOT.parent.parent
    with tempfile.TemporaryDirectory(prefix="botw-recovery-patch-") as temp:
        work = Path(temp)
        target = work / "cloud/CloudSaveCore.swift"
        target.parent.mkdir()
        target.write_bytes(git_blob(published_repo, PUBLISHED, "cloud/CloudSaveCore.swift"))
        patch = ROOT / "cloud/published-core-recovery.patch"
        subprocess.run(["git", "apply", "--check", str(patch)],
                       cwd=work, check=True, capture_output=True)
        subprocess.run(["git", "apply", str(patch)],
                       cwd=work, check=True, capture_output=True)
        assert target.read_bytes() == (ROOT / "cloud/CloudSaveCore.swift").read_bytes()
    print("PASS recovery patch: exact published base reconstructed in a temporary directory")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--upstream", type=Path, required=True)
    verify(parser.parse_args().upstream)
