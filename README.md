# sudoku-common

Shared library for all Sudoku-variant plugins in this repository
(`arrowsudoku`, `betweenlines`, `sandwichsudoku`, `sudoku`,
`sudokukiller`, `sudokux`, `thermosudoku`, `windoku`).

## Modules

| File | Purpose |
|------|---------|
| `base_board.lua` | Base game-state class — conflict detection, notes, undo, serialization |
| `base_board_widget.lua` | Base board renderer — cell sizing, given/user value styling, selection |
| `base_screen.lua` | Base full-screen UI — number pad, toolbar, pencil-mark toggle |
| `sudoku_grid_utils.lua` | Grid helpers — `emptyGrid`, `copyGrid`, `cloneNoteCell` |
| `puzzle_generator.lua` | Puzzle generator parameterised by box shape — digs clues out against `logic_solver` so what remains is always deducible |
| `logic_solver.lua` | Human-technique solver (singles → locked candidates → subsets → fish/XY-wing). Grades a grid's difficulty, and answers "what is the next deduction here?" — the engine behind both generation and the Hint button |

## Pure-logic guarantee

`createPuzzle` does not merely leave a grid with one solution — a grid can
have exactly one solution and still be crackable only by guessing a digit and
backtracking. It leaves a grid that `logic_solver` can finish by deduction
alone, using nothing above the difficulty's technique tier:

| Difficulty | Never needs more than |
|---|---|
| `easy`   | naked / hidden singles |
| `medium` | + locked candidates, naked pairs |
| `hard`   | + hidden pairs, naked/hidden triples, naked quads |
| `expert` | + X-Wing, Swordfish, XY-Wing |

That test is strictly stronger than counting solutions (every deduction is
forced, so a deducible grid is necessarily unique), so it *replaces* the old
`countSolutions(...) == 1` check instead of adding to it — which also made
large grids much cheaper to generate.

`createPuzzle` returns the puzzle plus an info table (`tier_cap`, `max_tier`,
`counts`, `clues`). `max_tier` is the hardest technique the finished grid
really needs, and can be lower than `tier_cap` — a 4×4 grid has no room for an
X-Wing however hard you dig.

`sudokukiller` does not go through `createPuzzle` — it has its own cage-based
generator — but `logic_solver` now reads cage sums (`opts.cages`), so its Easy
and Medium grids are deducible end to end and its Hint button works. Hard and
Expert stay genre-pure, carrying no given digits at all, and the cages alone do
not decide them; there the solver reports honestly that it cannot proceed.

## Hints

`BaseScreen:onHint()` reveals the next deduction over three taps — where to
look, why, then the value (written through `setValue`, so it undoes like any
other move). `BaseBoard:findWrongEntry()` gates the whole thing: while a
player-entered value contradicts the solution, the solver would reason from a
false premise and answer confidently wrong, so hints refuse to run.

It is driven by `logic_solver.nextPlacement()` rather than `nextStep()`: over
half the techniques only strike candidates out, and "you may rule out a 4
here" is useless to a player who keeps no pencil marks, so `nextPlacement`
walks past those preparatory steps and stops at the first cell that can
actually be filled.

A variant with units beyond rows/columns/boxes must override
`BaseBoard:getExtraRegions()` (as `sudokux` and `windoku` do), or its hints
will miss every deduction that depends on them.

`sudokukiller` deliberately has no Hint button: its information lives in the
cage sums, which this solver does not model, and classic deduction places
under 1 of its 65-80 empty cells before stalling.

## How to use in a plugin

Each sudoku variant plugin symlinks this directory as `sudoku-common/`:

```
sudoku.koplugin/
├── sudoku-common/   ← symlink → ../../sudoku-common
├── main.lua
├── screen.lua
├── board.lua
└── board_widget.lua
```

Path setup in `main.lua`:

```lua
local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
package.path = _dir .. "?.lua;" .. _dir .. "sudoku-common/?.lua;" .. package.path
```

## Inheritance diagram

```
BaseBoard  (base_board.lua)
└── VariantBoard  (board.lua)       ← one per plugin

BaseBoardWidget  (base_board_widget.lua)
└── VariantBoardWidget  (board_widget.lua)

BaseScreen  (base_screen.lua)
└── VariantScreen  (screen.lua)
```

## License

GPL-3.0
