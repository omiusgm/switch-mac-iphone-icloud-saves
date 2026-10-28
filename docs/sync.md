# Save sync: format, safety and limits

This document describes the **BOTW 1.6.0** overlay included here. It is not a
general save format for Switch games. The code used on the Mac and iPhone is
[CloudSaveCore.swift](../cloud/CloudSaveCore.swift); the iPhone lifecycle and
folder picker are in [BOTWCloudController.swift](../cloud/BOTWCloudController.swift).

## Data and profile layout

The Mac profile is normally `~/Library/Application Support/MacNativeGames/BotW/profile`.
On iPhone the native port sets `TOTK_PROFILE_DIR` to `Documents/save`. Both
contain a 16-byte `account.uid` and `save/<uid>/…` beneath that profile root.
The UID directory is derived from the file's little-endian values; a mismatched
profile is rejected. Only `account.uid` and files under `save/` are synchronized.
Images of the game, keys, shader caches, other app data and device identifiers
are not part of a save snapshot. Symlinks, path traversal, unexpected profile
entries, more than 4,000 files or more than 128 MiB are rejected.

The shared iCloud folder is created with `ZeldaCloud.json` and contains:

- `Objects/<sha256>`: immutable, content-addressed file bytes;
- `Snapshots/<uuid>.json`: a versioned manifest with hashes and parent IDs;
- `Devices/<random-uuid>.json`: each installation's latest revision pointer.

The UUIDs are locally generated sync identities, not hardware serial numbers.
Identical save files are reused across snapshots. Revisions and objects are not
automatically deleted. The folder contains game progress, so it belongs in the
owner's private iCloud Drive; don't publish or share it without their request.

## Publication and import

On Mac, the launcher runs `before` while the game is closed, starts the game,
waits for it to exit and then runs `after`. It blocks `before`, `seed`, `after`
and `resolve` if a process inside the game app is running. On iPhone, the cloud
check finishes before the native game thread starts; backgrounding the app
publishes a stable snapshot. The owner chooses the iCloud folder once with the
system document picker and can revoke that folder permission in iOS settings.
The iPhone controller serializes engine operations on one queue; only
`cancel()` is designed to be called from another thread. The included project
builds in Swift 5 language mode and can emit Sendable warnings with newer SDKs.
The Mac running-process check is best effort, not a lock honored by a game
started independently at the exact same moment. Use the provided launcher and
don't start another game instance while synchronization is in progress.

The engine validates version, UID, paths, file count, size and SHA-256 before
import. Existing local profiles are atomically exchanged with a verified staged
profile; the former directory is moved to a local backup. An image/header or
blob that has not arrived yet causes a retry or an explicit local-play choice,
not an import of incomplete data. The Mac helper retries transient missing
files for up to 20 seconds. A local acknowledgement from the file provider
does not prove the other device has received the bytes.

If two visible device heads diverge, both branches are retained and the user
chooses one. A new revision records both parents. Equal-content branches can
be reconciled automatically. The conflict dialog presents current tips; older
revisions and local backups remain on disk, but there is no full historical
restore browser in this release. Keep independent backups as well.

## iCloud and background limitations

iCloud is asynchronous. The phone can be suspended before an upload finishes,
and file-provider notifications and network state can lag. A local publish is
not proof of remote delivery; verify the receiving device before relying on a
new save. If a publication doesn't finish, local data remains and the next full
launch can retry. Avoid simultaneous or offline play on both devices. The
version graph detects divergences once both heads are visible, but it is not a
cross-device lock, a global compare-and-swap, or a guarantee against all races.

If the iPhone stays suspended while the Mac advances, reopening that already
running app may offer to close it so that a full launch can import the new
save. The engine doesn't replace a running game's on-disk profile from under
it. UserDefaults bookmarks and iPhone backups remain in the app container;
installing an update under the same team and bundle ID should retain them.

## Evidence and test boundary

The original setup used one Mac/iPhone pair and the owner confirmed the game
loaded. The selected Mac profile was imported on iPhone, a phone update was
published and imported on Mac, and 21 files / 6,299,800 bytes were compared by
SHA-256. The game produced 15 per-part full-image proof records. Twelve
synthetic checks cover two-way import, backups, divergence, missing payloads,
corruption and symlinks.

This repository adds a broader Mac running-process guard and portable setup,
signing and USB-transfer tools. Their isolated tests use synthetic data. The
portable IPA verifier was also run against the actual app built in the original
setup, and the proof parser was checked against its previously read device
record. The refactored signing and USB-transfer commands have not themselves
been rerun end to end on a physical device. The workflow has not been validated
on every device or OS version. Save only on one device at a time, wait for
synchronization and keep recoverable backups.

## Конспект по-русски

В облако попадают только `account.uid` и файлы `save/<uid>/…`, без ключей,
образа игры и кешей. Версии хранятся как неизменяемые манифесты, файлы — по
SHA-256, а каждое устройство ведёт собственную ссылку на последнюю версию.
Перед импортом проверяются версия игры, UID, пути и хеши; прежний профиль
остаётся в локальном резерве. Разные видимые ветки предлагаются для выбора.

iCloud работает с задержкой и не даёт этому коду общей блокировки двух
устройств. Играйте на одном устройстве за раз, дождитесь передачи и храните
отдельные резервные копии. Исторические версии остаются на диске, но отдельного
полноценного интерфейса восстановления любой старой версии пока нет.
