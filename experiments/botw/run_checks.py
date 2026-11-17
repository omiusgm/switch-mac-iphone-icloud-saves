#!/usr/bin/env python3
"""Offline source checks; only synthetic temporary profiles, no devices or game."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent


def run(args):
    subprocess.run([str(a) for a in args], check=True, cwd=ROOT)


def main():
    manifest = json.loads((ROOT / "source-manifest.json").read_text())
    for item in manifest["files"]:
        assert hashlib.sha256((ROOT / item["file"]).read_bytes()).hexdigest() == item["sha256"], item["file"]
    print("PASS preserved source hashes", flush=True)
    with tempfile.TemporaryDirectory(prefix="botw-source-checks-") as temp:
        work = Path(temp)
        for suite in ["CloudTests", "CloudRecoveryTests"]:
            exe = work / suite
            run(["xcrun", "swiftc", "-O", ROOT / "cloud/CloudSaveCore.swift", ROOT / ("cloud/" + suite + ".swift"), "-o", exe])
            run([exe])
        # macOS public declarations suffice for this host-only synthetic fixture.
        (work / "mach_vm_compat.h").write_text("#include <mach/mach_vm.h>\n")
        sources = [ROOT / "backend/botw_touch_state.c", ROOT / "backend/botw_touch_icons.c"]
        for name, flags in [("snapshot", ["-DBOTW_TOUCH_TEST=1"]), ("disabled", [])]:
            exe = work / name
            run(["xcrun", "--sdk", "macosx", "clang", "-std=c11", "-O1", "-g",
                 "-fsanitize=address,undefined", "-Wall", "-Wextra", "-Werror", *flags,
                 "-I", ROOT / "backend", "-I", work, ROOT / ("tests/" + name + ".c"), *sources, "-o", exe])
            run([exe])
        exe = work / "viewport"
        run(["xcrun", "clang", "-std=c11", "-Wall", "-Wextra", "-Werror", "-I", ROOT / "screenfit",
             "-I", ROOT / "ui", ROOT / "tests/test_viewport.c", "-lm", "-o", exe])
        run([exe])
        sdk = subprocess.run(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-path"],
                             check=True, text=True, capture_output=True).stdout.strip()
        for source in ["BOTWSheikahHUD.m", "BOTWSheikahEditor.m", "BOTWGraphicsSettings.m", "touch_pad.m"]:
            run(["xcrun", "--sdk", "iphonesimulator", "clang", "-target", "arm64-apple-ios26.0-simulator",
                 "-isysroot", sdk, "-fobjc-arc", "-fsyntax-only", "-DGAME_BOTW160", "-DGAME_BOTW",
                 "-I", ROOT / "ui", ROOT / ("ui/" + source)])
        print("PASS UIKit source syntax (no linking, simulator launch or game build)")


if __name__ == "__main__":
    main()
