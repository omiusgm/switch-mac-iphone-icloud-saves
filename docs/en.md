# BOTW 1.6.0 on Mac and iPhone with iCloud saves

[Русский](ru.md) · [Overview](../README.md) · [For agents](../AGENTS.md)

This is the reproducible recipe for one tested game and version. The underlying
[MacNativeGames project](https://github.com/ly05010419/MacNativeGames) supports
individual native ports; it is not a universal Switch emulator. Our iCloud
overlay must **not** be applied to a different game or BOTW version as though
its save format were interchangeable. See [adapting other games](other-games.md).

The example was checked on an Apple silicon Mac with 16 GB and macOS 27, and an
iPhone 15 Pro with iOS 27.0.1. BOTW 1.6.0 and two DLC packs were used. The game
loaded, its external image passed a full hash check, and 21 save files made a
real round trip across iCloud. Extended gameplay, every device and every network
condition were not tested. The iPhone setup dialogs in this overlay are in
Russian; translations appear below.

## 1. What you need

- An Apple silicon Mac. The pinned upstream requires macOS 26 or newer and
  recommends at least 16 GB RAM. A fresh updated iOS build needs about 60 GiB
  free on the Mac in addition to Xcode and the original inputs; use a separate work directory and allow more when APFS
  cloning is unavailable.
- An iPhone 14 or newer, or a compatible iPad, with iOS/iPadOS 26 or later.
  Allow about 25–30 GiB free for the example game, app, DLC and caches. Actual
  requirements depend on the inputs. Connect the device by USB for initial
  installation and data transfer.
- Your own BOTW base NSP/XCI and the 1.6.0 update NSP. For an NSP, provide your
  own compatible `prod.keys` and an unpacked firmware directory or previously
  extracted system shared fonts. The verified example also had both DLC packs;
  upstream supports builds without them, but that combination was not tested
  end to end with this overlay. No game, keys, firmware or compiled app is
  supplied here. Follow [upstream's input requirements](https://github.com/ly05010419/MacNativeGames/blob/ea1ce3b2be23540c4d67df95695f8c70f66cd8e0/docs/install.md#what-you-need).
- The same iCloud Drive account on the Mac and iPhone. The phone must have
  access to the Mac-created `Zelda BOTW` folder.
- [Full Xcode](https://apps.apple.com/us/app/xcode/id497799835), including the
  iOS SDK and Metal Toolchain, and [Homebrew](https://brew.sh/). Open Xcode and
  complete its first-run steps yourself. A simulator is not needed. Add your
  Apple Account under Xcode → Settings → Apple Accounts. On iPhone, enable
  [Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device),
  confirm the restart, and trust this Mac when prompted.

If the tools are not already installed, in a terminal:

```sh
brew install opus libvpx python@3.14 cmake ninja xcodegen
export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
xcodebuild -downloadComponent MetalToolchain
xcrun --sdk iphoneos --show-sdk-path
```

Set `DEVELOPER_DIR` to your actual Xcode Developer folder if it lives elsewhere.
The first build fetches pinned public build dependencies. The game and keys stay
local. Don't paste credentials, key values or device identifiers into chats,
issue reports or a GitHub repository.

## 2. Prepare a separate source checkout

```sh
git clone https://github.com/omiusgm/switch-mac-iphone-icloud-saves.git
cd switch-mac-iphone-icloud-saves
export BOTW_ROOT="$(pwd -P)"
export BOTW_UPSTREAM="$BOTW_ROOT/MacNativeGames"
git clone https://github.com/ly05010419/MacNativeGames.git "$BOTW_UPSTREAM"
git -C "$BOTW_UPSTREAM" checkout --detach ea1ce3b2be23540c4d67df95695f8c70f66cd8e0
python3.14 tools/apply_overlay.py "$BOTW_UPSTREAM" --check
python3.14 tools/apply_overlay.py "$BOTW_UPSTREAM"
python3.14 -m venv .venv
.venv/bin/pip install -r requirements.txt
MNG_TEST_REPO="$BOTW_UPSTREAM" sh tools/check.sh
```

The overlay refuses the wrong commit or conflicting overlay files. Keep this
checkout and its `work/` private: derived game files and build output are not
for publication. `tools/check.sh` tests synthetic profiles and a temporary
Mac launcher. It does not require your game files or modify your real profile.

## 3. Build and test the Mac game

Set these example paths to **your own** local files. `BOTW_FIRMWARE` is an
already-unpacked directory of firmware NCA files, not a ZIP. Use `--shared-fonts`
instead of `--firmware` if you have the six extracted fonts.

```sh
export BOTW_BASE="$HOME/Games/BOTW/base.nsp"
export BOTW_UPDATE="$HOME/Games/BOTW/update-1.6.0.nsp"
export BOTW_KEYS="$HOME/.switch/prod.keys"
export BOTW_FIRMWARE="$HOME/.switch/firmware"
export BOTW_MAC_APP="$HOME/Applications/Breath of the Wild.app"
mkdir -p "$HOME/Applications" "$BOTW_ROOT/work"

# Optional: add --dlc "$BOTW_DLC_1" --dlc "$BOTW_DLC_2" for your own two packs.
python3.14 "$BOTW_UPSTREAM/build_app.py" "$BOTW_BASE" -k "$BOTW_KEYS" \
  --update "$BOTW_UPDATE" --firmware "$BOTW_FIRMWARE" \
  --work "$BOTW_ROOT/work/macos" -o "$BOTW_MAC_APP"
```

Choose a new `BOTW_MAC_APP` path if you already have an app there; don't
overwrite an existing installation without a verified backup. Open the Mac app
once, create a game save and fully quit it. The default BOTW profile is
`~/Library/Application Support/MacNativeGames/BotW/profile`. Preserve a separate
backup of it before setup, especially if it contains existing progress.

## 4. Connect the Mac to iCloud

```sh
python3.14 tools/configure_macos.py --game-app "$BOTW_MAC_APP"
```

The tool checks that the game is closed, builds a local helper, seeds a dedicated
`iCloud Drive/Zelda BOTW` folder from your profile, and creates
`~/Applications/Play BOTW with iCloud.app`. It won't overwrite an existing
launcher or a nonempty unrelated cloud folder. To choose other locations, see
`python3.14 tools/configure_macos.py --help`. Local generated configuration and
build files are ignored by Git; keep them private anyway.

From now on, launch the Mac game through **Play BOTW with iCloud**. It checks
the folder before launch and publishes changes after the game closes. If the
game is already open, the helper refuses to replace its profile.

## 5. Build and verify the iPhone app

Close the game on both devices. Build in a separate iOS work folder:

```sh
# Include the same optional --dlc arguments you used for the Mac build.
python3.14 "$BOTW_UPSTREAM/build_app.py" "$BOTW_BASE" -k "$BOTW_KEYS" \
  --update "$BOTW_UPDATE" --firmware "$BOTW_FIRMWARE" \
  --platform ios --ios-game-data documents --no-shader-reminder \
  --work "$BOTW_ROOT/work/ios" -o "$BOTW_ROOT/work/BOTW.ipa"

.venv/bin/python tools/verify_ipa.py --ipa "$BOTW_ROOT/work/BOTW.ipa" \
  --work "$BOTW_ROOT/work/ios" --receipt "$BOTW_ROOT/work/ipa-verification.local.json"
```

The first build compiles a large shader set and may take a while. The overlay
packages the iPhone shaders in the IPA and leaves the large game image outside.
Verification checks the version, controller integration, shader hashes, fonts
and any DLC present in the work folder. It does not prove that the game will run
on a particular phone.

## 6. Sign, install and copy game data

Find your device name in Xcode Device Hub. Save and fully close Zelda on the
phone first. With an Apple Account already signed into Xcode:

```sh
.venv/bin/python tools/sign_install.py --ipa "$BOTW_ROOT/work/BOTW.ipa" \
  --receipt "$BOTW_ROOT/work/ipa-verification.local.json" \
  --device "My iPhone" --game-closed

.venv/bin/python tools/transfer_romfs.py \
  --image "$BOTW_ROOT/work/ios/totk/extracted/botw160/romfs/romfs.bin" \
  --game-closed
```

Use your actual device name. Signing may create an Apple Development certificate
and register the app identifier and device with Apple. Enter credentials and
confirm system prompts yourself. A Personal Team worked in the tested setup;
if your provisioning profile doesn't grant Increased Memory Limit, the helper
stops rather than pretending it does. Account and device capabilities can vary;
consult upstream if Xcode cannot create a compatible profile.

The transfer checks the local image against upstream's pinned SHA-256 and sends
1 GiB parts over the existing trusted USB connection. It checks part sizes and
the final marker, can resume an interrupted transfer, and refuses to overwrite
an unrecognised image. Keep the phone connected and unlocked. The game performs
its full device-side image hash on its first start. If iOS asks, trust your
developer profile in Settings → General → VPN & Device Management.

## 7. Select iCloud once and play

Open Zelda on the iPhone. In the first dialog choose **«Выбрать папку»**
(Choose folder), then **iCloud Drive → Zelda BOTW**, and confirm that folder.
The game checks and imports the Mac save before starting. If it finds two
different histories, choose the desired device's copy; both versions are kept.
If this is the first transfer of existing Mac progress, choose **Mac**.

| iPhone text | English |
|---|---|
| Сохранения iCloud | iCloud saves |
| Выбрать папку | Choose folder |
| Пока локально / Играть локально | Play locally for now |
| Какой прогресс продолжить? | Which save should be continued? |
| Повторить | Retry |
| Есть прогресс с другого устройства | A newer save from another device is available |
| Закрыть игру / Продолжить здесь | Close the game / Continue here |

On iPhone, save in the game and put the app in the background to publish changes.
On Mac, save and exit through the iCloud launcher. iCloud can take time to
deliver a snapshot. If a previously suspended iPhone game notices a newer Mac
save, it asks you to close and reopen the game before importing it; the running
game's files are not replaced underneath it.

For a read-only device check after launch:

```sh
python3.14 tools/status_phone.py --device "My iPhone"
```

The full-image proof record and the phone's local cloud status are evidence of
those stages, not by themselves proof that the Mac received the same revision.
With the Mac game fully closed, `build/cloud-sync before cloud/config.json`
checks/imports the latest visible cloud revision. Compare its `revision` with
`phone_revision` from the phone status after a completed publish. Confirm the
actual save in the game and retain separate backups.

## 8. Renewal and troubleshooting

Apple's [Personal Team profiles expire after seven days](https://developer.apple.com/help/account/basics/about-your-developer-account).
Repeat the **same** `sign_install.py` command before expiry with the same Apple
Account, team and bundle identifier. The app is installed over the existing
copy, so the app container, large game image, selected folder and saves should
remain. Keep backups and verify before replacing anything. A paid account's
capabilities and validity depend on its profile.

- No `Zelda BOTW` folder on iPhone: check that iCloud Drive is enabled on both
  devices, the same account is in use, and the Mac upload has finished.
- iCloud unavailable or partial upload: choose Retry, or explicitly play locally
  and retry later. Do not play both copies at once. A divergence is preserved and
  shown for a choice; see [sync details](sync.md).
- No USB device: unlock the phone, reconnect the cable and confirm existing
  Finder trust. The transfer tool never initiates a new pairing.
- Build/signing failure: check the pinned source, Xcode's full SDK and Metal
  Toolchain, free space, and the selected team. Do not disable signature checks.
- To choose the folder again: iPhone Settings → Apps → BotW → enable the iCloud
  folder selection option, then fully reopen the game.

When sharing a diagnostic, remove local paths, account/team/device IDs and
personal logs. Never upload the IPA, game data, keys or saves to an issue.
