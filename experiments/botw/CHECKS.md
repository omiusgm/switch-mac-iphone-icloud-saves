# Local preparation checks — 2026-11-11

Executed without game inputs, game launch, connected-device operations, real
profiles or iCloud folders:

- Preserved source SHA-256 checks passed.
- Swift cloud engine: 12 original synthetic checks passed.
- Recovery engine: 10 scenarios passed, including stale own-head repair,
  independent branches before/after repair, equal-payload merge, missing
  manifests, incomplete blobs, cyclic history, occupied own head, dirty local
  profile refusal and genuine remote descendants.
- Production backend with synthetic allocated memory passed ASan/UBSan snapshot,
  invalid-state, unmap and race tests. The disabled-platform fallback passed.
- Five viewport geometries, 29 synthetic FOV equations, explicit crop and aspect
  selection passed. No guest instructions were executed by these checks.
- Four UIKit units (`BOTWSheikahHUD.m`, `BOTWSheikahEditor.m`,
  `BOTWGraphicsSettings.m`, `touch_pad.m`) passed iOS Simulator SDK syntax-only
  compilation. No UI link/run, rendering or touch-device acceptance is claimed.
- `touch-backend.patch` and `touch-ui-reference.patch` each passed
  `git apply --check` against pristine source blobs from pinned upstream
  `ea1ce3b2be23540c4d67df95695f8c70f66cd8e0`, and applied outputs matched every
  recorded target hash. These are source application checks, not a full build.
- Recovery patch applied to the public guide engine at
  `0550c96dcc35703e777df58b114ee3828d5ba03a` and reproduced the included source.
- The separately adapted launcher reference passed 28 synthetic fixture
  scenarios in an isolated temporary home; real iCloud and window focus were
  not checked. Run `python3 experiments/botw/launcher/run_fixtures.py` from the
  repository root to repeat it.

The checks use temporary directories and synthetic account bytes. UI appearance,
real iCloud timing, device save exchange, full integration, runtime performance,
game camera behaviour and PS4 artwork remain outside these results.

The repository publication scanner passed after package preparation. The source
package contained no binary files, personal home-path matches or prohibited
artifact extensions. Manual review and licence scope remain
necessary in addition to that heuristic scan.

Post-audit source amendments were checked separately:

- Copied the exact d2r_gfx MIT licence (copyright 2026 jhaizhou), compared against
  the pinned upstream Git blob, and added component attribution.
- Replaced the procedural Sheikah settings emblem with system `gearshape.fill`
  only in the public copy. The source manifest records the original local SHA,
  sanitized SHA/size and `publication_edits`. The original local SHA still matches.
- Updated the public UI patch and target hashes. Both patches again passed
  `git apply --check` and exact output-hash verification.
- The same four UIKit units again passed syntax-only compilation.
- Archived the unmodified PS4 generator as source only; an in-memory Python syntax
  check passed without imports, execution or reading donor/game inputs. Its input
  and helper boundaries are documented in `ps4/GENERATOR.md`.
