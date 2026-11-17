# Positional PS4 prompt mapping / Соответствие подсказок PS4

The local prompt experiment kept physical positions rather than changing the
existing controller bindings. Preserve this distinction when rebuilding a layer.

Локальный эксперимент менял подсказки по положению кнопок и не переназначал
управление. При повторении нельзя подменять одну задачу другой.

| Switch input | PS4 prompt |
| --- | --- |
| A / right | Circle / ○ |
| B / bottom | Cross / × |
| X / top | Triangle / △ |
| Y / left | Square / □ |
| L / R | L1 / R1 |
| ZL / ZR | L2 / R2 |
| Plus / Minus | OPTIONS / SHARE |

The local README recorded installation of seven replacements and a manifest,
with backup/readback. A separate-profile Russian save-menu check displayed the
back prompt. In-world prompts and actual controller button presses remained
unverified. This package does not revalidate that installation.

По локальному README слой из семи замен установлен с резервной копией и
проверкой; в отдельном профиле проверена подсказка возврата в русском меню
сохранений. Подсказки в игровом мире и физические нажатия оставались без
подтверждения. Здесь установка заново не проверялась.

The archived source-only generator relies on locally supplied fonts/layouts and donor artwork
from a separate mod package. Neither donor licence sufficiency nor redistribution
of the derived output is established here. The generator source is preserved in
`stage_icons.py`; its upstream drawing helpers, donor ZIP, previews and output
files are excluded. See [GENERATOR.md](GENERATOR.md) for the pinned helper
revision and private staging boundary. This source alone is not a reproducible
mod and does not grant rights to any donor artwork or generated game resources.

Исходник генератора сохранён без исполнения. Шрифты, готовые игровые архивы,
его внешние helpers и донорская графика не перенесены: права на публикацию
такого результата здесь не установлены. Исходник и таблица не являются готовым
модом. Перед использованием нужны отдельно полученные разрешённые материалы.
