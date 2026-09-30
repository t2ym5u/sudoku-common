local grid_utils  = require("sudoku_grid_utils")
local logic_solver = require("logic_solver")
local emptyGrid  = grid_utils.emptyGrid
local copyGrid   = grid_utils.copyGrid

local bit    = require("bit")
local bor    = bit.bor
local band   = bit.band
local bnot   = bit.bnot
local lshift = bit.lshift

-- randInt(i) -> integer in [1, i], inclusive uniform. Defaults to
-- math.random so normal play is unaffected; callers pass a seeded
-- generator (see game-common/daily_seed.lua) for reproducible "puzzle of
-- the day" generation without touching global RNG state.
local function shuffledDigits(n, randInt)
    randInt = randInt or math.random
    local digits = {}
    for i = 1, n do digits[i] = i end
    for i = n, 2, -1 do
        local j = randInt(i)
        digits[i], digits[j] = digits[j], digits[i]
    end
    return digits
end

-- ---------------------------------------------------------------------------
-- extra_regions support (windoku's window boxes, sudokux's diagonals, ...)
--
-- extra_regions is an optional list of cell-lists, e.g.
-- { { {r=1,c=1}, {r=2,c=2}, ... }, ... }, each of which must also contain no
-- duplicate digit. The fast bitset engine below only tracks row/col/box
-- constraints, so any call that supplies extra_regions falls back to the
-- naive per-cell backtracking path in this section instead.
-- ---------------------------------------------------------------------------

local function buildCellRegionMap(extra_regions)
    if not extra_regions then return nil end
    local map = {}
    for _, region in ipairs(extra_regions) do
        for _, cell in ipairs(region) do
            map[cell.r] = map[cell.r] or {}
            map[cell.r][cell.c] = map[cell.r][cell.c] or {}
            table.insert(map[cell.r][cell.c], region)
        end
    end
    return map
end

local function isValidPlacement(grid, row, col, value, n, box_rows, box_cols, cell_region_map)
    for i = 1, n do
        if grid[row][i] == value or grid[i][col] == value then
            return false
        end
    end
    local br = math.floor((row - 1) / box_rows) * box_rows + 1
    local bc = math.floor((col - 1) / box_cols) * box_cols + 1
    for r = br, br + box_rows - 1 do
        for c = bc, bc + box_cols - 1 do
            if grid[r][c] == value then
                return false
            end
        end
    end
    if cell_region_map then
        local regions = cell_region_map[row] and cell_region_map[row][col]
        if regions then
            for _, region in ipairs(regions) do
                for _, cell in ipairs(region) do
                    if (cell.r ~= row or cell.c ~= col) and grid[cell.r][cell.c] == value then
                        return false
                    end
                end
            end
        end
    end
    return true
end

local function fillBoard(grid, cell, n, box_rows, box_cols, cell_region_map, randInt)
    if cell > n * n then
        return true
    end
    local row = math.floor((cell - 1) / n) + 1
    local col = (cell - 1) % n + 1
    local numbers = shuffledDigits(n, randInt)
    for _, value in ipairs(numbers) do
        if isValidPlacement(grid, row, col, value, n, box_rows, box_cols, cell_region_map) then
            grid[row][col] = value
            if fillBoard(grid, cell + 1, n, box_rows, box_cols, cell_region_map, randInt) then
                return true
            end
            grid[row][col] = 0
        end
    end
    return false
end

local function countSolutionsSlow(grid, limit, n, box_rows, box_cols, cell_region_map)
    local solutions = 0
    local function search(cell)
        if solutions >= limit then return end
        if cell > n * n then
            solutions = solutions + 1
            return
        end
        local row = math.floor((cell - 1) / n) + 1
        local col = (cell - 1) % n + 1
        if grid[row][col] ~= 0 then
            search(cell + 1)
            return
        end
        for _, value in ipairs(shuffledDigits(n)) do
            if isValidPlacement(grid, row, col, value, n, box_rows, box_cols, cell_region_map) then
                grid[row][col] = value
                search(cell + 1)
                grid[row][col] = 0
                if solutions >= limit then return end
            end
        end
    end
    search(1)
    return solutions
end

-- ---------------------------------------------------------------------------
-- Fast path (no extra_regions): bitset engine
-- ---------------------------------------------------------------------------

