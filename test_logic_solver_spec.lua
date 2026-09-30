-- Spec for logic_solver.lua and the pure-logic guarantee it gives
-- puzzle_generator.createPuzzle. Self-contained: it only requires files from
-- this same directory, so it runs both from sudoku-common's own repo and from
-- the koreader-plugins monorepo.
--
-- Like every other sudoku spec, this needs LuaJIT's `bit` module -- run it as
-- `busted --lua=luajit` against a LuaJIT rocks tree.
local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
package.path = DIR .. "?.lua;" .. package.path

-- base_board.lua pulls in KOReader's gettext for its error strings.
package.preload["gettext"] = function()
    return setmetatable({}, { __call = function(_, str) return str end })
end

local LS = require("logic_solver")
local PG = require("puzzle_generator")

-- Deterministic RNG so the generation properties below are reproducible
-- regardless of the host Lua's math.random.
local function seededRandInt(seed)
    local state = seed
    return function(i)
        state = (1103515245 * state + 12345) % 2147483648
        return state % i + 1
    end
end

describe("logic_solver", function()

    describe("techniques", function()
        it("finds a naked single", function()
            -- Row 1 holds 1,2,3 -- the last cell can only be 4.
            local step = LS.nextStep({ {1,2,3,0}, {0,0,0,0}, {0,0,0,0}, {0,0,0,0} }, 4, 2, 2)
            assert.are.equal("naked_single", step.technique)
            assert.are.equal(LS.TIER.SINGLES, step.tier)
            assert.are.same({ r = 1, c = 4, digit = 4 }, step.placements[1])
        end)

        it("finds a hidden single -- a cell with several candidates that is still the only home for a digit", function()
            -- 1s at (1,3) and (3,1) between them rule out every cell of the
            -- top-left box except (2,2), which itself can still take any digit.
            local grid = { {0,0,1,0}, {0,0,0,0}, {1,0,0,0}, {0,0,0,0} }
            assert.are.equal(4, #LS.candidates(grid, 4, 2, 2)[2][2])

            local step = LS.nextStep(grid, 4, 2, 2)
            assert.are.equal("hidden_single", step.technique)
            assert.are.equal(1, step.digit)
            assert.are.same({ r = 2, c = 2, digit = 1 }, step.placements[1])
        end)

        it("reports nothing to do on a finished grid", function()
            local full = { {1,2,3,4}, {3,4,1,2}, {2,1,4,3}, {4,3,2,1} }
            assert.is_nil(LS.nextStep(full, 4, 2, 2))
            local res = LS.solve(full, 4, 2, 2)
            assert.is_true(res.solved)
            assert.are.equal(0, res.max_tier)
        end)

        it("detects a contradictory grid", function()
            local res = LS.solve({ {1,1,0,0}, {0,0,0,0}, {0,0,0,0}, {0,0,0,0} }, 4, 2, 2)
            assert.is_true(res.contradiction)
            assert.is_false(res.solved)
        end)
    end)

    describe("tier ceiling", function()
        it("refuses techniques above max_tier", function()
            -- A grid needing more than singles is solvable outright but not
            -- under an easy-difficulty ceiling.
            local randInt = seededRandInt(4242)
            local sol = PG.generateSolvedBoard(12, 3, 4, nil, randInt)
            local puz = PG.createPuzzle(sol, "expert", 12, 3, 4, nil, randInt)
            local full  = LS.solve(puz, 12, 3, 4, nil)
            local capped = LS.solve(puz, 12, 3, 4, nil, { max_tier = LS.TIER.SINGLES })
            assert.is_true(full.solved)
            if full.max_tier > LS.TIER.SINGLES then
                assert.is_false(capped.solved)
            end
        end)
    end)

    describe("soundness", function()
        -- The strongest check available: whatever technique fires, on whatever
        -- grid, every value it writes must be the true one and every candidate
        -- it strikes out must be one the solution does not use. This covers the
        -- advanced techniques (subsets, fish, xy-wing) that are impractical to
        -- pin down with hand-built fixtures.
        it("never places a wrong value or eliminates a correct candidate", function()
            local randInt = seededRandInt(99)
            for _, shape in ipairs({ {4,2,2}, {6,2,3}, {9,3,3}, {12,3,4} }) do
                local n, br, bc = shape[1], shape[2], shape[3]
                for _, diff in ipairs({ "easy", "expert" }) do
                    local sol = PG.generateSolvedBoard(n, br, bc, nil, randInt)
                    local puz = PG.createPuzzle(sol, diff, n, br, bc, nil, randInt)
                    local res = LS.solve(puz, n, br, bc, nil, { trace = true })
                    assert.is_true(res.solved)
                    for _, step in ipairs(res.steps) do
                        for _, p in ipairs(step.placements or {}) do
                            assert.are.equal(sol[p.r][p.c], p.digit,
                                step.technique .. " placed a wrong value")
                        end
                        for _, e in ipairs(step.eliminations or {}) do
                            assert.are_not.equal(sol[e.r][e.c], e.digit,
                                step.technique .. " eliminated the correct candidate")
                        end
                    end
                end
            end
        end)
    end)
end)

describe("puzzle_generator pure-logic guarantee", function()

    -- A real grid produced by the PREVIOUS generator, whose only test was
    -- "exactly one solution remains". It has a unique solution and is still
    -- undeducible: no chain of techniques cracks it, a player can only guess a
    -- digit and backtrack. Before the change ~35% of 9x9 "expert" grids looked
    -- like this. The generator must never be able to emit it again.
    local GUESS_ONLY = {
        { 0, 0, 0, 6, 0, 0, 0, 0, 2 },
        { 0, 9, 0, 0, 0, 4, 0, 8, 0 },
        { 0, 0, 0, 2, 9, 5, 4, 0, 0 },
        { 0, 0, 0, 0, 0, 2, 0, 3, 7 },
        { 0, 3, 0, 8, 0, 0, 0, 0, 0 },
        { 0, 4, 0, 0, 3, 0, 6, 0, 0 },
        { 4, 1, 9, 0, 0, 0, 8, 2, 0 },
        { 0, 6, 0, 0, 0, 0, 9, 0, 0 },
        { 5, 0, 0, 4, 0, 0, 0, 6, 0 },
    }

    it("a unique solution is not the same thing as a deducible one", function()
        assert.are.equal(1, PG.countSolutions(GUESS_ONLY, 2, 9, 3, 3, nil))
        assert.is_false(LS.solve(GUESS_ONLY, 9, 3, 3, nil).solved)
        assert.is_false(LS.solvableWithin(GUESS_ONLY, 9, 3, 3, nil, LS.TIER.FISH))
    end)

    local SHAPES = {
        { label = "4x4",   n = 4,  br = 2, bc = 2 },
        { label = "6x6",   n = 6,  br = 2, bc = 3 },
        { label = "9x9",   n = 9,  br = 3, bc = 3 },
        { label = "12x12", n = 12, br = 3, bc = 4 },
    }

    for _, s in ipairs(SHAPES) do
        for _, diff in ipairs({ "easy", "medium", "hard", "expert" }) do
            it(s.label .. " " .. diff .. " is solvable by deduction alone, within its tier", function()
                local randInt = seededRandInt(s.n * 1000 + #diff)
                for _ = 1, 3 do
                    local sol = PG.generateSolvedBoard(s.n, s.br, s.bc, nil, randInt)
                    local puz, info = PG.createPuzzle(sol, diff, s.n, s.br, s.bc, nil, randInt)

                    local res = LS.solve(puz, s.n, s.br, s.bc, nil, { max_tier = info.tier_cap })
                    assert.is_true(res.solved)
                    assert.is_true(info.max_tier <= info.tier_cap)

                    -- Deduction must land on the generator's own solution, and
                    -- every clue must be a true one.
                    for r = 1, s.n do
                        for c = 1, s.n do
                            assert.are.equal(sol[r][c], res.grid[r][c])
                            if puz[r][c] ~= 0 then
                                assert.are.equal(sol[r][c], puz[r][c])
                            end
                        end
                    end
                end
            end)
        end
    end

    it("leaves fewer clues as the difficulty rises", function()
        local randInt = seededRandInt(31337)
        local sol = PG.generateSolvedBoard(9, 3, 3, nil, randInt)
        local prev
        for _, diff in ipairs({ "easy", "medium", "hard", "expert" }) do
            local _, info = PG.createPuzzle(sol, diff, 9, 3, 3, nil, randInt)
            if prev then assert.is_true(info.clues < prev) end
            prev = info.clues
        end
    end)

    it("falls back to medium for an unknown difficulty", function()
        local randInt = seededRandInt(7)
        local sol = PG.generateSolvedBoard(9, 3, 3, nil, randInt)
        local _, info = PG.createPuzzle(sol, "nonsense", 9, 3, 3, nil, randInt)
        assert.are.equal(LS.DIFFICULTY_TIER.medium, info.tier_cap)
        assert.is_true(LS.solvableWithin(select(1, PG.createPuzzle(sol, "nonsense", 9, 3, 3, nil, randInt)),
                                         9, 3, 3, nil, info.tier_cap))
    end)

    describe("variants with extra regions", function()
        local function windokuRegions()
            local regs = {}
            for _, tl in ipairs({ {2,2}, {2,6}, {6,2}, {6,6} }) do
                local cells = {}
                for r = tl[1], tl[1] + 2 do
                    for c = tl[2], tl[2] + 2 do cells[#cells + 1] = { r = r, c = c } end
                end
                regs[#regs + 1] = cells
            end
            return regs
        end
        local function diagonalRegions(n)
            local a, b = {}, {}
            for i = 1, n do a[i] = { r = i, c = i }; b[i] = { r = i, c = n - i + 1 } end
            return { a, b }
        end

        for _, v in ipairs({ { "windoku", windokuRegions() }, { "sudokux", diagonalRegions(9) } }) do
            it(v[1] .. " grids are deducible too (extra regions are just more units)", function()
                local randInt = seededRandInt(555)
                for _, diff in ipairs({ "easy", "expert" }) do
                    local sol = PG.generateSolvedBoard(9, 3, 3, v[2], randInt)
                    local puz, info = PG.createPuzzle(sol, diff, 9, 3, 3, v[2], randInt)
                    local res = LS.solve(puz, 9, 3, 3, v[2], { max_tier = info.tier_cap })
                    assert.is_true(res.solved)
                    for r = 1, 9 do
                        for c = 1, 9 do assert.are.equal(sol[r][c], res.grid[r][c]) end
                    end
                end
            end)
        end
    end)
end)


describe("hint support", function()
    local BaseBoard = require("base_board")

    -- Smallest concrete board BaseBoard can drive: it only needs the two
    -- accessors every real variant already implements.
    local TestBoard = setmetatable({}, { __index = BaseBoard })
    TestBoard.__index = TestBoard

    function TestBoard:new(puzzle, solution, n, br, bc)
        local board = setmetatable({
            n = n, box_rows = br, box_cols = bc,
            puzzle = puzzle, solution = solution,
            user = {}, notes = {}, wrong_marks = {}, conflicts = {},
            selected = { row = 1, col = 1 },
            undo_stack = {}, reveal_solution = false,
        }, self)
        for r = 1, n do
            board.user[r], board.notes[r] = {}, {}
            board.wrong_marks[r], board.conflicts[r] = {}, {}
            for c = 1, n do
                board.user[r][c], board.notes[r][c] = 0, {}
                board.wrong_marks[r][c], board.conflicts[r][c] = false, false
            end
        end
        return board
    end

    function TestBoard:isGiven(r, c) return self.puzzle[r][c] ~= 0 end

    function TestBoard:getWorkingValue(r, c)
        local given = self.puzzle[r][c]
        if given ~= 0 then return given end
        return self.user[r][c]
    end

    local function freshBoard(difficulty)
        local randInt = seededRandInt(8080)
        local sol = PG.generateSolvedBoard(9, 3, 3, nil, randInt)
        local puz = PG.createPuzzle(sol, difficulty or "medium", 9, 3, 3, nil, randInt)
        return TestBoard:new(puz, sol, 9, 3, 3), puz, sol
    end

    it("builds a working grid from givens plus the player's own entries", function()
        local board, puz, sol = freshBoard()
        local r, c
        for rr = 1, 9 do
            for cc = 1, 9 do
                if puz[rr][cc] == 0 then r, c = rr, cc break end
            end
            if r then break end
        end
        board:setSelection(r, c)
        board:setValue(sol[r][c])
        local grid = board:getWorkingGrid()
        assert.are.equal(sol[r][c], grid[r][c])
        for rr = 1, 9 do
            for cc = 1, 9 do
                if puz[rr][cc] ~= 0 then assert.are.equal(puz[rr][cc], grid[rr][cc]) end
            end
        end
    end)

    it("spots a wrong entry, so hints never reason from a false premise", function()
        local board, puz, sol = freshBoard()
        assert.is_nil(board:findWrongEntry())
        local r, c
        for rr = 1, 9 do
            for cc = 1, 9 do if puz[rr][cc] == 0 then r, c = rr, cc break end end
            if r then break end
        end
        board:setSelection(r, c)
        board:setValue((sol[r][c] % 9) + 1)
        local wr, wc = board:findWrongEntry()
        assert.are.equal(r, wr)
        assert.are.equal(c, wc)
    end)

    it("writes a hinted value, counts it, and leaves it undoable", function()
        local board = freshBoard()
        local step = LS.nextPlacement(board:getWorkingGrid(), 9, 3, 3, nil)
        local cell = step.placements[1]

        assert.are.equal(0, board:getHintsUsed())
        assert.is_true(board:applyHint(cell.r, cell.c, cell.digit))
        assert.are.equal(cell.digit, board:getWorkingValue(cell.r, cell.c))
        assert.are.equal(1, board:getHintsUsed())

        assert.is_true(board:canUndo())
        board:undo()
        assert.are.equal(0, board:getWorkingValue(cell.r, cell.c))
    end)

    it("refuses to hint while the solution is on screen", function()
        local board = freshBoard()
        board:toggleSolution()
        local step = LS.nextPlacement(board:getWorkingGrid(), 9, 3, 3, nil)
        local ok = board:applyHint(step.placements[1].r, step.placements[1].c,
                                   step.placements[1].digit)
        assert.is_false(ok)
        assert.are.equal(0, board:getHintsUsed())
    end)

    it("defaults to no extra regions", function()
        assert.is_nil(freshBoard():getExtraRegions())
    end)

    it("can carry a whole puzzle to completion, one hint at a time", function()
        for _, difficulty in ipairs({ "easy", "expert" }) do
            local board, puz = freshBoard(difficulty)
            local blanks = 0
            for r = 1, 9 do
                for c = 1, 9 do if puz[r][c] == 0 then blanks = blanks + 1 end end
            end

            local applied = 0
            while true do
                local step = LS.nextPlacement(board:getWorkingGrid(), 9, 3, 3, nil)
                if not step then break end
                local cell = step.placements[1]
                assert.is_true(board:applyHint(cell.r, cell.c, cell.digit))
                applied = applied + 1
                assert.is_true(applied <= blanks, "hints outnumbered the blank cells")
            end

            assert.are.equal(blanks, applied)
            assert.are.equal(blanks, board:getHintsUsed())
            assert.is_true(board:isSolved())
            assert.is_nil(board:findWrongEntry())
        end
    end)

    it("reports why it cannot help, rather than guessing", function()
        local board, _puz, sol = freshBoard()
        assert.are.equal("complete", select(3, LS.nextPlacement(sol, 9, 3, 3, nil)))

        local broken = {}
        for r = 1, 9 do
            broken[r] = {}
            for c = 1, 9 do broken[r][c] = sol[r][c] end
        end
        broken[1][1] = sol[1][2]
        assert.are.equal("contradiction", select(3, LS.nextPlacement(broken, 9, 3, 3, nil)))
    end)
end)
