-- sudoku_common_version.lua — this copy of sudoku-common: its version and
-- the modules it provides by name. Read by module_guard.lua (by path, a
-- verbatim copy of game-common's), which uses it to make sure no sudoku
-- variant runs on modules older than its own.
--
-- Bump `version` with every release (it must match CHANGELOG.md's top entry,
-- test_module_guard_spec.lua checks), and list every new module in `modules`.
return {
    lib     = "sudoku-common",
    version = "1.8.0",
    modules = {
        "base_board", "base_board_widget", "base_screen", "logic_solver",
        "puzzle_generator", "stats_exporter", "sudoku_grid_utils",
    },
    -- Also shipped, verbatim, by game-common: its copy is as good as ours.
    shared = { stats_exporter = true },
}
