# BOTW: source preservation / сохранение исходников

This folder preserves useful local work after the original guide was published.
It is an **experimental source archive**, not an installable game, a complete
updated port or proof that a feature works on a real iPhone/iPad.

Здесь собраны полезные исходники, появившиеся после публикации основной инструкции.
Это **архив исходников экспериментов**. Он не заменяет рабочую игру и не даёт
готовую обновлённую сборку для Mac, iPhone или iPad.

Source baseline: [MacNativeGames ea1ce3b2be23540c4d67df95695f8c70f66cd8e0](https://github.com/ly05010419/MacNativeGames/tree/ea1ce3b2be23540c4d67df95695f8c70f66cd8e0),
BOTW 1.6.0. The original guide revision is
`0550c96dcc35703e777df58b114ee3828d5ba03a`.

## What is preserved / Что сохранено

| Area / Область | Included / В архиве | Evidence and limit / Проверка и границы |
| --- | --- | --- |
| iCloud recovery | Full updated `CloudSaveCore.swift`, controller, original tests, recovery regression suite, patch against the published engine | 12 original checks and 10 recovery scenarios passed on synthetic temporary profiles. This does not measure real iCloud delivery or establish a new device acceptance result. / 12 исходных проверок и 10 сценариев восстановления прошли на временных синтетических профилях; реальный обмен заново не проверялся. |
| iCloud launch indicator | [Separate launcher reference](launcher/README.md) and isolated fixtures | 28 synthetic scenarios passed; the published reference is not installed and real iCloud/focus were not checked. / 28 синтетических сценариев прошли; публичный пример не установлен, реальный iCloud и фокус окна не проверялись. |
| HUD editor | UIKit layout, drag/scale editor, overlap validation, sparse preferences and accessibility source | Local editor candidate; source syntax checked. Atlas artwork and production simulator fixture screenshots are absent. / Локальный кандидат редактора; проверен синтаксис исходников. Атласов и игровых снимков нет. |
| Touch camera and settings | Floating camera/sensitivity, input arbitration, menu neutralization and settings integration source | Source reference from the later local candidate; four UIKit units passed syntax checking. No linked game/device test here. / Исходники позднего локального кандидата; четыре UIKit-модуля проверены компилятором. Игровой запуск не выполнялся. |
| HUD backend | Bounded read-only equipment/rune sampling and Yaz0/BNTX decoder; host hooks and synthetic tests | ASan/UBSan snapshot, invalid-state, unmapped-memory and race fixtures passed; disabled-platform fallback passed. No game resources are bundled. / Синтетические проверки границ, гонок и недоступной памяти прошли с санитайзерами; fallback на отключённой платформе проверен. |
| Screen fit | Pixel-centred viewport helper, explicit crop helper, frame-cadence analyser, synthetic geometry tests | Five viewport cases and 29 FOV equations passed. Local full Vert+ runtime remained an uninstalled research candidate; its instruction patches are excluded. / Проверены пять размеров viewport и 29 углов FOV. Полный Vert+ остался локальным исследованием; патчей игровых инструкций здесь нет. |
| PS4 prompts | Positional mapping, original source-only generator and preservation notes | The local notes recorded an installed layer and a Russian save-menu check. In-world prompts and physical button presses remained unverified. No font, mod overlay, donor ZIP or artwork is included. The archived generator was syntax checked, not executed. / По локальному README слой установлен, проверено меню сохранений; подсказки в мире и физические кнопки остались без подтверждения. Исходник генератора сохранён без исполнения. |

`source-manifest.json` records relative provenance, byte sizes and SHA-256 for
selected preserved source files; the separate launcher reference has its own
fixtures. These are source hashes, not evidence that an installed
app uses those files. All personal device/account identifiers and local logs are
excluded. The synthetic tests create invented account bytes in a temporary
directory; no real account or save is present.

The public HUD source replaces the local procedural Sheikah settings emblem
with Apple's system `gearshape.fill` SF Symbol. Its original source hash and
publication edit are recorded; the local working source/app remain unchanged.

В публичной копии HUD процедурная эмблема заменена системным значком шестерёнки.
Исходный хеш и изменение записаны в manifest; локальные исходники и игра не менялись.

`source-manifest.json` содержит относительное происхождение, размер и SHA-256
сохранённых исходников. Это не квитанция установленной сборки. Тесты создают
вымышленные данные во временном каталоге; реальных аккаунтов и сохранений нет.

## Reproduce source checks / Повторить проверки исходников

On macOS with Xcode and the iOS Simulator SDK, from the repository root:

На Mac с Xcode и SDK симулятора iOS, из корня репозитория:

```sh
python3 -B experiments/botw/run_checks.py
python3 -B experiments/botw/verify_patches.py --upstream /path/to/MacNativeGames
```

The second command reads only the pinned source blobs from the supplied Git
repository. It constructs temporary clean files, runs `git apply --check`, applies
each patch there and verifies exact output hashes. It changes neither checkout
nor app/profile. The recovery patch is checked separately against the published
guide commit. These checks passed during preparation; see [CHECKS.md](CHECKS.md).

Вторая команда читает исходные файлы указанного pinned-коммита. Она проверяет
применение патчей и итоговые хеши только во временных каталогах, не меняя checkout,
приложение или профиль. Recovery-патч отдельно проверяется на коммите исходной
инструкции. Результат подготовки — в [CHECKS.md](CHECKS.md).

## Patch boundaries / Границы патчей

- `patches/touch-backend.patch` preserves the bounded reader and host hooks in
  loader, services and RomFS. It contains authored C source and numeric format
  offsets/hashes, **no copied game instructions or game image bytes**.
- `patches/touch-ui-reference.patch` preserves UIKit and host-input source changes.
  Its textual application to the pinned files is verified, but **it is not a
  complete integration**. App entry points reference optional scene-quality,
  format and presentation APIs whose guest/runtime implementation is absent.
  Build-system integration, generated Swift headers, renderer hooks, fonts and
  optional artwork also require separate work. Do not apply it to a working app.
- `cloud/published-core-recovery.patch` is relative to the original public guide's
  `cloud/CloudSaveCore.swift`, not directly to MacNativeGames. Replacing the Swift
  source alone does not regenerate the main guide's older combined overlay.

Backend-патч сохраняет авторский C-код и числовые смещения формата, без копий
инструкций или байтов игры. UI-патч воспроизводимо применяется к исходникам, но
остаётся **ссылочным материалом для доработки**, а не готовым обновлением.
Часть реализаций runtime, подключение сборки и игровые ресурсы отсутствуют.
Recovery-патч относится к опубликованному движку синхронизации; старый общий
overlay основной инструкции он автоматически не обновляет.

## What stays local / Что осталось локально

No game, NSP, extracted image, firmware, keys, compiled app/IPA, real save,
signing profile, device/account IDs, personal logs or screenshots are included.
No Sheikah atlas, Nintendo icon data, PlayStation donor artwork or generated
font/mod overlay is included. Full screenfit and scene-resolution patches that
quote game instructions are excluded. These omissions are deliberate; this
archive cannot reproduce the exact visual/game build by itself.

Игры, ключи, прошивки, сборки, настоящие сохранения, профили подписи,
идентификаторы и личные логи остаются локально. Атласы, игровые иконки,
донорская графика PlayStation и готовые моды не перенесены. Полные патчи Vert+
и разрешения сцены с копиями игровых инструкций исключены. Для точного
воспроизведения внешнего вида и игровой сборки этого архива недостаточно.

See [licenses/NOTICE.md](licenses/NOTICE.md) for the exact source revisions and
licences. MIT code permission does not extend to Nintendo property or omitted
third-party artwork. Public-code preservation and private backup of unique
restricted materials are separate tasks; the latter requires its own destination
and owner authorization.
