# Fire Emblem save-sync experiment

[Русский](README.md)

This directory preserves source from a separate Fire Emblem: Three Houses 1.2.0 macOS and iOS experiment. It is **not an installer**. The local work used [nxnative](https://github.com/seedds/nxnative) at commit `beea17cfdbd8fe6112de9d1c191c0488da7970bf`. This directory includes two alternative partial integration patches. Applying them requires a separate review of integration, paths and the actual build's behavior.

- `src/CloudSaveCore.swift`: snapshot, local-state and backup engine.
- `src/CloudCLI.swift` and `src/FEProfileLauncher.m`: experimental macOS helper and launcher.
- `src/FECloudController.swift`: experimental iOS folder selection and lifecycle controller.
- `tests/CloudTests.swift` and `tests/run.sh`: local engine checks using synthetic data.

On macOS with Xcode Command Line Tools and Swift, run `./tests/run.sh` from this directory. It compiles into a temporary directory; the test creates and removes separate temporary profiles. It does not access real saves, iCloud or devices. The checks cover, among other cases, synthetic exchanges, divergent history, backups, corrupt or missing payloads, and symbolic links.

A passing test does not establish real iCloud behavior, real conflict resolution, game launch, iPhone or iPad operation, or exchange between devices. This test does not exercise the launcher or iOS controller. Real use requires separate integration and verification with backups, including actual delivery and receipt. Do not apply this code directly to an existing profile on the basis of this test.

Separate iOS-controller typechecking with the iOS 26 SDK and Swift 5 passed
with warnings about capturing `CloudSaveEngine` in `@Sendable` closures. This
is not an app build or proof of thread safety; review it before enabling strict
Swift concurrency.

Game data, translation mods, saves, keys, signed applications, credentials and private configuration are excluded. The code uses Apple system APIs and is not a general solution for other games.

## Partial nxnative patches

`patches/ios-cloud-touch.patch` connects the cloud controller and adds touch gestures. `patches/ios-graphics-cloud-touch.patch` is the corresponding graphics-branch version with graphics menu and Metal changes. They are alternative snapshots against the pinned commit: **choose one and do not apply them sequentially**. Changes that package an external translation and game resources are excluded. These patches do not reproduce the complete local builds.

In a separate clean nxnative checkout at the exact commit above, run `git apply --check /path/to/chosen.patch`, then, only for a separate experimental build, `git apply /path/to/chosen.patch`. Copy `src/CloudSaveCore.swift` and `src/FECloudController.swift` into `dm/ios/Sources/`: these were new files and are not included in the diff. Confirm the build includes the Swift files and links `fe_cloud_prepare`. Both patches passed an applicability check on a temporary archive of the pinned commit, without building or launching a game. The tests in this directory do not exercise the UI or rendering changes.

## Translation and DLC

The translation mod and DLC files are kept outside this repository. In one
local iOS build, 1,904 translation files and six DLC images were checked
against their source files. This verifies file contents, not DLC translation
coverage, translation on macOS, or gameplay after a new build.

The partial public patches do not include external translation integration.
For your own build, use files compatible with your game version and verify the
integration separately. Back up your mods, DLC and progress before updating;
do not publish game data, keys or save files.

## Attribution and licence

The patches contain portions of nxnative, copyright 2026 seedds, MIT licensed: [licenses/nxnative-MIT.txt](licenses/nxnative-MIT.txt). This experiment is not an official part of nxnative. The repository's main licence covers its own project materials; third-party components retain their respective rights. Fire Emblem and Nintendo are trademarks of their respective owners; this project is unaffiliated with them.