-- Build a valid solved grid using the cyclic-shift formula, then randomise it
-- with band/stack/row/col permutations and digit relabelling.  O(n²), no backtracking.
--
-- Formula: grid[r][c] = (box_cols*(r-1 mod box_rows) + floor((r-1)/box_rows) + (c-1)) mod n + 1
-- This is a valid Latin square that also satisfies all box constraints.
local function generateSolvedBoardFast(n, box_rows, box_cols, randInt)
    randInt = randInt or math.random
    local num_bands  = n / box_rows   -- number of row bands
    local num_stacks = n / box_cols   -- number of col stacks

    -- Step 1: construct the base grid
    local grid = emptyGrid(n)
    for r = 1, n do
        local k        = (r - 1) % box_rows
        local band_idx = math.floor((r - 1) / box_rows)
        for c = 1, n do
            grid[r][c] = (box_cols * k + band_idx + c - 1) % n + 1
        end
    end

    -- Step 2: shuffle band order
    local band_ord = {}
    for i = 1, num_bands do band_ord[i] = i end
    for i = num_bands, 2, -1 do
        local j = randInt(i)
        band_ord[i], band_ord[j] = band_ord[j], band_ord[i]
    end

    -- Step 3: shuffle rows within each band
    local row_perm = {}
    for bi = 1, num_bands do
        local w = {}
        for i = 1, box_rows do w[i] = i end
        for i = box_rows, 2, -1 do
            local j = randInt(i)
            w[i], w[j] = w[j], w[i]
        end
        local base = (band_ord[bi] - 1) * box_rows
        for i = 1, box_rows do
            row_perm[(bi - 1) * box_rows + i] = base + w[i]
        end
    end

    -- Step 4: shuffle stack order
    local stack_ord = {}
    for i = 1, num_stacks do stack_ord[i] = i end
    for i = num_stacks, 2, -1 do
        local j = randInt(i)
        stack_ord[i], stack_ord[j] = stack_ord[j], stack_ord[i]
    end

    -- Step 5: shuffle cols within each stack
    local col_perm = {}
    for si = 1, num_stacks do
        local w = {}
        for i = 1, box_cols do w[i] = i end
        for i = box_cols, 2, -1 do
            local j = randInt(i)
            w[i], w[j] = w[j], w[i]
        end
        local base = (stack_ord[si] - 1) * box_cols
        for i = 1, box_cols do
            col_perm[(si - 1) * box_cols + i] = base + w[i]
        end
    end

    -- Step 6: random digit relabelling
    local digit_map = shuffledDigits(n, randInt)

    -- Step 7: apply all permutations
    local out = emptyGrid(n)
    for r = 1, n do
        local src_r = row_perm[r]
        for c = 1, n do
            out[r][c] = digit_map[grid[src_r][col_perm[c]]]
        end
    end
    return out
end

