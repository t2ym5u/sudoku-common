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
-- duplicate digit. The fast Latin-square construction below only knows
-- row/col/box constraints, so any call that supplies extra_regions fills its
-- grid by backtracking search in this section instead (and countSolutions
-- takes the naive per-cell path).
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

-- Fills an empty grid with a solution that also satisfies extra_regions.
--
-- Bitmask backtracking that branches on the most constrained choice -- a
-- digit with one place left in some unit, else the open cell with the fewest
-- digits left (first in reading order on a tie) -- trying digits in a fresh
-- random order at each branch. Filling cells strictly in reading order, as
-- this used to, regularly painted itself into a corner deep in the grid and
-- backtracked through thousands of placements before noticing: on windoku
-- that was 80% of generating a puzzle, up to 0.4 s on a desktop and ten
-- times that on an e-reader. This notices a dead end as soon as a cell runs
-- out of digits or a unit out of room for one.
--
-- A fill that still wanders past FILL_NODE_LIMIT placements is abandoned
-- and restarted (a node count, not a time limit, so a given randInt still
-- produces the same grid on every device).
local FILL_NODE_LIMIT   = 300
local FILL_MAX_RESTARTS = 20

local function fillBoardOnce(grid, n, box_rows, box_cols, cell_region_list, randInt, node_limit)
    local num_stacks = n / box_cols
    local full_mask  = lshift(1, n) - 1
    local total      = n * n

    -- Unit masks: rows 1..n, cols n+1..2n, boxes 2n+1..3n, regions after.
    local used, unit_cells = {}, {}
    local cell_units = {}
    local num_units = 3 * n + #(cell_region_list.regions)
    for u = 1, num_units do used[u] = 0; unit_cells[u] = {} end
    for idx = 1, total do
        local r = math.floor((idx - 1) / n) + 1
        local c = (idx - 1) % n + 1
        local b = math.floor((r - 1) / box_rows) * num_stacks + math.floor((c - 1) / box_cols) + 1
        local list = { r, n + c, 2 * n + b }
        local extra = cell_region_list.of[idx]
        if extra then
            for _, ri in ipairs(extra) do list[#list + 1] = 3 * n + ri end
        end
        cell_units[idx] = list
        for _, u in ipairs(list) do
            local uc = unit_cells[u]
            uc[#uc + 1] = idx
        end
    end

    local value, free = {}, {}
    for idx = 1, total do value[idx] = 0 end
    local nodes = 0

    local function search(remaining)
        if remaining == 0 then return true end
        nodes = nodes + 1
        if nodes > node_limit then return false end

        local best, best_cnt = nil, n + 1
        for idx = 1, total do
            if value[idx] == 0 then
                local m = 0
                for _, u in ipairs(cell_units[idx]) do m = bor(m, used[u]) end
                local f = band(bnot(m), full_mask)
                free[idx] = f
                local cnt, x = 0, f
                while x ~= 0 do x = band(x, x - 1); cnt = cnt + 1 end
                if cnt == 0 then return false end
                if cnt < best_cnt then best, best_cnt = idx, cnt end
            end
        end
        local best_free = free[best]
        -- Every unit must still have room for each of its missing digits; and
        -- a digit with a single place left in a unit is as forced as a cell
        -- with a single digit left, so branch on it the same way.
        for u = 1, num_units do
            local m = used[u]
            if m ~= full_mask then
                local once, twice = m, m
                for _, idx in ipairs(unit_cells[u]) do
                    if value[idx] == 0 then
                        local f = free[idx]
                        twice = bor(twice, band(once, f))
                        once  = bor(once, f)
                    end
                end
                if once ~= full_mask then return false end
                if best_cnt > 1 and twice ~= full_mask then
                    local d = band(bnot(twice), full_mask)
                    d = band(d, -d)
                    for _, idx in ipairs(unit_cells[u]) do
                        if value[idx] == 0 and band(free[idx], d) ~= 0 then
                            best, best_free, best_cnt = idx, d, 1
                            break
                        end
                    end
                end
            end
        end
        if best_cnt == 0 then return false end

        -- The candidate digits, shuffled.
        local cand, k = {}, 0
        for d = 1, n do
            if band(best_free, lshift(1, d - 1)) ~= 0 then k = k + 1; cand[k] = d end
        end
        for i = k, 2, -1 do
            local j = randInt(i)
            cand[i], cand[j] = cand[j], cand[i]
        end

        local units = cell_units[best]
        for i = 1, k do
            local d = cand[i]
            local m = lshift(1, d - 1)
            value[best] = d
            for _, u in ipairs(units) do used[u] = bor(used[u], m) end
            if search(remaining - 1) then return true end
            for _, u in ipairs(units) do used[u] = band(used[u], bnot(m)) end
            value[best] = 0
            if nodes > node_limit then return false end
        end
        return false
    end

    if not search(total) then return false end
    for idx = 1, total do
        grid[math.floor((idx - 1) / n) + 1][(idx - 1) % n + 1] = value[idx]
    end
    return true
end

local function fillBoard(grid, n, box_rows, box_cols, extra_regions, randInt)
    randInt = randInt or math.random
    -- extra_regions as unit numbers per cell index.
    local list = { regions = extra_regions, of = {} }
    for ri, region in ipairs(extra_regions) do
        for _, cell in ipairs(region) do
            local idx = (cell.r - 1) * n + cell.c
            list.of[idx] = list.of[idx] or {}
            table.insert(list.of[idx], ri)
        end
    end
    for _ = 1, FILL_MAX_RESTARTS do
        if fillBoardOnce(grid, n, box_rows, box_cols, list, randInt, FILL_NODE_LIMIT) then
            return true
        end
    end
    -- Regions that make every fill this hard (none of the shipped variants):
    -- search to the end rather than loop forever.
    return fillBoardOnce(grid, n, box_rows, box_cols, list, randInt, math.huge)
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
-- through the backtracking fill (fillBoard) instead of the fast Latin-square
-- construction, since the latter can't guarantee arbitrary extra regions.
-- randInt(i) -> [1,i] (optional): see shuffledDigits' doc comment above.
local function generateSolvedBoard(n, box_rows, box_cols, extra_regions, randInt)
    if extra_regions then
        local grid = emptyGrid(n)
        fillBoard(grid, n, box_rows, box_cols, extra_regions, randInt)
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
--
-- Both are ceilings, though, and a ceiling alone did not separate the levels:
-- see "Difficulty floors" below.
-- ---------------------------------------------------------------------------

local DIG_RATIOS = { easy = 0.43, medium = 0.56, hard = 0.65, expert = nil }

-- ---------------------------------------------------------------------------
-- Difficulty floors
--
-- Digging a 9x9 grid at random down to medium's 36 or hard's 29 clues almost
-- always leaves a grid the singles finish on their own: measured 2026-11-05,
-- Medium 100%, Hard 94% and even Expert 68% singles-only, so Medium, Hard and
-- Expert only differed by clue count. Random minimal puzzles are mostly easy;
-- the tier cap could never make them harder.
--
-- A floor is the missing lower bound: the finished grid must need at least
-- `steps` deductions beyond the singles (locked candidates or harder), or
-- one technique of tier `or_tier` or above. createPuzzle gets there by:
--
--   1. digging to the ratio, exactly as before -- when the floor already
--      holds there, that is the puzzle, unchanged;
--   2. otherwise digging on through the cells not asked yet, still within
--      tier_cap, until the floor holds;
--   3. if it does, putting clues back (earliest removed first) while it still
--      holds, up to the ratio's clue count, so the levels keep their clue
--      gradient too;
--   4. if the cells run out first, putting a few clues back into the
--      hardest grid seen so far and digging it again in a new order, at
--      most `attempts` digs in all, and keeping the hardest grid seen. The
--      solution never changes, only which clues are left.
--      Attempts are counted, never timed: a given randInt still gives the
--      same puzzle on every device (the Daily Challenge relies on it).
--
-- Medium needs one step past the singles (a locked candidate or a naked
-- pair, the first thing tier LOCKED adds); Hard three such steps or one of
-- tier SUBSETS; Expert five, or one of tier FISH. Measured 2026-11-06 over
-- 500 9x9 seeds, the floor holds on 99% of Medium, 96% of Hard and 88% of
-- Expert grids; a miss returns the hardest of its digs, which nearly always
-- needs a step or more past the singles too (all but 1-2% of them).
--
-- Grids below FLOOR_MIN_N get no floor: a 4x4 or 6x6 grid has no room for
-- anything past the singles, whatever is dug.
-- ---------------------------------------------------------------------------

local SINGLES_TIER = logic_solver.TIER.SINGLES
local SUBSETS      = logic_solver.TIER.SUBSETS
local FISH         = logic_solver.TIER.FISH
local FLOOR_MIN_N  = 9
local FLOORS = {
    medium = { steps = 1,                   attempts = 14 },
    hard   = { steps = 3, or_tier = SUBSETS, attempts = 14 },
    expert = { steps = 5, or_tier = FISH,    attempts = 10 },
}
-- Share of the cells a retry puts back into the best grid so far before
-- digging it again: a few when that grid already needs something past the
-- singles (a nearby grid is often a little harder), many when the singles
-- finish it (start well away from it). Measured on 9x9, 2026-11-06 (200-500
-- seeds): 8 and 24 clues met the floors at least as often as 2-5, 12-16 or
-- digging the solved grid afresh, for less work per retry.
local RESTORE      = 0.10
local RESTORE_EASY = 0.30

-- Search budget of one otherSolution() call (nodes, never time): past it
-- the test falls back to plain deduction, which gives the same answer.
local OTHER_SOLUTION_NODES = 2000
local OTHER_SOLUTION_MAX_N = 12

-- Steps the singles do not cover (cage_last_cell is a single for killer
-- cages; createPuzzle never sees cages, listed for completeness).
local SINGLES = { naked_single = true, hidden_single = true, cage_last_cell = true }

local function nonSingleSteps(counts)
    local k = 0
    for name, c in pairs(counts) do
        if not SINGLES[name] then k = k + c end
    end
    return k
end

local function floorHolds(floor, max_tier, steps)
    return steps >= floor.steps or (floor.or_tier ~= nil and max_tier >= floor.or_tier)
end

local function shuffle(list, randInt)
    for i = #list, 2, -1 do
        local j = randInt(i)
        list[i], list[j] = list[j], list[i]
    end
    return list
end

-- One dig of `puzzle` (changed in place), asking the givens listed in
-- `cells`, in that order, whether they can go. Returns the puzzle, the
-- number of empty cells, and whether `floor` (nil: none) holds.
-- report(fraction of `cells` examined) drives the progress bar.
local function dig(puzzle, solved_grid, cells, n, box_rows, box_cols, extra_regions,
                   tier_cap, removals, floor, report)
    local total = n * n

    -- Each cell is asked once, in this order, "is the puzzle without it still
    -- solvable within tier_cap?" -- the same question as
    -- logic_solver.solvableWithin(puzzle minus that clue), answered
    -- incrementally (see "Incremental digging support" in logic_solver.lua):
    --   kept  -- a running state holding the clues already decided to stay
    --            and what the singles deduce from them. Those clues are in
    --            every puzzle asked about from then on, so whatever follows
    --            from them can be taken as known instead of re-derived.
    --   a test starts from kept, adds the clues not asked about yet, and
    --            stops as soon as the removed clue is deduced back: the
    --            puzzle with it is solvable (it always is -- it is the
    --            solved grid, or a puzzle that already passed), so from
    --            there deduction completes the grid.
    -- Same answers, same puzzles, a fraction of the work on big grids.
    --
    -- Above the singles, a test is answered in up to three steps, cheapest
    -- first (the answer is the same as one deduce() at tier_cap, so are the
    -- puzzles):
    --   1. deduce with the singles only: if that brings the clue back, so
    --      would tier_cap;
    --   2. otherwise, from where that got stuck, look for a solution with
    --      another digit in the cell: if there is one, the puzzle without the
    --      clue is ambiguous and no deduction can bring it back. Near the end
    --      of an Expert dig nearly every test fails this way, and this
    --      settles it in a fraction of the time the subsets and fish took to
    --      give up (see logic_solver.otherSolution);
    --   3. otherwise carry the deduction on at tier_cap.
    local function removable(ctx, st, idx, digit)
        if tier_cap <= SINGLES_TIER or n > OTHER_SOLUTION_MAX_N then
            return logic_solver.deduce(ctx, st, tier_cap, idx)
        end
        if logic_solver.deduce(ctx, st, SINGLES_TIER, idx) then return true end
        if st.broken then return false end
        if logic_solver.otherSolution(ctx, st, idx, digit, OTHER_SOLUTION_NODES) then
            return false
        end
        return logic_solver.deduce(ctx, st, tier_cap, idx)
    end

    local removed = 0
    for r = 1, n do
        for c = 1, n do
            if puzzle[r][c] == 0 then removed = removed + 1 end
        end
    end
    local ctx, kept = logic_solver.digState(n, box_rows, box_cols, extra_regions)
    local order = {}
    local function tryRemove(cell)
        local row, col = cell.r, cell.c
        local idx    = (row - 1) * n + col
        local backup = puzzle[row][col]
        puzzle[row][col] = 0
        local st = logic_solver.stateWithClues(ctx, kept, puzzle)
        if removable(ctx, st, idx, backup) then
            removed = removed + 1
            order[#order + 1] = cell
            return true
        end
        puzzle[row][col] = backup
        logic_solver.placeClue(ctx, kept, idx, backup)
        logic_solver.deduceSingles(ctx, kept)
        return false
    end

    local count = #cells
    local i = 1
    while i <= count and removed < removals do
        tryRemove(cells[i])
        report(i / count)
        i = i + 1
    end
    if not floor then return puzzle, removed, true end

    -- Does the floor hold on the puzzle as it stands? The singles alone
    -- (cheap) settle most cases: if they finish the grid, it does not.
    -- Also leaves in `rated` the puzzle's rating when it took one (nil: the
    -- singles finish it), for createPuzzle to rank a grid that misses.
    local _, empty = logic_solver.digState(n, box_rows, box_cols, extra_regions)
    local rated
    local function holds()
        rated = nil
        local st = logic_solver.stateWithClues(ctx, empty, puzzle)
        logic_solver.deduceSingles(ctx, st)
        if st.unsolved == 0 then return false end
        -- Stuck on singles but solvable within tier_cap: at least one step
        -- beyond them is needed.
        if floor.steps <= 1 then return true end
        rated = logic_solver.solve(puzzle, n, box_rows, box_cols, extra_regions,
                                   { max_tier = tier_cap })
        return floorHolds(floor, rated.max_tier, nonSingleSteps(rated.counts))
    end

    -- Past the ratio, a level stops digging as soon as its floor holds;
    -- Expert (no ratio) always digs to the end.
    -- A grid that misses comes back with its rating when holds() took one
    -- on it as it stands (a failed removal puts the clue back), or
    -- "singles" when the singles finish it.
    local ok = removed >= removals and holds()
    local looked = removed >= removals
    while not ok and i <= count do
        if tryRemove(cells[i]) and removed >= removals then
            ok = holds()
            looked = true
        end
        report(i / count)
        i = i + 1
    end
    -- (Expert, or a dig that ran out of cells before the ratio: not looked
    -- at yet.)
    if not ok and not looked then ok = holds() end
    if not ok then return puzzle, removed, false, rated or "singles" end

    -- Back up to the ratio's clue count while the floor still holds: the
    -- clues this dig took first, then any other empty cell.
    if ok and removed > removals then
        local back = {}
        for k = 1, #order do back[k] = order[k] end
        local mine = {}
        for k = 1, #order do mine[(order[k].r - 1) * n + order[k].c] = true end
        for r = 1, n do
            for c = 1, n do
                if puzzle[r][c] == 0 and not mine[(r - 1) * n + c] then
                    back[#back + 1] = { r = r, c = c }
                end
            end
        end
        for k = 1, #back do
            if removed <= removals then break end
            local cell = back[k]
            puzzle[cell.r][cell.c] = solved_grid[cell.r][cell.c]
            if holds() then
                removed = removed - 1
            else
                puzzle[cell.r][cell.c] = 0
            end
        end
    end
    return puzzle, removed, ok
end

-- on_progress (optional): called as the digging goes as
-- on_progress(done, total), done/total being the fraction of the work done
-- (a retry for the floor takes the bar on from where it was), so callers
-- can drive a real progress bar instead of a fake timer.
--
-- Returns the puzzle plus an info table describing what was actually produced:
--   { tier_cap  = the tier the dig was allowed to use,
--     max_tier  = the hardest tier the finished grid really needs,
--     counts    = { [technique name] = times needed },
--     steps     = deductions needed beyond the singles,
--     floor_met = the level's floor holds (true when it has none),
--     attempts  = digs it took,
--     clues     = number of givens left }
-- max_tier can legitimately come out below tier_cap -- a 4x4 grid has no room
-- for an X-Wing no matter how hard you dig -- so report it rather than pretend
-- the label was achieved.
local function createPuzzle(solved_grid, difficulty, n, box_rows, box_cols, extra_regions, randInt, on_progress)
    randInt = randInt or math.random
    local total    = n * n
    local tier_cap = logic_solver.DIFFICULTY_TIER[difficulty]
                     or logic_solver.DIFFICULTY_TIER.medium
    local ratio    = DIG_RATIOS[difficulty]
    local floor    = FLOORS[difficulty]
    -- Unknown difficulty strings fell back to "medium" before; keep that.
    if ratio == nil and logic_solver.DIFFICULTY_TIER[difficulty] == nil then
        ratio = DIG_RATIOS.medium
        floor = FLOORS.medium
    end
    if n < FLOOR_MIN_N then floor = nil end
    local removals = ratio and math.floor(total * ratio) or total
    local attempts = floor and floor.attempts or 1

    -- First dig: the whole solved grid in a random order (exactly as before
    -- the floors, so a grid that meets its floor at the ratio is unchanged).
    local puzzle = copyGrid(solved_grid, n)
    local cells = {}
    for r = 1, n do
        for c = 1, n do cells[#cells + 1] = { r = r, c = c } end
    end
    shuffle(cells, randInt)

    local best, best_removed, best_key, best_rating
    local met = (floor == nil)
    local used = 0
    local base, span = 0, 1
    for attempt = 1, attempts do
        used = attempt
        if attempts > 1 then
            span = (attempt < attempts) and (1 - base) / 2 or (1 - base)
        end
        local b, s = base, span
        local report = on_progress
            and function(f) on_progress(b + s * f, 1) end
            or function() end
        local p, removed, ok, rating = dig(puzzle, solved_grid, cells, n, box_rows, box_cols,
                                           extra_regions, tier_cap, removals, floor, report)
        if ok then
            best, best_removed, best_rating, met = p, removed, nil, true
            break
        end
        -- Floor missed: keep the hardest grid so far (the latest on a tie)...
        local key
        if rating == "singles" then
            rating, key = nil, SINGLES_TIER * 10000
        else
            rating = rating or logic_solver.solve(p, n, box_rows, box_cols, extra_regions,
                                                  { max_tier = tier_cap })
            key = rating.max_tier * 10000 + nonSingleSteps(rating.counts)
        end
        if not best_key or key >= best_key then
            best, best_removed, best_key, best_rating = p, removed, key, rating
        end
        base = base + span
        if attempt == attempts then break end
        -- ...and dig it again: put back some of its clues at random, then
        -- ask every given again, in a new random order.
        local share = (best_key < 10000 * (SINGLES_TIER + 1)) and RESTORE_EASY or RESTORE
        local restore = math.floor(total * share)
        puzzle = copyGrid(best, n)
        local holes = {}
        for r = 1, n do
            for c = 1, n do
                if puzzle[r][c] == 0 then holes[#holes + 1] = { r = r, c = c } end
            end
        end
        for k = 1, math.min(restore, #holes) do
            local j = k - 1 + randInt(#holes - k + 1)
            holes[k], holes[j] = holes[j], holes[k]
            local cell = holes[k]
            puzzle[cell.r][cell.c] = solved_grid[cell.r][cell.c]
        end
        cells = {}
        for r = 1, n do
            for c = 1, n do
                if puzzle[r][c] ~= 0 then cells[#cells + 1] = { r = r, c = c } end
            end
        end
        shuffle(cells, randInt)
    end
    if on_progress then on_progress(1, 1) end

    local rating = best_rating or logic_solver.solve(best, n, box_rows, box_cols, extra_regions,
                                                     { max_tier = tier_cap })
    return best, {
        tier_cap  = tier_cap,
        max_tier  = rating.max_tier,
        counts    = rating.counts,
        steps     = nonSingleSteps(rating.counts),
        floor_met = met,
        attempts  = used,
        clues     = total - best_removed,
    }
end

return {
    generateSolvedBoard = generateSolvedBoard,
    countSolutions      = countSolutions,
    createPuzzle        = createPuzzle,
    -- For specs and audits (specs switch a floor off by setting
    -- FLOORS[level] to nil, then put it back).
    DIG_RATIOS          = DIG_RATIOS,
    FLOORS              = FLOORS,
    FLOOR_MIN_N         = FLOOR_MIN_N,
    nonSingleSteps      = nonSingleSteps,
}
