# Archived generator source / Исходник генератора

`stage_icons.py` is an exact, unmodified copy of the locally authored generator.
It contains Python algorithms, resource-name identifiers and compatibility
hashes, not donor ZIP bytes, game resources, decoded icons, private IDs or paths.
The tiny OPTIONS lettering is authored procedural text; no donor silhouette is
embedded. The donor SHARE/OPTIONS shapes are read only from a separately supplied
file at execution time. Preservation does not authorize publication of its output.

Сохранена точная копия локального Python-исходника. В ней нет байтов donor ZIP,
игровых ресурсов, иконок, личных ID или абсолютных домашних путей. Генератор
читает силуэты SHARE/OPTIONS из отдельно предоставленного файла при запуске;
сохранение кода не выдаёт прав на распространение результата.

## Dependencies and scope

This older graphics experiment intentionally uses a different helper baseline
from the main BOTW port:
[MacNativeGames bad89a8c82d1e1cd1e0bbd6e4308b2992c17d76c](https://github.com/ly05010419/MacNativeGames/tree/bad89a8c82d1e1cd1e0bbd6e4308b2992c17d76c).
The MIT licence at that exact commit was checked. Do not substitute the moving
default branch. The generator checks SHA-256 of seven helper sources before
importing them:

- `games/totk/scripts/make_botw_button_icons.py`
- `games/totk/scripts/botw_playstation_icons.py`
- `games/totk/scripts/make_mod_manifest.py`
- `games/totk/scripts/prepare_shader_seed.py`
- `games/totk/scripts/shader_list.py`
- `tools/builder/controls_file.py`
- `tools/builder/icons_plan.py`

Expected file hashes and the compatibility donor hash are in the Python source.
They establish exact-input compatibility, not legal permission or authenticity.
The helpers must be in `upstream/` beside the private copy of the script, retaining
their original repository layout. They are not bundled here. Because verification
and imports occur before argument parsing, even `--help` needs those helpers.

The donor must be separately obtained and permitted for the owner's intended
use; the original [Velkyn mod page](https://gamebanana.com/mods/659253) is a
provenance pointer, not a licence grant. No donor is downloaded or redistributed.
The generator only accepts its original pinned donor hash; a different permitted
donor requires a separately reviewed adaptation rather than bypassing the check.

Baseline helpers, donor-файл и права на предполагаемое использование нужно
получить отдельно. Хеш в коде подтверждает совпадение входа, а не разрешение.
Другой donor нельзя подставить отключением проверки: потребуется новая
проверенная адаптация. Внешние helpers здесь не опубликованы повторно.

## Private staging only

Do not execute this archived copy inside the public repository: its output
includes game-derived resources and image previews. First copy only this source
to a private scratch directory, preserve the script filename, and prepare the
exact permitted local helper/input files there. All source arguments should be
explicit; no real device/account identifiers are needed:

```sh
python3 -B stage_icons.py \
  --donor /path/to/permitted-donor.zip \
  --app /path/to/owned-game.app \
  --controls /path/to/controls.txt \
  --output /path/to/private-scratch/derived-check
```

`--output` must be a new `derived*` directory directly beside the script.
The controls file's sibling `controller-type.txt` must also be present. The code
reads the supplied local app's resources and controls, writes only its staging
output, and contains no network request, game launch, installation or profile
write. Imported helpers still require normal source/dependency review.

The source was compiled in memory for Python syntax only. It was not executed
or imported during archival; no donor, game file or live profile was opened.
Game compatibility, generated appearance, rights and output installation were
not revalidated. Generated output and private inputs must remain outside the
public Git tree.

Код проверен только на синтаксис без импорта и исполнения. Игровые файлы,
donor и профиль не открывались. Генерацию, внешний вид и установку заново не
проверяли. Выполнять можно лишь в отдельном приватном рабочем каталоге с
разрешёнными входами; полученные игровые материалы не добавлять в публичный Git.
