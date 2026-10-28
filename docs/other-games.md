# Adapting another game / Как адаптировать другую игру

The complete recipe and code in this repository are limited to **BOTW 1.6.0**.
[MacNativeGames](https://github.com/ly05010419/MacNativeGames) develops ports
per game and version. Check its current supported-title table and device notes;
the pinned version in this guide is intentionally older than upstream's moving
default branch. A game's availability on Mac doesn't establish iPhone support.

Before adapting the save engine to another game:

1. Verify that the exact game, update and both target platforms are supported by
   the underlying project, using your own game and system files.
2. Identify the exact Mac and iOS profile roots, account IDs and save format.
   Establish compatibility by real save/load tests on both sides. Don't assume
   the BOTW `account.uid` layout or version identifiers apply.
3. Decide which files are saves and which are caches, keys or game data. Build a
   strict allowlist and preserve existing profiles and local backups.
4. Adapt the title/version validation, UID handling and app lifecycle hooks;
   add tests for interrupted uploads, divergent offline play, corrupt files,
   symlinks, process guards and recovery. Changes need their own review.
5. On real devices, verify both directions and that the actual game loads the
   received save. Report exactly which stages worked; a copied file or visible
   folder is not proof of a playable save.

Этот репозиторий даёт готовый рецепт только для BOTW 1.6.0. У исходного
проекта поддержка появляется для отдельных игр и версий; наличие Mac-порта не
означает наличия iPhone-порта. Для другой игры отдельно найдите пути и формат
сохранений на каждом устройстве, ограничьте список передаваемых файлов,
обеспечьте резервирование, проверьте конфликты и проведите реальные тесты
загрузки в обе стороны. Простая замена названия и Title ID небезопасна.
