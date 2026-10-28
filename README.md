# Switch games on Mac and iPhone: iCloud saves

# Игры Switch на Mac и iPhone: сохранения в iCloud

[Русская инструкция](docs/ru.md) · [English guide](docs/en.md) · [Agent instructions](AGENTS.md) · [Technical details](docs/sync.md)

This repository explains how to build and run a supported Nintendo Switch game
on Apple silicon Mac and iPhone and sync saves through iCloud Drive. The
**tested recipe is The Legend of Zelda: Breath of the Wild 1.6.0** with the
[MacNativeGames](https://github.com/ly05010419/MacNativeGames) native port.
It includes the source for our optional save-sync overlay and practical setup
instructions for humans and AI agents.

Здесь описано, как собрать поддерживаемую игру Nintendo Switch для Mac на Apple
silicon и iPhone и синхронизировать сохранения через iCloud Drive. **Проверенный
пример — The Legend of Zelda: Breath of the Wild 1.6.0** на основе нативного
порта [MacNativeGames](https://github.com/ly05010419/MacNativeGames). Внутри —
исходный код дополнительной синхронизации и инструкции для людей и AI-агентов.

## Scope / Область применения

- The underlying project is a game-specific native port, not a general Switch
  emulator. **This save overlay supports BOTW 1.6.0 only.** Other game ports,
  versions and save formats need separate adaptation and testing.
- Нативный проект поддерживает отдельные игры и не является универсальным
  эмулятором Switch. **Этот обмен сохранениями рассчитан только на BOTW 1.6.0.**
  Для других игр, версий и форматов нужна отдельная адаптация и проверка.
- One real setup was checked end to end: an Apple silicon Mac and an iPhone 15
  Pro, macOS 27 / iOS 27.0.1, BOTW 1.6.0 and two DLC packs. The game loaded,
  and 21 save files went Mac → iPhone → iCloud → Mac with matching hashes.
  Twelve additional local checks exercised conflicts, backups and corruption.
- Сценарий проверен на одной реальной паре устройств: Mac на Apple silicon и
  iPhone 15 Pro, macOS 27 / iOS 27.0.1, BOTW 1.6.0 и два DLC. Игра загрузилась;
  21 файл сохранения прошёл путь Mac → iPhone → iCloud → Mac с проверкой хешей.
  Ещё 12 локальных проверок проверяют конфликты, резервирование и повреждения.

You provide your own game, updates, console keys and system fonts. The repo
contains no game assets, keys, firmware, compiled game, IPA, saves, Apple account
credentials or personal device identifiers. Follow the upstream project's
requirements for using your own copy and system files.

Игру, обновление, ключи консоли и системные шрифты каждый предоставляет сам.
В репозитории нет игровых файлов, ключей, прошивки, собранной игры, IPA,
сохранений, данных Apple Account и идентификаторов устройств. Используйте
собственную копию и системные файлы в соответствии с требованиями исходного проекта.

## How syncing works / Как работает обмен

1. Mac: the provided launcher checks iCloud before launch and publishes local
   changes after the game closes.
2. iPhone: select the dedicated `Zelda BOTW` folder once. The game checks it on
   a full launch and publishes local changes when it goes to the background.
3. Each device keeps a local profile. Content-addressed history retains older
   copies; a visible divergence prompts a choice instead of silently replacing
   a branch. iCloud delivery is asynchronous: save, leave the first game, and
   give it time to sync before opening the other device.

1. На Mac дополнительный ярлык проверяет iCloud до запуска и отправляет
   изменения после закрытия игры.
2. На iPhone папку `Zelda BOTW` выбирают один раз. При полном запуске игра
   проверяет её, а при сворачивании отправляет локальные изменения.
3. Локальные профили остаются на устройствах, старые копии — в истории.
   При обнаруженном расхождении приложение предлагает выбрать ветку.
   iCloud доставляет файлы не мгновенно: сохранитесь, выйдите из первой игры
   и дайте синхронизации время перед запуском на другом устройстве.

This is an early community workflow, not a distributed lock or a guarantee
against all iCloud/offline races. Avoid playing on both devices at once and
keep independent backups. The iPhone setup dialogs are currently in Russian;
the English guide translates each choice. The UI and game port may change in
new upstream releases, so this guide pins the tested upstream commit.

Это ранняя настройка сообщества, а не распределённая блокировка и не гарантия
от всех задержек iCloud или офлайн-конфликтов. Не играйте одновременно на двух
устройствах и сохраняйте отдельные резервные копии. В новой версии исходного
проекта интерфейс и порты могут измениться — здесь зафиксирован проверенный коммит.

## Find this guide / Ключевые слова

Nintendo Switch, Zelda BOTW, Breath of the Wild, Mac, MacBook, Apple silicon,
iPhone, iOS, iCloud Drive, cross-save, cloud saves, game saves, AI agent, Codex,
Claude Code, MacNativeGames, сохранения, синхронизация, облако, инструкция.

[MIT licence](LICENSE) · [Upstream attribution](NOTICE.md)
