-- ---------------------------------------------------------------------------
-- logic_solver.lua — human-technique sudoku solver.
--
-- puzzle_generator.lua guarantees a *unique* solution, which is not the same
-- thing as a solution a human can reach. A uniquely-solvable grid can still
-- require bifurcation (try a digit, see if it blows up, backtrack) -- that is
-- guessing, not deduction, and it is what made the old clue-count-based
-- difficulty labels meaningless.
--
-- This module answers the stronger question: "can this grid be solved by
-- deduction alone, and which techniques does it need?". It is used for two
-- things:
--
--   1. Generation (puzzle_generator.createPuzzle) -- a clue may only be dug
--      out if what remains is still solvable by pure logic within the
--      difficulty's allowed technique set. Note that a grid solvable by pure
--      logic necessarily HAS a unique solution, so this single test replaces
--      the old countSolutions() == 1 check rather than adding to it.
--
--   2. Hints -- nextStep() returns the next available deduction, described
--      well enough to explain it ("hidden single: 7 is the only cell in this
--      box that can still take a 7") instead of just revealing a value.
--
-- Everything is expressed over generic "units" (a unit is a set of cells that
-- must contain each digit exactly once). Rows, columns and boxes are built in;
-- extra_regions (sudokux's diagonals, windoku's window boxes) simply become
-- more units, so those variants are supported without any special-casing.
--
-- Candidates are LuaJIT bitmasks (bit d-1 set == digit d still possible), same
-- dependency puzzle_generator.lua already has.
-- ---------------------------------------------------------------------------

local bit    = require("bit")
local band   = bit.band
local bor    = bit.bor
local bnot   = bit.bnot
local lshift = bit.lshift
local rshift = bit.rshift

local M = {}

-- ---------------------------------------------------------------------------
-- Technique tiers
--
-- A tier is "how advanced a solver you have to be". The generator digs against
-- a tier cap, so an "easy" grid is not merely a grid with more clues -- it is
-- a grid that provably never needs anything beyond singles.
-- ---------------------------------------------------------------------------

M.TIER = {
    SINGLES  = 1,   -- naked single, hidden single
    LOCKED   = 2,   -- locked candidates, naked pair
    SUBSETS  = 3,   -- hidden pair, naked/hidden triple, naked quad
    FISH     = 4,   -- X-Wing, Swordfish, XY-Wing
}

M.DIFFICULTY_TIER = {
    easy   = M.TIER.SINGLES,
    medium = M.TIER.LOCKED,
    hard   = M.TIER.SUBSETS,
    expert = M.TIER.FISH,
}

-- ---------------------------------------------------------------------------
-- Bit helpers
-- ---------------------------------------------------------------------------

-- Grids go up to 16x16, so every mask here fits in 16 bits: popcount is two
-- byte lookups, and lowestDigit a lookup on the isolated lowest bit. The
-- solver calls both on every cell of every unit, many times per dug clue.
local POP8 = {}
for i = 0, 255 do
    local c, x = 0, i
    while x ~= 0 do
        x = band(x, x - 1)
        c = c + 1
    end
    POP8[i] = c
end
local LOW_DIGIT = {}
for d = 1, 31 do LOW_DIGIT[lshift(1, d - 1)] = d end

local function popcount(x)
    if x >= 0 and x < 65536 then
        return POP8[band(x, 255)] + POP8[rshift(x, 8)]
    end
    local c = 0
    while x ~= 0 do
        x = band(x, x - 1)
        c = c + 1
    end
    return c
end

-- Digit (1-based) of the lowest set bit. Undefined for 0.
local function lowestDigit(mask)
    return LOW_DIGIT[band(mask, -mask)] or 1
end

local function digitsOf(mask)
    local out = {}
    while mask ~= 0 do
        local low = band(mask, -mask)
        out[#out + 1] = lowestDigit(low)
        mask = band(mask, mask - 1)
    end
    return out
end

-- Calls fn(env, pick) for every k-subset of list whose masks (mask_of[item],
-- a bitmask per item) together span exactly k bits -- the only subsets the
-- subset and fish techniques can use -- in lexicographic order, stopping
-- early if fn returns a truthy value (which is then returned). A branch whose
-- partial union already spans more than k bits is cut, since adding items
-- can only grow it: on a 16x16 grid that skips most of the C(16, 4) quads.
-- pick is reused between calls -- copy it if you need to keep it.
--
-- Written without closures (fn gets what it needs through env) and without
-- recursion, as an explicit walk over the subset indices, because LuaJIT
-- compiles neither well, and this runs for every unit on every step the
-- solver takes once singles run dry.
local function combinations(list, mask_of, k, fn, env)
    local m = #list
    if m < k then return nil end
    -- idx[d]: position in list picked at depth d; acc[d]: union of the
    -- masks picked at depths 1..d (acc[0] = 0).
    local pick, idx, acc = {}, { 0 }, { [0] = 0 }
    local depth = 1
    while depth >= 1 do
        local i, limit = idx[depth] + 1, m - (k - depth)
        local u = 0
        while i <= limit do
            u = bor(acc[depth - 1], mask_of[list[i]])
            if popcount(u) <= k then break end
            i = i + 1
        end
        if i > limit then
            depth = depth - 1
        else
            idx[depth], pick[depth], acc[depth] = i, list[i], u
            if depth == k then
                if popcount(u) == k then
                    local hit = fn(env, pick)
                    if hit then return hit end
                end
            else
                depth = depth + 1
                idx[depth] = i
            end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Context: the geometry of one grid shape, independent of any puzzle.
--
-- Building it costs O(n^3)-ish, and the generator solves the same shape
-- hundreds of times while digging, so contexts are memoised. The cache is
-- keyed first on the extra_regions table identity (variants pass a
-- module-level constant) and held weakly, so a variant's regions table does
-- not keep its context alive after the plugin is unloaded.
-- ---------------------------------------------------------------------------

local NO_REGIONS  = {}   -- stand-in key for extra_regions == nil
local ctx_cache   = setmetatable({}, { __mode = "k" })

local function buildContext(n, box_rows, box_cols, extra_regions)
    local num_stacks = n / box_cols
    local ctx = {
        n         = n,
        box_rows  = box_rows,
        box_cols  = box_cols,
        cells     = n * n,
        full_mask = lshift(1, n) - 1,
        units     = {},
        unit_kind = {},
        rows      = {},
        cols      = {},
        unit_of   = {},
        in_unit   = {},
        peers     = {},
        peer_set  = {},
        row_of    = {},
        col_of    = {},
    }

    for r = 1, n do
        for c = 1, n do
            local idx = (r - 1) * n + c
            ctx.row_of[idx] = r
            ctx.col_of[idx] = c
            ctx.unit_of[idx] = {}
        end
    end

    local function addUnit(cell_idxs, kind)
        ctx.units[#ctx.units + 1] = cell_idxs
        local u = #ctx.units
        ctx.unit_kind[u] = kind
        local member = {}
        for _, idx in ipairs(cell_idxs) do
            local lst = ctx.unit_of[idx]
            lst[#lst + 1] = u
            member[idx] = true
        end
        ctx.in_unit[u] = member
        return u
    end

    for r = 1, n do
        local cells = {}
        for c = 1, n do cells[c] = (r - 1) * n + c end
        ctx.rows[r] = addUnit(cells, "row")
    end
    for c = 1, n do
        local cells = {}
        for r = 1, n do cells[r] = (r - 1) * n + c end
        ctx.cols[c] = addUnit(cells, "col")
    end
    for b = 1, n do
        local band_idx  = math.floor((b - 1) / num_stacks)
        local stack_idx = (b - 1) % num_stacks
        local cells = {}
        for dr = 1, box_rows do
            for dc = 1, box_cols do
                local r = band_idx * box_rows + dr
                local c = stack_idx * box_cols + dc
                cells[#cells + 1] = (r - 1) * n + c
            end
        end
        addUnit(cells, "box")
    end
    if extra_regions then
        for _, region in ipairs(extra_regions) do
            local cells = {}
            for _, cell in ipairs(region) do
                cells[#cells + 1] = (cell.r - 1) * n + cell.c
            end
            addUnit(cells, "region")
        end
    end

    -- Overlaps: for each unit u, every other unit v sharing at least two
    -- cells with it, with the cells of u outside v and of v outside u. Only
    -- such a pair can lock a digit (see lockedCandidates).
    ctx.overlaps = {}
    for u = 1, #ctx.units do
        local list = {}
        for v = 1, #ctx.units do
            if v ~= u then
                local shared, u_only, v_only = 0, {}, {}
                local in_u, in_v = ctx.in_unit[u], ctx.in_unit[v]
                for _, idx in ipairs(ctx.units[u]) do
                    if in_v[idx] then shared = shared + 1 else u_only[#u_only + 1] = idx end
                end
                if shared >= 2 then
                    for _, idx in ipairs(ctx.units[v]) do
                        if not in_u[idx] then v_only[#v_only + 1] = idx end
                    end
                    list[#list + 1] = { v = v, u_only = u_only, v_only = v_only }
                end
            end
        end
        ctx.overlaps[u] = list
    end

    -- Peers: every cell sharing at least one unit. Used to propagate a
    -- placement and, in xy_wing, to ask "does this cell see both wings?".
    for idx = 1, ctx.cells do
        local seen = {}
        local list = {}
        for _, u in ipairs(ctx.unit_of[idx]) do
            for _, other in ipairs(ctx.units[u]) do
                if other ~= idx and not seen[other] then
                    seen[other] = true
                    list[#list + 1] = other
                end
            end
        end
        ctx.peers[idx]    = list
        ctx.peer_set[idx] = seen
    end

    -- Slots of st.idle (see unitIdle), one per (technique, unit) or
    -- (fish, orientation, digit), packed into one array.
    local nu = #ctx.units
    ctx.idle_hidden_single = 0
    ctx.idle_locked = nu
    ctx.idle_naked  = { [2] = 2 * nu, [3] = 3 * nu, [4] = 4 * nu }
    ctx.idle_hidden = { [2] = 5 * nu, [3] = 6 * nu, [4] = 7 * nu }
    ctx.idle_fish   = { [2] = 8 * nu, [3] = 8 * nu + 2 * n }
    ctx.idle_xy     = 8 * nu + 4 * n + 1
    ctx.idle_slots  = ctx.idle_xy

    return ctx
end

local function getContext(n, box_rows, box_cols, extra_regions)
    local key      = extra_regions or NO_REGIONS
    local by_shape = ctx_cache[key]
    if not by_shape then
        by_shape = {}
        ctx_cache[key] = by_shape
    end
    local shape = n .. ":" .. box_rows .. ":" .. box_cols
    local ctx   = by_shape[shape]
    if not ctx then
        ctx = buildContext(n, box_rows, box_cols, extra_regions)
        by_shape[shape] = ctx
    end
    return ctx
end

M.getContext = getContext

-- ---------------------------------------------------------------------------
-- Solver state
-- ---------------------------------------------------------------------------

local function eliminate(ctx, st, idx, digit)
    local m = lshift(1, digit - 1)
    local cur = st.cand[idx]
    if band(cur, m) == 0 then return false end
    local nc = band(cur, bnot(m))
    st.cand[idx] = nc
    if nc == 0 and st.value[idx] == 0 then st.broken = true end
    local ustamp = st.ustamp
    if ustamp then
        local tick = st.tick
        local us = ctx.unit_of[idx]
        for i = 1, #us do ustamp[us[i]] = tick end
        st.dstamp[digit], st.gstamp = tick, tick
    end
    return true
end

local function place(ctx, st, idx, digit)
    local m = lshift(1, digit - 1)
    if band(st.cand[idx], m) == 0 then
        st.broken = true
        return false
    end
    local value, cand = st.value, st.cand
    -- Change stamps, kept only by the generator's states (see M.deduce).
    local ustamp, tick = st.ustamp, st.tick
    local unit_of = ctx.unit_of
    if ustamp then
        local dstamp, gone = st.dstamp, cand[idx]
        while gone ~= 0 do
            dstamp[LOW_DIGIT[band(gone, -gone)]] = tick
            gone = band(gone, gone - 1)
        end
        local us = unit_of[idx]
        for i = 1, #us do ustamp[us[i]] = tick end
        st.gstamp = tick
    end
    value[idx] = digit
    cand[idx]  = 0
    st.unsolved = st.unsolved - 1
    local keep = bnot(m)
    for _, p in ipairs(ctx.peers[idx]) do
        if value[p] == digit then
            st.broken = true
            return false
        end
        -- eliminate(ctx, st, p, digit), inlined: this is the solver's
        -- innermost loop.
        local cur = cand[p]
        if band(cur, m) ~= 0 then
            local nc = band(cur, keep)
            cand[p] = nc
            if nc == 0 and value[p] == 0 then st.broken = true end
            if ustamp then
                local us = unit_of[p]
                for i = 1, #us do ustamp[us[i]] = tick end
            end
        end
    end
    return not st.broken
end

-- Skipping work that cannot find anything new. The generator's test states
-- (M.stateWithClues) carry change stamps: st.tick is bumped before every
-- scan, and a change to a cell (value or candidates) stamps the units it
-- belongs to, the digits it concerns, and the grid with the current tick. A
-- technique that scanned a unit (or a digit, for fish) and found nothing
-- records the tick in st.idle[key]; if nothing it reads has been stamped
-- since (a stamp >= the recorded tick counts as "maybe changed"), scanning
-- it again would find nothing again, so it is skipped. Plain solve() states
-- have no stamps and always scan everything.
local function unitIdle(st, key, u)
    return st.ustamp[u] < st.idle[key]
end

-- Returns the state, or nil if the given grid is already self-contradictory.
local function newState(ctx, grid)
    local n  = ctx.n
    local st = { value = {}, cand = {}, unsolved = ctx.cells, broken = false }
    for idx = 1, ctx.cells do
        st.value[idx] = 0
        st.cand[idx]  = ctx.full_mask
    end
    for r = 1, n do
        for c = 1, n do
            local v = grid[r][c]
            if v ~= 0 then
                if not place(ctx, st, (r - 1) * n + c, v) then return nil end
            end
        end
    end
    return st
end

local function rc(ctx, idx)
    return ctx.row_of[idx], ctx.col_of[idx]
end

local function cellList(ctx, idxs)
    local out = {}
    for i, idx in ipairs(idxs) do
        local r, c = rc(ctx, idx)
        out[i] = { r = r, c = c }
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Techniques
--
-- Each returns a step table (or nil). A step never mutates the state -- it
-- only describes what may be done, so the same function serves both the
-- solve loop and the hint button. applyStep() performs it.
--
-- step = {
--   technique    = "hidden_single",
--   tier         = 1,
--   digit        = 7,                    -- the digit the step is about, if any
--   unit_kind    = "box",                -- which kind of unit justifies it
--   placements   = { {r=,c=,digit=} },   -- values that can be written
--   eliminations = { {r=,c=,digit=} },   -- candidates that can be struck out
--   focus        = { {r=,c=} },          -- cells a hint should highlight
-- }
-- ---------------------------------------------------------------------------

local function nakedSingle(ctx, st)
    for idx = 1, ctx.cells do
        local cand = st.cand[idx]
        if st.value[idx] == 0 and cand ~= 0 and band(cand, cand - 1) == 0 then
            local d    = lowestDigit(st.cand[idx])
            local r, c = rc(ctx, idx)
            return {
                technique  = "naked_single",
                tier       = M.TIER.SINGLES,
                digit      = d,
                placements = { { r = r, c = c, digit = d } },
                focus      = { { r = r, c = c } },
            }
        end
    end
    return nil
end

-- One pass over a unit's cells: which digits are placed in it, and which are
-- still a candidate in at least one / at least two of its open cells. The
-- per-digit scans of hiddenSingle and lockedCandidates only ever act on a
-- digit that is unplaced and held once (resp. twice or more), so these masks
-- let them skip every other digit without changing what they find.
local function unitDigitMasks(st, cells)
    local placed, once, twice = 0, 0, 0
    local value, cand = st.value, st.cand
    for i = 1, #cells do
        local idx = cells[i]
        local v = value[idx]
        if v ~= 0 then
            placed = bor(placed, lshift(1, v - 1))
        else
            local cm = cand[idx]
            twice = bor(twice, band(once, cm))
            once  = bor(once, cm)
        end
    end
    return placed, once, twice
end

local function hiddenSingle(ctx, st)
    for u = 1, #ctx.units do
        local cells = ctx.units[u]
        local placed, once, twice = unitDigitMasks(st, cells)
        local single = band(band(once, bnot(twice)), bnot(placed))
        while single ~= 0 do
            local m   = band(single, -single)
            local d   = lowestDigit(m)
            local hit
            for _, idx in ipairs(cells) do
                if st.value[idx] == 0 and band(st.cand[idx], m) ~= 0 then
                    hit = idx
                    break
                end
            end
            if popcount(st.cand[hit]) > 1 then
                local r, c = rc(ctx, hit)
                return {
                    technique  = "hidden_single",
                    tier       = M.TIER.SINGLES,
                    digit      = d,
                    unit_kind  = ctx.unit_kind[u],
                    placements = { { r = r, c = c, digit = d } },
                    -- Nobody reads the focus of a step the generator takes.
                    focus      = not st.lean and cellList(ctx, cells) or nil,
                }
            end
            single = band(single, single - 1)
        end
    end
    return nil
end

-- Locked candidates, stated generically: if every cell of unit A that can
-- still take digit d also belongs to unit B, then d is used up inside the
-- overlap, so it can be struck from B outside A. Classic "pointing" (box ->
-- line) and "claiming" (line -> box) are both instances, and so are the
-- interactions with windoku/sudokux extra regions -- no special-casing.
-- With change stamps (see unitIdle), a unit is skipped when neither it nor
-- any unit overlapping it changed since it last yielded nothing.
local function lockedIdle(ctx, st, u)
    local since = st.idle[ctx.idle_locked + u]
    local ustamp = st.ustamp
    if ustamp[u] >= since then return false end
    for _, ov in ipairs(ctx.overlaps[u]) do
        if ustamp[ov.v] >= since then return false end
    end
    return true
end

local function lockedCandidates(ctx, st)
    local tracked = st.ustamp ~= nil
    for u = 1, #ctx.units do
      if not (tracked and lockedIdle(ctx, st, u)) then
        local cells = ctx.units[u]
        local placed, _, twice = unitDigitMasks(st, cells)
        local multi = band(twice, bnot(placed))
        -- Cheap filter first: a digit can only produce a step if, for some
        -- overlapping unit v, none of u's cells outside v can take it while
        -- some of v's cells outside u still can. Digits failing that for
        -- every v are skipped; the rest go through the exact search below,
        -- so the step found is the same as without the filter.
        local useful = 0
        if multi ~= 0 then
            local cand = st.cand
            for _, ov in ipairs(ctx.overlaps[u]) do
                local outside_v, outside_u = 0, 0
                for _, idx in ipairs(ov.u_only) do outside_v = bor(outside_v, cand[idx]) end
                local locked = band(multi, bnot(outside_v))
                if locked ~= 0 then
                    for _, idx in ipairs(ov.v_only) do outside_u = bor(outside_u, cand[idx]) end
                    useful = bor(useful, band(locked, outside_u))
                end
            end
        end
        multi = useful
        while multi ~= 0 do
            local m = band(multi, -multi)
            local d = lowestDigit(m)
            multi = band(multi, multi - 1)
            local holders = {}
            for _, idx in ipairs(cells) do
                if st.value[idx] == 0 and band(st.cand[idx], m) ~= 0 then
                    holders[#holders + 1] = idx
                end
            end
            if #holders >= 2 then   -- always: multi only keeps digits held twice
                -- Any unit covering all holders must be one of the first
                -- holder's units, so there are at most a handful to test.
                local is_holder = {}
                for _, h in ipairs(holders) do is_holder[h] = true end
                for _, v in ipairs(ctx.unit_of[holders[1]]) do
                    if v ~= u then
                        local member = ctx.in_unit[v]
                        local covers = true
                        for i = 2, #holders do
                            if not member[holders[i]] then covers = false break end
                        end
                        if covers then
                            local elims = {}
                            for _, idx in ipairs(ctx.units[v]) do
                                if st.value[idx] == 0 and not is_holder[idx]
                                   and band(st.cand[idx], m) ~= 0 then
                                    local r, c = rc(ctx, idx)
                                    elims[#elims + 1] = { r = r, c = c, digit = d }
                                end
                            end
                            if #elims > 0 then
                                return {
                                    technique    = "locked_candidates",
                                    tier         = M.TIER.LOCKED,
                                    digit        = d,
                                    unit_kind    = ctx.unit_kind[u],
                                    eliminations = elims,
                                    focus        = cellList(ctx, holders),
                                }
                            end
                        end
                    end
                end
            end
        end
        if tracked then st.idle[ctx.idle_locked + u] = st.tick end
      end
    end
    return nil
end

-- Naked subset of size k: k cells in a unit whose candidates together span
-- exactly k digits -- those digits are spoken for, strike them elsewhere.
local function nakedSubsetPick(env, pick)
    local ctx, st, k, cells = env.ctx, env.st, env.k, env.cells
    local union = 0
    for i = 1, k do union = bor(union, st.cand[pick[i]]) end
    if popcount(union) ~= k then return nil end
    local in_pick = {}
    for i = 1, k do in_pick[pick[i]] = true end
    local elims = {}
    for _, idx in ipairs(cells) do
        if st.value[idx] == 0 and not in_pick[idx] then
            local shared = band(st.cand[idx], union)
            if shared ~= 0 then
                local r, c = rc(ctx, idx)
                for _, d in ipairs(digitsOf(shared)) do
                    elims[#elims + 1] = { r = r, c = c, digit = d }
                end
            end
        end
    end
    if #elims == 0 then return nil end
    local picked = {}
    for i = 1, k do picked[i] = pick[i] end
    return {
        technique    = env.technique,
        tier         = env.tier,
        unit_kind    = ctx.unit_kind[env.u],
        digits       = digitsOf(union),
        eliminations = elims,
        focus        = cellList(ctx, picked),
    }
end

local function nakedSubset(ctx, st, k, technique, tier)
    local env = { ctx = ctx, st = st, k = k, technique = technique, tier = tier }
    local tracked = st.ustamp ~= nil
    for u = 1, #ctx.units do
        local cells = ctx.units[u]
        local key   = tracked and (ctx.idle_naked[k] + u)
        if not (tracked and unitIdle(st, key, u)) then
            local pool  = {}
            for _, idx in ipairs(cells) do
                local pc = popcount(st.cand[idx])
                if st.value[idx] == 0 and pc >= 2 and pc <= k then
                    pool[#pool + 1] = idx
                end
            end
            env.u, env.cells = u, cells
            local step = combinations(pool, st.cand, k, nakedSubsetPick, env)
            if step then return step end
            if tracked then st.idle[key] = st.tick end
        end
    end
    return nil
end

-- Hidden subset of size k: k digits in a unit confined to exactly k cells --
-- those cells are spoken for, strike every *other* digit from them.
local function hiddenSubsetPick(env, pick)
    local ctx, st, k, cells, pos = env.ctx, env.st, env.k, env.cells, env.pos
    local union, dmask = 0, 0
    for i = 1, k do
        union = bor(union, pos[pick[i]])
        dmask = bor(dmask, lshift(1, pick[i] - 1))
    end
    if popcount(union) ~= k then return nil end
    local elims, focus = {}, {}
    local slots = union
    while slots ~= 0 do
        local slot = lowestDigit(band(slots, -slots))
        local idx  = cells[slot]
        local r, c = rc(ctx, idx)
        focus[#focus + 1] = { r = r, c = c }
        local extra = band(st.cand[idx], bnot(dmask))
        for _, d in ipairs(digitsOf(extra)) do
            elims[#elims + 1] = { r = r, c = c, digit = d }
        end
        slots = band(slots, slots - 1)
    end
    if #elims == 0 then return nil end
    local digits = {}
    for i = 1, k do digits[i] = pick[i] end
    return {
        technique    = env.technique,
        tier         = env.tier,
        unit_kind    = ctx.unit_kind[env.u],
        digits       = digits,
        eliminations = elims,
        focus        = focus,
    }
end

local function hiddenSubset(ctx, st, k, technique, tier)
    local env = { ctx = ctx, st = st, k = k, technique = technique, tier = tier }
    local tracked = st.ustamp ~= nil
    for u = 1, #ctx.units do
        local cells = ctx.units[u]
        local key   = tracked and (ctx.idle_hidden[k] + u)
        if not (tracked and unitIdle(st, key, u)) then
        -- pos[d]: the slots (bit i-1 = cells[i]) where d can still go, built
        -- in one pass over the unit's cells.
        local pos, placed = {}, 0
        for d = 1, ctx.n do pos[d] = 0 end
        for i, idx in ipairs(cells) do
            local v = st.value[idx]
            if v ~= 0 then
                placed = bor(placed, lshift(1, v - 1))
            else
                local cm, slot = st.cand[idx], lshift(1, i - 1)
                while cm ~= 0 do
                    local d = LOW_DIGIT[band(cm, -cm)]
                    pos[d] = bor(pos[d], slot)
                    cm = band(cm, cm - 1)
                end
            end
        end
        local pool = {}
        for d = 1, ctx.n do
            local pc = popcount(pos[d])
            if band(placed, lshift(1, d - 1)) == 0 and pc >= 2 and pc <= k then
                pool[#pool + 1] = d
            end
        end
        env.u, env.cells, env.pos = u, cells, pos
        local step = combinations(pool, pos, k, hiddenSubsetPick, env)
        if step then return step end
        if tracked then st.idle[key] = st.tick end
        end
    end
    return nil
end

-- Fish of size k (k=2 X-Wing, k=3 Swordfish), on rows against columns and
-- vice versa. Deliberately restricted to rows/cols: a "fish" over arbitrary
-- extra regions is not a technique a human would recognise, and the point of
-- the tiers is to describe human effort.
local function fishPick(env, pick)
    local ctx, st, k, pos, m, d = env.ctx, env.st, env.k, env.pos, env.m, env.d
    local orient, base_units, cover_line = env.orient, env.base_units, env.cover_line
    local union = 0
    for i = 1, k do union = bor(union, pos[pick[i]]) end
    if popcount(union) ~= k then return nil end
    local in_base = {}
    for i = 1, k do in_base[pick[i]] = true end
    local elims, focus = {}, {}
    for i = 1, k do
        for _, idx in ipairs(ctx.units[base_units[pick[i]]]) do
            if st.value[idx] == 0 and band(st.cand[idx], m) ~= 0 then
                local r, c = rc(ctx, idx)
                focus[#focus + 1] = { r = r, c = c }
            end
        end
    end
    local covers = union
    while covers ~= 0 do
        local ci = lowestDigit(band(covers, -covers))
        for _, idx in ipairs(ctx.units[cover_line[ci]]) do
            local base_line = (orient == "row") and ctx.row_of[idx] or ctx.col_of[idx]
            if not in_base[base_line] and st.value[idx] == 0
               and band(st.cand[idx], m) ~= 0 then
                local r, c = rc(ctx, idx)
                elims[#elims + 1] = { r = r, c = c, digit = d }
            end
        end
        covers = band(covers, covers - 1)
    end
    if #elims == 0 then return nil end
    return {
        technique    = env.technique,
        tier         = env.tier,
        digit        = d,
        unit_kind    = orient,
        eliminations = elims,
        focus        = focus,
    }
end

local FISH_ORIENTS = { "row", "col" }

local function fish(ctx, st, k, technique, tier)
    local n = ctx.n
    local env = { ctx = ctx, st = st, k = k, technique = technique, tier = tier }
    local tracked = st.ustamp ~= nil
    for oi, orient in ipairs(FISH_ORIENTS) do
        -- A fish on digit d reads only d's candidates and placements.
        local key0 = ctx.idle_fish[k] + (oi - 1) * n
        local busy = not tracked
        if tracked then
            for d = 1, n do
                if st.dstamp[d] >= st.idle[key0 + d] then busy = true break end
            end
        end
        if busy then
        local base_units = (orient == "row") and ctx.rows or ctx.cols
        local cover_of   = (orient == "row") and ctx.col_of or ctx.row_of
        local cover_line = (orient == "row") and ctx.cols or ctx.rows
        env.orient, env.base_units, env.cover_line = orient, base_units, cover_line
        -- line_pos[(d - 1) * n + li]: the cover lines where d can still go in
        -- base line li; line_placed[li]: the digits already placed in it. One
        -- pass over the grid for all digits at once.
        local line_pos, line_placed = {}, {}
        for i = 1, n * n do line_pos[i] = 0 end
        for li = 1, n do
            local placed = 0
            for _, idx in ipairs(ctx.units[base_units[li]]) do
                local v = st.value[idx]
                if v ~= 0 then
                    placed = bor(placed, lshift(1, v - 1))
                else
                    local cm, cover = st.cand[idx], lshift(1, cover_of[idx] - 1)
                    while cm ~= 0 do
                        local slot = (LOW_DIGIT[band(cm, -cm)] - 1) * n + li
                        line_pos[slot] = bor(line_pos[slot], cover)
                        cm = band(cm, cm - 1)
                    end
                end
            end
            line_placed[li] = placed
        end
        for d = 1, n do
            if not (tracked and st.dstamp[d] < st.idle[key0 + d]) then
                local m    = lshift(1, d - 1)
                local pool = {}
                local pos  = {}
                local base = (d - 1) * n
                for li = 1, n do
                    local mask = line_pos[base + li]
                    local pc = popcount(mask)
                    if band(line_placed[li], m) == 0 and pc >= 2 and pc <= k then
                        pool[#pool + 1] = li
                        pos[li] = mask
                    end
                end
                env.d, env.m, env.pos = d, m, pos
                local step = combinations(pool, pos, k, fishPick, env)
                if step then return step end
                if tracked then st.idle[key0 + d] = st.tick end
            end
        end
        end
    end
    return nil
end

-- XY-Wing: pivot {x,y} sees wing A {x,z} and wing B {y,z}. Whichever way the
-- pivot resolves, one wing becomes z -- so z is impossible in any cell seeing
-- both wings.
local function xyWing(ctx, st)
    local tracked = st.ustamp ~= nil
    if tracked and st.gstamp < st.idle[ctx.idle_xy] then return nil end
    local bi = {}
    for idx = 1, ctx.cells do
        if st.value[idx] == 0 and popcount(st.cand[idx]) == 2 then
            bi[#bi + 1] = idx
        end
    end
    -- The two digits of each bivalue cell, low then high.
    local lo, hi = {}, {}
    for _, idx in ipairs(bi) do
        local cm = st.cand[idx]
        lo[idx] = lowestDigit(cm)
        hi[idx] = lowestDigit(band(cm, cm - 1))
    end
    for _, pivot in ipairs(bi) do
        local x, y = lo[pivot], hi[pivot]
        for _, a in ipairs(bi) do
            if a ~= pivot and ctx.peer_set[pivot][a] then
                local a1, a2 = lo[a], hi[a]
                local z
                if a1 == x then z = a2 elseif a2 == x then z = a1 end
                if z and z ~= y then
                    local zmask = lshift(1, z - 1)
                    local want  = bor(lshift(1, y - 1), zmask)
                    for _, b in ipairs(bi) do
                        if b ~= pivot and b ~= a and ctx.peer_set[pivot][b]
                           and st.cand[b] == want then
                            local elims = {}
                            for idx = 1, ctx.cells do
                                if idx ~= a and idx ~= b and st.value[idx] == 0
                                   and ctx.peer_set[a][idx] and ctx.peer_set[b][idx]
                                   and band(st.cand[idx], zmask) ~= 0 then
                                    local r, c = rc(ctx, idx)
                                    elims[#elims + 1] = { r = r, c = c, digit = z }
                                end
                            end
                            if #elims > 0 then
                                return {
                                    technique    = "xy_wing",
                                    tier         = M.TIER.FISH,
                                    digit        = z,
                                    eliminations = elims,
                                    focus        = cellList(ctx, { pivot, a, b }),
                                }
                            end
                        end
                    end
                end
            end
        end
    end
    if tracked then st.idle[ctx.idle_xy] = st.tick end
    return nil
end

-- ---------------------------------------------------------------------------
-- Killer cages (optional)
--
-- A cage is { sum = n, cells = { {r=,c=}, ... } }: its cells hold distinct
-- digits adding to the sum. Passed in through opts.cages, and ignored
-- entirely when absent, so classic variants pay nothing for this.
--
-- The workhorse below is combination analysis: enumerate every way the cage's
-- unplaced cells could be filled, and keep only the digits that appear in at
-- least one. It subsumes the usual published shortcuts (a 3-cell 6 must be
-- 1-2-3, and so on) without hard-coding any of them.
-- ---------------------------------------------------------------------------

-- Walks the cage's unplaced cells, trying each cell's remaining candidates,
-- and records which digits survive in at least one complete solution. Returns
-- a per-cell mask of viable digits, or nil when the cage cannot be completed
-- at all (which makes the whole position contradictory).
local function cageViableDigits(ctx, st, cells, target)
    local k = #cells
    if k == 0 then return nil end

    local viable = {}
    for i = 1, k do viable[i] = 0 end

    local chosen = {}
    local used   = 0              -- digits already taken inside this cage
    local found  = false

    local function rec(i, remaining)
        if i > k then
            if remaining ~= 0 then return end
            found = true
            for j = 1, k do viable[j] = bor(viable[j], chosen[j]) end
            return
        end
        -- Every later cell needs at least 1, and at most n.
        local left = k - i
        local free = band(st.cand[cells[i]], bnot(used))
        while free ~= 0 do
            local m = band(free, -free)
            local d = lowestDigit(m)
            if d <= remaining - left and (remaining - d) <= left * ctx.n then
                chosen[i] = m
                used = bor(used, m)
                rec(i + 1, remaining - d)
                used = band(used, bnot(m))
            end
            free = band(free, free - 1)
        end
    end

    rec(1, target)
    if not found then return nil end
    return viable
end

local function cageCombinations(ctx, st)
    local cages = st.cages
    if not cages then return nil end

    for _, cage in ipairs(cages) do
        local open, target = {}, cage.sum
        for _, cell in ipairs(cage.cells) do
            local idx = (cell.r - 1) * ctx.n + cell.c
            local v = st.value[idx]
            if v ~= 0 then target = target - v else open[#open + 1] = idx end
        end

        if #open > 0 then
            local viable = cageViableDigits(ctx, st, open, target)
            if not viable then
                st.broken = true
                return nil
            end
            local elims, focus = {}, {}
            for i, idx in ipairs(open) do
                local dead = band(st.cand[idx], bnot(viable[i]))
                local r, c = rc(ctx, idx)
                focus[#focus + 1] = { r = r, c = c }
                for _, d in ipairs(digitsOf(dead)) do
                    elims[#elims + 1] = { r = r, c = c, digit = d }
                end
            end
            if #elims > 0 then
                return {
                    technique    = "cage_combinations",
                    tier         = M.TIER.LOCKED,
                    unit_kind    = "cage",
                    sum          = cage.sum,
                    eliminations = elims,
                    focus        = focus,
                }
            end
        end
    end
    return nil
end

-- One cell left in a cage: its value is simply what the sum still needs.
local function cageLastCell(ctx, st)
    local cages = st.cages
    if not cages then return nil end

    for _, cage in ipairs(cages) do
        local open, target = nil, cage.sum
        local count = 0
        for _, cell in ipairs(cage.cells) do
            local idx = (cell.r - 1) * ctx.n + cell.c
            local v = st.value[idx]
            if v ~= 0 then target = target - v else count = count + 1; open = idx end
        end
        if count == 1 and target >= 1 and target <= ctx.n then
            local m = lshift(1, target - 1)
            if band(st.cand[open], m) ~= 0 and popcount(st.cand[open]) > 1 then
                local r, c = rc(ctx, open)
                return {
                    technique  = "cage_last_cell",
                    tier       = M.TIER.SINGLES,
                    digit      = target,
                    unit_kind  = "cage",
                    sum        = cage.sum,
                    placements = { { r = r, c = c, digit = target } },
                    focus      = cellList(ctx, { open }),
                }
            end
        end
    end
    return nil
end

-- The "45 rule", the technique killer grids are actually built around: every
-- unit holds each digit once, so its cells always sum to 1+2+...+n. Compare
-- that against the cages sitting inside the unit and a single cell often falls
-- out, even on a grid with no given digits at all.
--
--   innie -- the cages inside the unit leave exactly one cell uncovered: that
--            cell is the unit total minus those cage sums.
--   outie -- the cages covering the unit overflow it by exactly one cell: that
--            outside cell is the cage sums minus the unit total.
local function cageUnitSums(ctx, st)
    local cages = st.cages
    if not cages then return nil end

    local n      = ctx.n
    local total  = n * (n + 1) / 2
    local in_unit_cache = ctx.in_unit

    for u = 1, #ctx.units do
        local member = in_unit_cache[u]
        local unit_cells = ctx.units[u]

        local covered, sum_inside = {}, 0
        local partial, partial_out = nil, nil
        local too_many = false

        for _, cage in ipairs(cages) do
            local inside, outside = {}, {}
            for _, cell in ipairs(cage.cells) do
                local idx = (cell.r - 1) * n + cell.c
                if member[idx] then inside[#inside + 1] = idx else outside[#outside + 1] = idx end
            end
            if #inside > 0 then
                if #outside == 0 then
                    sum_inside = sum_inside + cage.sum
                    for _, idx in ipairs(inside) do covered[idx] = true end
                elseif partial then
                    too_many = true
                    break
                else
                    partial, partial_out = cage, outside
                    for _, idx in ipairs(inside) do covered[idx] = true end
                end
            end
        end

        if not too_many then
            local uncovered = {}
            for _, idx in ipairs(unit_cells) do
                if not covered[idx] then uncovered[#uncovered + 1] = idx end
            end

            local target, cell
            if not partial and #uncovered == 1 then
                cell   = uncovered[1]
                target = total - sum_inside
            elseif partial and #uncovered == 0 and #partial_out == 1 then
                cell   = partial_out[1]
                target = (sum_inside + partial.sum) - total
            end

            if cell and target and target >= 1 and target <= n and st.value[cell] == 0 then
                local m = lshift(1, target - 1)
                if band(st.cand[cell], m) ~= 0 and popcount(st.cand[cell]) > 1 then
                    local r, c = rc(ctx, cell)
                    return {
                        technique  = partial and "cage_outie" or "cage_innie",
                        tier       = M.TIER.LOCKED,
                        digit      = target,
                        unit_kind  = ctx.unit_kind[u],
                        placements = { { r = r, c = c, digit = target } },
                        focus      = cellList(ctx, { cell }),
                    }
                end
            end
        end
    end
    return nil
end

-- Cheapest first, so the expensive subset/fish scans only run once the grid
-- is genuinely stuck on singles -- which is also what makes the tier a fair
-- description of the work a human has to do.
local TECHNIQUES = {
    { name = "naked_single",      tier = M.TIER.SINGLES, fn = nakedSingle },
    { name = "hidden_single",     tier = M.TIER.SINGLES, fn = hiddenSingle },
    { name = "cage_last_cell",    tier = M.TIER.SINGLES, fn = cageLastCell },
    { name = "cage_unit_sums",    tier = M.TIER.LOCKED,  fn = cageUnitSums },
    { name = "cage_combinations", tier = M.TIER.LOCKED,  fn = cageCombinations },
    { name = "locked_candidates", tier = M.TIER.LOCKED,  fn = lockedCandidates },
    { name = "naked_pair",        tier = M.TIER.LOCKED,
      fn = function(ctx, st) return nakedSubset(ctx, st, 2, "naked_pair", M.TIER.LOCKED) end },
    { name = "hidden_pair",       tier = M.TIER.SUBSETS,
      fn = function(ctx, st) return hiddenSubset(ctx, st, 2, "hidden_pair", M.TIER.SUBSETS) end },
    { name = "naked_triple",      tier = M.TIER.SUBSETS,
      fn = function(ctx, st) return nakedSubset(ctx, st, 3, "naked_triple", M.TIER.SUBSETS) end },
    { name = "hidden_triple",     tier = M.TIER.SUBSETS,
      fn = function(ctx, st) return hiddenSubset(ctx, st, 3, "hidden_triple", M.TIER.SUBSETS) end },
    { name = "naked_quad",        tier = M.TIER.SUBSETS,
      fn = function(ctx, st) return nakedSubset(ctx, st, 4, "naked_quad", M.TIER.SUBSETS) end },
    { name = "x_wing",            tier = M.TIER.FISH,
      fn = function(ctx, st) return fish(ctx, st, 2, "x_wing", M.TIER.FISH) end },
    { name = "swordfish",         tier = M.TIER.FISH,
      fn = function(ctx, st) return fish(ctx, st, 3, "swordfish", M.TIER.FISH) end },
    { name = "xy_wing",           tier = M.TIER.FISH, fn = xyWing },
}

M.TECHNIQUES = TECHNIQUES

local function applyStep(ctx, st, step)
    if step.placements then
        for _, p in ipairs(step.placements) do
            if not place(ctx, st, (p.r - 1) * ctx.n + p.c, p.digit) then return false end
        end
    end
    if step.eliminations then
        for _, e in ipairs(step.eliminations) do
            eliminate(ctx, st, (e.r - 1) * ctx.n + e.c, e.digit)
            if st.broken then return false end
        end
    end
    return true
end

local function findStep(ctx, st, max_tier)
    for _, tech in ipairs(TECHNIQUES) do
        if tech.tier <= max_tier then
            local step = tech.fn(ctx, st)
            if step then return step end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- opts (all optional):
--   max_tier -- refuse techniques above this tier (default M.TIER.FISH)
--   trace    -- collect every step taken, in order (for explanations/tests)
--
-- Returns:
--   { solved      = bool,   -- reached a full grid by deduction alone
--     max_tier    = int,    -- hardest tier actually needed (0 if nothing to do)
--     counts      = { [technique] = n },
--     unsolved    = int,    -- cells still empty when it gave up
--     contradiction = bool, -- the grid is inconsistent
--     grid        = grid,   -- as far as deduction got
--     steps       = {...} } -- only when opts.trace
function M.solve(grid, n, box_rows, box_cols, extra_regions, opts)
    opts = opts or {}
    local max_tier = opts.max_tier or M.TIER.FISH
    local ctx = getContext(n, box_rows, box_cols, extra_regions)
    local st  = newState(ctx, grid)
    if not st then
        return { solved = false, max_tier = 0, counts = {}, unsolved = -1,
                 contradiction = true, steps = opts.trace and {} or nil }
    end
    st.cages = opts.cages
    st.lean  = not opts.trace

    local counts, steps, best = {}, opts.trace and {} or nil, 0
    while st.unsolved > 0 and not st.broken do
        local step = findStep(ctx, st, max_tier)
        if not step then break end
        counts[step.technique] = (counts[step.technique] or 0) + 1
        if step.tier > best then best = step.tier end
        if steps then steps[#steps + 1] = step end
        if not applyStep(ctx, st, step) then break end
    end

    local out = {}
    for r = 1, n do
        out[r] = {}
        for c = 1, n do out[r][c] = st.value[(r - 1) * n + c] end
    end
    return {
        solved        = (st.unsolved == 0) and not st.broken,
        max_tier      = best,
        counts        = counts,
        unsolved      = st.unsolved,
        contradiction = st.broken,
        grid          = out,
        steps         = steps,
    }
end

-- True if the grid can be solved by deduction alone using nothing above
-- max_tier. This is strictly stronger than "has a unique solution": a grid
-- that passes this necessarily has exactly one solution, since every step
-- taken is forced.
-- cages (optional): killer-style { sum = n, cells = {...} } list, see the
-- cage techniques above.
function M.solvableWithin(grid, n, box_rows, box_cols, extra_regions, max_tier, cages)
    return M.solve(grid, n, box_rows, box_cols, extra_regions,
                   { max_tier = max_tier, cages = cages }).solved
end

-- The single next deduction available on this grid, or nil if none is (either
-- it is finished, it is broken, or it needs more than max_tier). Drives the
-- hint button -- see the step shape documented above the techniques.
function M.nextStep(grid, n, box_rows, box_cols, extra_regions, opts)
    opts = opts or {}
    local ctx = getContext(n, box_rows, box_cols, extra_regions)
    local st  = newState(ctx, grid)
    if not st then return nil end
    st.cages = opts.cages
    return findStep(ctx, st, opts.max_tier or M.TIER.FISH)
end

-- The next deduction that actually FILLS A CELL, plus whatever had to be
-- deduced first to get there.
--
-- nextStep() alone is the wrong shape for a hint button: over half the
-- techniques only strike candidates out, and "you may rule out a 4 here" is
-- useless to a player who keeps no pencil marks. This walks the solver forward
-- through those preparatory steps and stops at the first placement, so a hint
-- is always something the player can act on.
--
-- Returns placement_step, prerequisite_steps, reason
--   placement_step -- a step whose .placements is non-empty, or nil
--   prerequisites  -- eliminations applied on the way (possibly empty)
--   reason         -- why there is no placement: "contradiction" (the grid as
--                     given cannot be completed), "complete" (nothing left to
--                     fill) or "stuck" (no technique within max_tier applies)
function M.nextPlacement(grid, n, box_rows, box_cols, extra_regions, opts)
    opts = opts or {}
    local ctx = getContext(n, box_rows, box_cols, extra_regions)
    local st  = newState(ctx, grid)
    if not st then return nil, nil, "contradiction" end
    st.cages = opts.cages
    if st.unsolved == 0 then return nil, nil, "complete" end

    local max_tier = opts.max_tier or M.TIER.FISH
    local prereq   = {}
    while st.unsolved > 0 and not st.broken do
        local step = findStep(ctx, st, max_tier)
        if not step then return nil, prereq, "stuck" end
        if step.placements and step.placements[1] then return step, prereq, nil end
        prereq[#prereq + 1] = step
        if not applyStep(ctx, st, step) then return nil, prereq, "contradiction" end
    end
    return nil, prereq, st.broken and "contradiction" or "complete"
end

-- Candidate digits per cell, as a grid of digit-arrays. Useful for a
-- "fill in the pencil marks" helper and for explaining a hint.
function M.candidates(grid, n, box_rows, box_cols, extra_regions)
    local ctx = getContext(n, box_rows, box_cols, extra_regions)
    local st  = newState(ctx, grid)
    local out = {}
    for r = 1, n do
        out[r] = {}
        for c = 1, n do
            local idx = (r - 1) * n + c
            out[r][c] = (st and st.value[idx] == 0) and digitsOf(st.cand[idx]) or {}
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Incremental digging support (puzzle_generator.createPuzzle)
--
-- The generator asks solvableWithin() once per cell of the grid, each time on
-- the current puzzle minus one clue, and each call used to rebuild the state
-- from the bare clues and re-derive everything one step at a time. These
-- helpers let it keep a running state instead and answer the same question
-- with less repeated work (16x16 grids: about half the work). They rely on
-- a property of the techniques above:
-- every step is a sound deduction, and knowing more never stops a technique
-- from reaching what it would have reached (a pattern that loses a cell to a
-- placement degenerates into a lower-tier step of the same reach). So the set
-- of facts deducible within a tier does not depend on the order the steps are
-- taken in, which is what makes it safe to
--   * start from facts already known to follow from a subset of the clues,
--   * place every single found in a sweep instead of one per scan,
--   * stop as soon as the removed clue is deduced again (if the puzzle WITH
--     that clue was solvable, deducing it brings back that exact position),
--   * skip re-scanning what found nothing and has not changed since (see
--     unitIdle).
-- Cross-checked 2026-11-04: every one of ~330,000 dig tests over 6,000
-- generated puzzles (4x4 to 16x16, Windoku and Sudoku X regions, every
-- difficulty) gave solvableWithin()'s answer, so the puzzles are identical.
-- M.solve() itself, which rates puzzles and drives hints, is unchanged.
-- Killer cages are not supported here (their techniques read st.cages).
-- ---------------------------------------------------------------------------

-- Empty state on the given shape (no clue placed).
function M.digState(n, box_rows, box_cols, extra_regions)
    local ctx = getContext(n, box_rows, box_cols, extra_regions)
    local st  = { value = {}, cand = {}, unsolved = ctx.cells, broken = false, lean = true }
    for idx = 1, ctx.cells do
        st.value[idx] = 0
        st.cand[idx]  = ctx.full_mask
    end
    return ctx, st
end

-- Turns on the change stamps M.deduce uses to skip idle scans (see
-- unitIdle). Fresh: nothing is known idle yet.
local function trackChanges(ctx, st)
    local ustamp, dstamp, idle = {}, {}, {}
    for u = 1, #ctx.units do ustamp[u] = 0 end
    for d = 1, ctx.n do dstamp[d] = 0 end
    -- -1: never scanned, so never idle (stamps start at 0).
    for i = 1, ctx.idle_slots do idle[i] = -1 end
    st.ustamp, st.dstamp, st.gstamp, st.tick, st.idle = ustamp, dstamp, 0, 0, idle
end

-- A new state holding what base holds plus every clue of grid -- the same
-- state as copying base and placing those clues one by one, built in one
-- pass over the units instead. base must be consistent with grid (it is: it
-- only ever holds clues of grid and what follows from them). The new state
-- keeps change stamps (see unitIdle).
function M.stateWithClues(ctx, base, grid)
    local units, unit_of = ctx.units, ctx.unit_of
    local bv, bc = base.value, base.cand
    local value, cand, umask = {}, {}, {}
    for u = 1, #units do umask[u] = 0 end
    for idx = 1, ctx.cells do
        local v = bv[idx]
        if v == 0 then v = grid[ctx.row_of[idx]][ctx.col_of[idx]] end
        value[idx] = v
        if v ~= 0 then
            local m = lshift(1, v - 1)
            local us = unit_of[idx]
            for i = 1, #us do umask[us[i]] = bor(umask[us[i]], m) end
        end
    end
    local unsolved = 0
    for idx = 1, ctx.cells do
        if value[idx] ~= 0 then
            cand[idx] = 0
        else
            local seen = 0
            local us = unit_of[idx]
            for i = 1, #us do seen = bor(seen, umask[us[i]]) end
            cand[idx] = band(bc[idx], bnot(seen))
            unsolved = unsolved + 1
        end
    end
    local st = { value = value, cand = cand, unsolved = unsolved,
                 broken = false, lean = true }
    trackChanges(ctx, st)
    return st
end

-- Writes a clue into the state unless it is already there. False if it
-- contradicts what the state holds.
function M.placeClue(ctx, st, idx, digit)
    local v = st.value[idx]
    if v ~= 0 then
        if v ~= digit then st.broken = true end
        return not st.broken
    end
    return place(ctx, st, idx, digit)
end

-- Places every naked and hidden single, repeatedly, until none is left.
local function sweepSingles(ctx, st)
    local value, cand, units = st.value, st.cand, ctx.units
    local stamp = st.ustamp
    local changed = true
    while changed and not st.broken do
        changed = false
        for idx = 1, ctx.cells do
            local cm = cand[idx]
            if value[idx] == 0 and cm ~= 0 and band(cm, cm - 1) == 0 then
                if not place(ctx, st, idx, LOW_DIGIT[cm]) then return end
                changed = true
            end
        end
        for u = 1, #units do
            local cells = units[u]
            local key = ctx.idle_hidden_single + u
            if not (stamp and unitIdle(st, key, u)) then
            if stamp then st.tick = st.tick + 1 end
            local placed, once, twice = unitDigitMasks(st, cells)
            local single = band(band(once, bnot(twice)), bnot(placed))
            while single ~= 0 do
                local m = band(single, -single)
                -- An earlier placement in this sweep may already have put
                -- this digit somewhere in the unit (via a peer) -- look again.
                for i = 1, #cells do
                    local idx = cells[i]
                    if value[idx] == 0 and band(cand[idx], m) ~= 0 then
                        if not place(ctx, st, idx, LOW_DIGIT[m]) then return end
                        changed = true
                        break
                    end
                end
                single = band(single, single - 1)
            end
            if stamp then st.idle[key] = st.tick end
            end
        end
    end
end

-- First technique after the singles (and the killer-only ones before
-- locked candidates, which never fire without cages).
local FIRST_NON_SINGLE
for i, tech in ipairs(TECHNIQUES) do
    if tech.name == "locked_candidates" then FIRST_NON_SINGLE = i break end
end

-- Runs deduction within max_tier from st (mutated) until the grid is solved,
-- nothing more applies, or -- if stop_idx is given -- that cell is filled.
-- Returns true when solved or stop_idx was filled.
function M.deduce(ctx, st, max_tier, stop_idx)
    while true do
        sweepSingles(ctx, st)
        if st.broken then return false end
        if st.unsolved == 0 then return true end
        if stop_idx and st.value[stop_idx] ~= 0 then return true end
        local step
        for i = FIRST_NON_SINGLE, #TECHNIQUES do
            local tech = TECHNIQUES[i]
            if tech.tier <= max_tier then
                if st.ustamp then st.tick = st.tick + 1 end
                step = tech.fn(ctx, st)
                if step then break end
            end
        end
        if not step then return false end
        if not applyStep(ctx, st, step) then return false end
    end
end

-- Only the singles: cheap propagation for keeping a running state current.
function M.deduceSingles(ctx, st)
    sweepSingles(ctx, st)
    return not st.broken
end

-- Is there a solution of st with something other than `digit` in cell idx?
-- st is not changed. True: yes, so the grid st came from is ambiguous; false:
-- no; nil: undecided within `budget` search nodes (a count, never a time, so
-- the answer -- and the generator's puzzles -- are the same on every device).
--
-- Every elimination the techniques make holds for every solution (none of
-- them assumes the solution is unique), so searching from a state they have
-- already reduced is sound, and much smaller. The generator calls this on a
-- grid whose own solution has `digit` there: any second solution of the grid
-- without that clue must differ from it in that very cell (otherwise it would
-- also solve the grid with the clue, which has only one), so this is exactly
-- "does removing the clue leave more than one solution?".
--
-- Plain depth-first search: the open cell with the fewest candidates first,
-- each placement striking its digit from the peers. Module-level functions
-- rather than closures, which LuaJIT does not compile.
local os_nodes, os_budget = 0, 0

local function osAssign(peers, value, cand, i, d)
    local m = lshift(1, d - 1)
    local keep = bnot(m)
    value[i] = d
    cand[i]  = 0
    local ps = peers[i]
    for k = 1, #ps do
        local p = ps[k]
        if value[p] == d then return false end
        local cur = cand[p]
        if band(cur, m) ~= 0 then
            cur = band(cur, keep)
            cand[p] = cur
            if cur == 0 and value[p] == 0 then return false end
        end
    end
    return true
end

local function osCopy(t, cells)
    local o = {}
    for i = 1, cells do o[i] = t[i] end
    return o
end

-- Places every naked and hidden single, in place, until none is left. False
-- on a contradiction.
local function osPropagate(ctx, value, cand)
    local cells, units, peers = ctx.cells, ctx.units, ctx.peers
    local changed = true
    while changed do
        changed = false
        for i = 1, cells do
            if value[i] == 0 then
                local cm = cand[i]
                if cm == 0 then return false end
                if band(cm, cm - 1) == 0 then
                    if not osAssign(peers, value, cand, i, LOW_DIGIT[cm]) then return false end
                    changed = true
                end
            end
        end
        for u = 1, #units do
            local us = units[u]
            local placed, once, twice = 0, 0, 0
            for k = 1, #us do
                local i = us[k]
                local v = value[i]
                if v ~= 0 then
                    placed = bor(placed, lshift(1, v - 1))
                else
                    local cm = cand[i]
                    twice = bor(twice, band(once, cm))
                    once  = bor(once, cm)
                end
            end
            if bor(placed, once) ~= ctx.full_mask then return false end
            local single = band(once, bnot(twice))
            while single ~= 0 do
                local m = band(single, -single)
                single = band(single, single - 1)
                for k = 1, #us do
                    local i = us[k]
                    if value[i] == 0 and band(cand[i], m) ~= 0 then
                        if not osAssign(peers, value, cand, i, LOW_DIGIT[m]) then return false end
                        changed = true
                        break
                    end
                end
            end
        end
    end
    return true
end

-- true: a solution; false: none; nil: out of budget.
local function osSearch(ctx, value, cand)
    os_nodes = os_nodes + 1
    if os_nodes > os_budget then return nil end
    if not osPropagate(ctx, value, cand) then return false end
    local cells = ctx.cells
    local best, best_cnt = 0, 99
    for i = 1, cells do
        if value[i] == 0 then
            local cm = cand[i]
            local cnt = POP8[band(cm, 0xFF)] + POP8[rshift(cm, 8)]
            if cnt < best_cnt then
                best, best_cnt = i, cnt
                if cnt <= 2 then break end
            end
        end
    end
    if best == 0 then return true end
    local cm = cand[best]
    while cm ~= 0 do
        local m = band(cm, -cm)
        cm = band(cm, cm - 1)
        local v2, c2 = osCopy(value, cells), osCopy(cand, cells)
        if osAssign(ctx.peers, v2, c2, best, LOW_DIGIT[m]) then
            local found = osSearch(ctx, v2, c2)
            if found ~= false then return found end
        end
    end
    return false
end

function M.otherSolution(ctx, st, idx, digit, budget)
    os_nodes, os_budget = 0, budget
    local others = band(st.cand[idx], bnot(lshift(1, digit - 1)))
    local undecided = false
    while others ~= 0 do
        local m = band(others, -others)
        others = band(others, others - 1)
        local value, cand = osCopy(st.value, ctx.cells), osCopy(st.cand, ctx.cells)
        if osAssign(ctx.peers, value, cand, idx, LOW_DIGIT[m]) then
            local found = osSearch(ctx, value, cand)
            if found then return true end
            if found == nil then undecided = true end
        end
    end
    if undecided then return nil end
    return false
end

return M
