from pathlib import Path
import json
import os
import subprocess
import time
import shutil
import sys
import tempfile

if "--isolated-child" not in sys.argv:
    with tempfile.TemporaryDirectory(prefix="botw-launcher-fixtures-") as directory:
        root = Path(directory).resolve()
        for name in ("profile_launcher.m", "fixture_tests.m", "fixture.sh", "run_fixtures.py"):
            shutil.copy2(Path(__file__).resolve().parent / name, root / name)
        home = root / "home"
        home.mkdir()
        env = os.environ.copy()
        env.update(HOME=str(home), TMPDIR=str(root))
        env.pop("BOTW_SETUP_CONFIG", None)
        subprocess.run([sys.executable, str(root / "run_fixtures.py"), "--isolated-child"], env=env, cwd=root, check=True)
    raise SystemExit(0)

root = Path(__file__).resolve().parent
if (not root.name.startswith("botw-launcher-fixtures-") or
        os.environ.get("HOME") != str(root / "home") or
        os.environ.get("TMPDIR") != str(root) or "BOTW_SETUP_CONFIG" in os.environ):
    raise RuntimeError("Fixtures require the isolated temporary home created by this script")
compiler = [
    "clang", "-fobjc-arc", "-Wall", "-Wextra", "-Werror",
    "-Wno-sign-compare", "-Wno-incompatible-pointer-types", "-framework", "Cocoa",
]
binary = root / "fixture_tests"
subprocess.run([*compiler, root / "fixture_tests.m", "-o", binary], check=True)

scenarios = (
    "check", "missing-game-check", "lock-public", "lock-hardlink", "disabled", "fast", "slow", "malformed",
    "missing-helper", "launch-failure", "nonzero-json", "signalled-json", "missing-status",
    "empty-status", "unknown-status", "wrong-status", "bad-choice", "valid-empty",
    "valid-imported", "offline", "cancel", "choose", "choose-conflict", "post", "bad-post",
)
for scenario in scenarios:
    result = subprocess.run([binary, root, scenario], stdout=subprocess.PIPE, text=True, check=True, timeout=15)
    if scenario == "check":
        launch = json.loads(result.stdout)
        assert launch[:4] == ["/usr/bin/caffeinate", "-i", "/usr/bin/open", "-W"]
        assert launch[-1] == str(root / "check" / "Applications" / "Breath of the Wild.app")
    else:
        assert not result.stdout, result.stdout

def assert_exited(pid_file):
    pid = int(pid_file.read_text())
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return
    raise AssertionError(f"fixture helper {pid} survived its launcher")

for scenario, reply in (("quit", "yes"), ("quit-timeout", "no")):
    prefix = f"{scenario}.marker"
    for file in root.glob(f"{prefix}*"):
        file.unlink()
    subprocess.run([binary, root, scenario], check=True, timeout=15)
    assert (root / prefix).read_text() == "writer completed\n"
    assert (root / f"{prefix}.reply-{reply}").exists()
    assert_exited(root / f"{prefix}.pid")
    print(f"PASS {scenario} (reply={reply}, helper exited)", flush=True)

prefix = "lifecycle-first.marker"
for file in root.glob(f"{prefix}*"):
    file.unlink()
with subprocess.Popen([binary, root, "lifecycle-first"]) as first:
    for phase in ("before", "game", "after"):
        entered = root / f"{prefix}.entered-{phase}"
        deadline = time.monotonic() + 7
        while not entered.exists():
            assert first.poll() is None and time.monotonic() < deadline, phase
            time.sleep(0.02)
        subprocess.run([binary, root, "lifecycle-second"], check=True, timeout=5)
        (root / f"{prefix}.allow-{phase}").touch()
    assert first.wait(timeout=7) == 0
for phase in ("before", "game", "after"):
    assert_exited(root / f"{prefix}.entered-{phase}")
# The same stage home can launch again after the complete lifecycle.
subprocess.run([binary, root, "lifecycle-first"], check=True, timeout=7)
print("PASS lifecycle lock (before, game, after, reacquired)", flush=True)
print(f"Passed all {len(scenarios) + 3} offscreen fixture cases", flush=True)
