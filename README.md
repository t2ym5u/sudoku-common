# sudoku-common

Shared library for all Sudoku-variant plugins in this repository
(`sudoku`, `sudokukiller`, `sudokux`, `hypersudoku`, `sandwichsudoku`,
`thermosudoku`, `windoku`).

## Modules

| File | Purpose |
|------|---------|
| `base_board.lua` | Base game-state class — conflict detection, notes, undo, serialization |
| `base_board_widget.lua` | Base board renderer — cell sizing, given/user value styling, selection |
| `base_screen.lua` | Base full-screen UI — number pad, toolbar, pencil-mark toggle |
| `sudoku_grid_utils.lua` | Grid helpers — `emptyGrid`, `copyGrid`, `cloneNoteCell` |
| `puzzle_generator.lua` | Backtracking puzzle generator parameterised by box shape |

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
