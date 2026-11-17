# Source attribution

The repository's MIT licence covers the local contributions in this folder.
MacNativeGames source and adapted host code are based on commit
`ea1ce3b2be23540c4d67df95695f8c70f66cd8e0`; retain its licence in
[the repository licence copy](../../../licenses/MacNativeGames-MIT.txt).

UIKit editor behaviour, layout concepts, pouch/rune layouts and icon-decoding
algorithms adapt author-owned code from [BOTWRecompAndroid](https://github.com/mamcjr/BOTWRecompAndroid/tree/3d9beeb0c25c65845e805c91c4bba1bbb860cae9),
commit `3d9beeb0c25c65845e805c91c4bba1bbb860cae9`, notably
`runtime/ui/touch_controls.mm`, `runtime/hle/pouch.c` and
`runtime/hle/gdt_runes.c`.

The [upstream LICENSE at that exact commit](https://github.com/mamcjr/BOTWRecompAndroid/blob/3d9beeb0c25c65845e805c91c4bba1bbb860cae9/LICENSE)
was checked during preparation. Its exact licence text is preserved in
[BOTWRecompAndroid-MIT.txt](BOTWRecompAndroid-MIT.txt), including the express
exclusion of Nintendo property and independently licensed third-party components.
The source header `backend/botw_touch_license.h` also retains its notice.

The `ui/fps_overlay.h` declaration source and its reference-patch hunks originate
in `games/totk/third_party/d2r_gfx`, separately licensed MIT, copyright (c) 2026
jhaizhou. Its exact licence is included in [d2r_gfx-MIT.txt](d2r_gfx-MIT.txt).
The broad MacNativeGames licence does not replace this component notice.

Public-copy sanitization: `BOTWSheikahSettingsArtwork` uses Apple's system
`gearshape.fill` SF Symbol instead of the local procedural Sheikah settings
emblem. The comment points to this included notice. The original local source
and installed app were not changed; provenance records both the original and
sanitized source hashes.

The unmodified local `ps4/stage_icons.py` is preserved as source only. It imports
helpers pinned to MacNativeGames `bad89a8c82d1e1cd1e0bbd6e4308b2992c17d76c`;
none of those helper copies, donor contents or generated resources are bundled.
See [the generator scope](../ps4/GENERATOR.md). No donor-art rights are claimed.

**No upstream artwork, atlas, decoded Nintendo icon pixels, game-image bytes,
guest instructions or donor data is included.** References to resource names in
source code are API/file-format identifiers; the resources themselves are absent.
No rights to PlayStation donor artwork are asserted or granted.

**Атласы, игровая графика, инструкции из игрового образа и донорские данные не
включены.** Лицензия на авторский код не выдаёт прав на собственность Nintendo
или отсутствующую графику третьих лиц.