-- Bitset backtracking solver with MRV (minimum remaining values) heuristic.
-- Does NOT modify grid; returns the number of solutions found (stops at limit).
local function countSolutionsFast(grid, limit, n, box_rows, box_cols)
    local num_stacks = n / box_cols
    local full_mask  = lshift(1, n) - 1

    -- Build constraint bitmasks and collect empty cells
    local row_used = {}
    local col_used = {}
    local box_used = {}
    for i = 1, n do
        row_used[i] = 0
        col_used[i] = 0
        box_used[i] = 0
    end

    local cells = {}
    for r = 1, n do
        local band_base = math.floor((r - 1) / box_rows) * num_stacks
        for c = 1, n do
            local b = band_base + math.floor((c - 1) / box_cols) + 1
            local v = grid[r][c]
            if v ~= 0 then
                local m = lshift(1, v - 1)
                row_used[r] = bor(row_used[r], m)
                col_used[c] = bor(col_used[c], m)
                box_used[b] = bor(box_used[b], m)
            else
                cells[#cells + 1] = { r = r, c = c, b = b }
            end
        end
    end

    local total     = #cells
    local solutions = 0

    local function search(depth)
        if solutions >= limit then return end
        if depth > total then
            solutions = solutions + 1
            return
        end

        -- MRV: pick the empty cell with the fewest legal values
        local best, best_cnt = depth, n + 1
        for i = depth, total do
            local cell = cells[i]
            local free = band(bnot(bor(bor(row_used[cell.r], col_used[cell.c]), box_used[cell.b])), full_mask)
            -- popcount via kernighan bit trick
            local cnt, x = 0, free
            while x > 0 do x = band(x, x - 1); cnt = cnt + 1 end
            if cnt < best_cnt then
                best_cnt = cnt
                best = i
                if cnt == 0 then break end
            end
        end

        if best_cnt == 0 then return end

        cells[depth], cells[best] = cells[best], cells[depth]
        local cell = cells[depth]
        local r, c, b = cell.r, cell.c, cell.b

        local free = band(bnot(bor(bor(row_used[r], col_used[c]), box_used[b])), full_mask)

        while free ~= 0 do
            local m = band(free, -free)          -- isolate lowest set bit
            row_used[r] = bor(row_used[r], m)
            col_used[c] = bor(col_used[c], m)
            box_used[b] = bor(box_used[b], m)

            search(depth + 1)

            row_used[r] = band(row_used[r], bnot(m))
            col_used[c] = band(col_used[c], bnot(m))
            box_used[b] = band(box_used[b], bnot(m))

            free = band(free, free - 1)          -- clear lowest set bit
            if solutions >= limit then break end
        end

        cells[depth], cells[best] = cells[best], cells[depth]
    end

    search(1)
    return solutions
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- extra_regions (optional): see the section above -- routes generation
-- through the slower per-cell backtracking path instead of the fast bitset
-- Latin-square construction, since the latter can't guarantee arbitrary
-- extra regions.
-- randInt(i) -> [1,i] (optional): see shuffledDigits' doc comment above.
local function generateSolvedBoard(n, box_rows, box_cols, extra_regions, randInt)
    if extra_regions then
        local grid = emptyGrid(n)
        local cell_region_map = buildCellRegionMap(extra_regions)
        fillBoard(grid, 1, n, box_rows, box_cols, cell_region_map, randInt)
        return grid
    end
    return generateSolvedBoardFast(n, box_rows, box_cols, randInt)
end

local function countSolutions(grid, limit, n, box_rows, box_cols, extra_regions)
    if extra_regions then
        return countSolutionsSlow(grid, limit, n, box_rows, box_cols, buildCellRegionMap(extra_regions))
    end
    return countSolutionsFast(grid, limit, n, box_rows, box_cols)
end

-- ---------------------------------------------------------------------------
-- Digging out the clues
--
-- The oracle used to be "does exactly one solution remain?". That is weaker
-- than it sounds: a uniquely-solvable grid can still force the player to try
-- a digit and backtrack when it blows up. Measured on this generator before
-- the change, 35% of 9x9 "expert" grids and 5% of "hard" ones were solvable
-- only by guessing -- and, in the other direction, easy/medium/hard all came
-- out needing nothing but singles, so the three labels described the same
-- experience with different clue counts.
--
-- The oracle is now "is what remains still solvable by deduction alone, using
-- nothing above this difficulty's technique tier?" (see logic_solver.lua).
-- That is strictly stronger -- a grid solvable by pure logic necessarily has
-- one solution, since every deduction is forced -- so this REPLACES the old
-- countSolutions() == 1 check rather than adding to it, and the generator got
-- considerably faster in the process (12x12 expert 3.5s -> 0.13s per grid,
-- 16x16 expert >60s -> 1.1s, because a dead end is now rejected by cheap
-- constraint propagation instead of a full backtracking search).
--
-- Two knobs shape a difficulty, and they do different jobs:
--
--   tier  -- a GUARANTEE about the hardest technique that can ever be needed.
--            "easy" grids provably never need more than naked/hidden singles.
--   ratio -- how far to keep digging, i.e. how many clues are left. This stays
--            the primary "how long will this take me" knob, as before.
--
-- expert has no ratio cap: the tier ceiling is the only thing stopping it, so
-- it digs as deep as pure logic allows.
-- ---------------------------------------------------------------------------

local DIG_RATIOS = { easy = 0.43, medium = 0.56, hard = 0.65, expert = nil }

-- on_progress (optional): called after each cell examined as
-- on_progress(removed, removals), so callers can drive a real progress bar
-- off actual digging work instead of a fake timer.
--
-- Returns the puzzle plus an info table describing what was actually produced:
--   { tier_cap  = the tier the dig was allowed to use,
--     max_tier  = the hardest tier the finished grid really needs,
--     counts    = { [technique name] = times needed },
--     clues     = number of givens left }
-- max_tier can legitimately come out below tier_cap -- a 4x4 grid has no room
-- for an X-Wing no matter how hard you dig -- so report it rather than pretend
-- the label was achieved.
local function createPuzzle(solved_grid, difficulty, n, box_rows, box_cols, extra_regions, randInt, on_progress)
    randInt = randInt or math.random
    local puzzle   = copyGrid(solved_grid, n)
    local total    = n * n
    local tier_cap = logic_solver.DIFFICULTY_TIER[difficulty]
                     or logic_solver.DIFFICULTY_TIER.medium
    local ratio    = DIG_RATIOS[difficulty]
    -- Unknown difficulty strings fell back to "medium" before; keep that.
    if ratio == nil and logic_solver.DIFFICULTY_TIER[difficulty] == nil then
        ratio = DIG_RATIOS.medium
    end
    local removals = ratio and math.floor(total * ratio) or total

    local cells = {}
    for r = 1, n do
        for c = 1, n do cells[#cells + 1] = { r = r, c = c } end
    end
    for i = #cells, 2, -1 do
        local j = randInt(i)
        cells[i], cells[j] = cells[j], cells[i]
    end

    local removed = 0
    for _, cell in ipairs(cells) do
        if removed >= removals then break end
        local row, col = cell.r, cell.c
        if puzzle[row][col] ~= 0 then
            local backup = puzzle[row][col]
            puzzle[row][col] = 0
            if logic_solver.solvableWithin(puzzle, n, box_rows, box_cols, extra_regions, tier_cap) then
                removed = removed + 1
            else
                puzzle[row][col] = backup
            end
        end
        if on_progress then on_progress(removed, removals) end
    end

    local rating = logic_solver.solve(puzzle, n, box_rows, box_cols, extra_regions,
                                      { max_tier = tier_cap })
    return puzzle, {
        tier_cap = tier_cap,
        max_tier = rating.max_tier,
        counts   = rating.counts,
        clues    = total - removed,
    }
end

return {
    generateSolvedBoard = generateSolvedBoard,
    countSolutions      = countSolutions,
    createPuzzle        = createPuzzle,
}
