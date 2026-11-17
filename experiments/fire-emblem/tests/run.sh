#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/fe-cloud-test.XXXXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
xcrun swiftc "$root/src/CloudSaveCore.swift" "$root/tests/CloudTests.swift" -o "$tmp/cloud-tests"
"$tmp/cloud-tests"
