#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/botw-cloud-check.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
xcrun swiftc -swift-version 5 -O -parse-as-library cloud/CloudSaveCore.swift cloud/CloudTests.swift -o "$test_dir/cloud-tests"
"$test_dir/cloud-tests"
sdk=$(xcrun --sdk iphoneos --show-sdk-path)
xcrun swiftc -swift-version 5 -target arm64-apple-ios26.0 -sdk "$sdk" -parse-as-library -typecheck cloud/CloudSaveCore.swift cloud/BOTWCloudController.swift
python3 -m unittest discover -s tests -v
