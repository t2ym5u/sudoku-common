# Changelog

All notable changes to this project will be documented in this file.

## [1.4.0] - 2026-10-01

### Added
- `stats_exporter.lua`, a verbatim copy of game-common's. The two shared
  libraries are mutually exclusive per plugin -- a sudoku variant mounts
  sudoku-common and never sees game-common -- but both write the same
  `game_stats.lua`, so the sudoku variants had no way to report a play
  session at all. `scripts/check_sudoku_common_drift.sh` now diffs the two
  copies and fails if they diverge.

## [1.3.0] - 2026-09-30

### Added
- `drawConflictMark()` in `base_board_widget.lua`, exported alongside
  `drawLine`/`drawDiagonalLine`: draws the bar that marks a cell whose digit
  conflicts with another. Greyscale-only by design -- every shade dark enough
  to read as "wrong" is already taken by givens, entries and revealed
  solutions, so the marker carries the meaning in its shape.

## [1.1.0] - 2026-09-30

### Added
- `logic_solver.lua` — a human-technique solver (naked/hidden singles, locked
  candidates, naked/hidden subsets, X-Wing, Swordfish, XY-Wing) expressed over
  generic units, so `extra_regions` variants (sudokux, windoku) are supported
  with no special-casing. It grades a grid's difficulty and answers "what is
  the next deduction here?".
- Hint support on the shared classes: `BaseScreen:onHint()` (three taps: where
  to look, why, then the value), plus `BaseBoard:getWorkingGrid`,
  `findWrongEntry`, `applyHint`, `getHintsUsed` and `getExtraRegions`.

### Changed
- `createPuzzle` now digs clues out against the logic solver: a clue may only
  be removed if what remains is still solvable by deduction alone, within the
  difficulty's technique tier. A grid solvable by pure logic necessarily has a
  unique solution, so this **replaces** the old `countSolutions(...) == 1`
  check rather than adding to it — and made generation much faster (12x12
  Expert 3.5s -> 0.13s, 16x16 Expert over 60s -> 1.1s).
- `createPuzzle` returns a second value describing what it actually produced:
  `tier_cap`, `max_tier`, `counts` and `clues`.

### Fixed
- `base_screen.lua` asked KOReader's gettext directly for strings only the
  per-plugin `i18n.lua` knows, so the whole shared UI stayed English on a
  French device. It now prefers `i18n` when reachable, falling back to the old
  shim.
