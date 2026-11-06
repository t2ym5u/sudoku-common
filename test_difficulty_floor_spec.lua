-- Spec for puzzle_generator's difficulty floors: a 9x9 Medium, Hard or
-- Expert grid must really need more than the singles (and more of it as the
-- level rises), not just have fewer clues. Self-contained, like
-- test_logic_solver_spec.lua: run it with LuaJIT's `bit` module (or the shim
-- scripts/dev/run_specs.sh provides).
local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
package.path = DIR .. "?.lua;" .. package.path

local LS = require("logic_solver")
local PG = require("puzzle_generator")

local function seededRandInt(seed)
    local state = seed
    return function(i)
        state = (1103515245 * state + 12345) % 2147483648
        return state % i + 1
    end
end

local LEVELS = { "easy", "medium", "hard", "expert" }
local SEEDS  = 20

local function rate(puz, n, br, bc, regions, tier)
    local res = LS.solve(puz, n, br, bc, regions, { max_tier = tier })
    return res, PG.nonSingleSteps(res.counts)
end

local function floorHolds(floor, res, steps)
    return steps >= floor.steps or (floor.or_tier ~= nil and res.max_tier >= floor.or_tier)
end

-- Generates SEEDS 9x9 grids per level once, shared by the specs below.
local runs = {}
local function run(diff)
    if runs[diff] then return runs[diff] end
    local out = {}
    for seed = 1, SEEDS do
        local sol = PG.generateSolvedBoard(9, 3, 3, nil, seededRandInt(seed))
        local t0 = os.clock()
        local puz, info = PG.createPuzzle(sol, diff, 9, 3, 3, nil, seededRandInt(seed * 13 + 5))
        out[#out + 1] = { sol = sol, puz = puz, info = info, secs = os.clock() - t0 }
    end
    runs[diff] = out
    return out
end

describe("difficulty floors", function()

    it("has a floor for medium, hard and expert, none for easy", function()
        assert.is_nil(PG.FLOORS.easy)
        for _, d in ipairs({ "medium", "hard", "expert" }) do
            assert.is_table(PG.FLOORS[d])
            assert.is_true(PG.FLOORS[d].attempts >= 1)
        end
        -- Each floor is stricter than the one below it.
        assert.is_true(PG.FLOORS.medium.steps < PG.FLOORS.hard.steps)
        assert.is_true(PG.FLOORS.hard.steps < PG.FLOORS.expert.steps)
    end)

    for _, diff in ipairs(LEVELS) do
        it("9x9 " .. diff .. " grids stay pure logic within the level's tier", function()
            for _, g in ipairs(run(diff)) do
                local res, steps = rate(g.puz, 9, 3, 3, nil, g.info.tier_cap)
                assert.is_true(res.solved)
                assert.are.same(g.sol, res.grid)
                assert.are.equal(steps, g.info.steps)
                assert.are.equal(res.max_tier, g.info.max_tier)
                local clues = 0
                for r = 1, 9 do
                    for c = 1, 9 do
                        if g.puz[r][c] ~= 0 then
                            clues = clues + 1
                            assert.are.equal(g.sol[r][c], g.puz[r][c])
                        end
                    end
                end
                assert.are.equal(clues, g.info.clues)
            end
        end)
    end

    it("leaves 9x9 easy as it was: singles only, 47 clues, one dig", function()
        for _, g in ipairs(run("easy")) do
            assert.are.equal(LS.TIER.SINGLES, g.info.max_tier)
            assert.are.equal(47, g.info.clues)
            assert.are.equal(1, g.info.attempts)
            assert.is_true(g.info.floor_met)
        end
    end)

    for _, diff in ipairs({ "medium", "hard", "expert" }) do
        it("meets the 9x9 " .. diff .. " floor on nearly every grid", function()
            local floor, met = PG.FLOORS[diff], 0
            for _, g in ipairs(run(diff)) do
                local res, steps = rate(g.puz, 9, 3, 3, nil, g.info.tier_cap)
                assert.are.equal(floorHolds(floor, res, steps), g.info.floor_met)
                assert.is_true(g.info.attempts <= floor.attempts)
                if g.info.floor_met then met = met + 1 end
                -- Even a miss is never a grid the singles finish alone.
                assert.is_true(steps >= 1)
            end
            -- Measured 2026-11-06 on 500 seeds: Medium 99%, Hard 96%,
            -- Expert 88%; a miss returns the hardest of its digs.
            assert.is_true(met >= SEEDS * 0.75, diff .. ": floor met on " .. met .. "/" .. SEEDS)
        end)
    end

    it("separates the 9x9 levels: more steps past the singles and fewer clues as they rise", function()
        local prev_steps, prev_clues = -1, 82
        for _, diff in ipairs(LEVELS) do
            local steps, clues = 0, 0
            for _, g in ipairs(run(diff)) do
                steps = steps + g.info.steps
                clues = clues + g.info.clues
            end
            assert.is_true(steps / SEEDS > prev_steps, diff .. " steps " .. steps / SEEDS)
            assert.is_true(clues / SEEDS < prev_clues, diff .. " clues " .. clues / SEEDS)
            prev_steps, prev_clues = steps / SEEDS, clues / SEEDS
        end
    end)

    it("is deterministic and never reads the clock (the Daily Challenge relies on it)", function()
        local clock, time = os.clock, os.time
        local ok, err = pcall(function()
            os.clock = function() error("createPuzzle read os.clock") end
            os.time  = function() error("createPuzzle read os.time") end
            for _, diff in ipairs(LEVELS) do
                for seed = 1, 3 do
                    local sol = PG.generateSolvedBoard(9, 3, 3, nil, seededRandInt(seed + 100))
                    local a, ia = PG.createPuzzle(sol, diff, 9, 3, 3, nil, seededRandInt(seed))
                    local b, ib = PG.createPuzzle(sol, diff, 9, 3, 3, nil, seededRandInt(seed),
                                                  function() end)
                    assert.are.same(a, b)
                    assert.are.equal(ia.attempts, ib.attempts)
                end
            end
        end)
        os.clock, os.time = clock, time
        assert.is_true(ok, err)
    end)

    -- Checksums of what 1.9.0 digs for these seeds (LuaJIT and Lua 5.4+
    -- agree: Park-Miller stays exact in both). A later speed-up must keep
    -- them: a seed gives the same puzzle everywhere.
    local function parkMiller(seed)
        local st = seed
        return function(i)
            st = (st * 16807) % 2147483647
            return st % i + 1
        end
    end
    local function checksum(g, n, acc)
        for r = 1, n do
            for c = 1, n do acc = (acc * 31 + g[r][c]) % 1000000007 end
        end
        return acc
    end
    for _, cf in ipairs({
        { 9, 3, 3, "medium", 244958339 }, { 9, 3, 3, "hard", 859562019 },
        { 9, 3, 3, "expert", 226334444 }, { 12, 3, 4, "hard", 675144626 },
    }) do
        local n, br, bc, diff, want = cf[1], cf[2], cf[3], cf[4], cf[5]
        it(("%dx%d %s: same puzzles as 1.9.0 for the same seeds"):format(n, n, diff), function()
            local acc = 0
            for seed = 1, 5 do
                local randInt = parkMiller(seed * 1000 + 7)
                local sol = PG.generateSolvedBoard(n, br, bc, nil, randInt)
                local puz = PG.createPuzzle(sol, diff, n, br, bc, nil, randInt)
                acc = checksum(puz, n, checksum(sol, n, acc))
            end
            assert.are.equal(want, acc)
        end)
    end

    it("returns the plain dig unchanged when it already meets the floor", function()
        local same, checked = 0, 0
        for _, diff in ipairs({ "medium", "hard", "expert" }) do
            local floor = PG.FLOORS[diff]
            for seed = 1, 12 do
                local sol = PG.generateSolvedBoard(9, 3, 3, nil, seededRandInt(seed + 200))
                PG.FLOORS[diff] = nil
                local ok, plain = pcall(PG.createPuzzle, sol, diff, 9, 3, 3, nil, seededRandInt(seed))
                PG.FLOORS[diff] = floor
                assert.is_true(ok, plain)
                local res, steps = rate(plain, 9, 3, 3, nil, LS.DIFFICULTY_TIER[diff])
                if floorHolds(floor, res, steps) then
                    checked = checked + 1
                    local got = PG.createPuzzle(sol, diff, 9, 3, 3, nil, seededRandInt(seed))
                    assert.are.same(plain, got)
                    same = same + 1
                end
            end
        end
        assert.is_true(checked > 0)
        assert.are.equal(checked, same)
    end)

    it("puts no floor on 4x4 and 6x6 grids (no room past the singles)", function()
        for _, shape in ipairs({ { 4, 2, 2 }, { 6, 2, 3 } }) do
            local n, br, bc = shape[1], shape[2], shape[3]
            for _, diff in ipairs(LEVELS) do
                local sol = PG.generateSolvedBoard(n, br, bc, nil, seededRandInt(n))
                local _, info = PG.createPuzzle(sol, diff, n, br, bc, nil, seededRandInt(n + 1))
                assert.are.equal(1, info.attempts)
                assert.is_true(info.floor_met)
            end
        end
    end)

    it("drives the progress bar forward, ending at 1", function()
        local sol = PG.generateSolvedBoard(9, 3, 3, nil, seededRandInt(9))
        local last, calls = -1, 0
        PG.createPuzzle(sol, "expert", 9, 3, 3, nil, seededRandInt(10), function(done, total)
            calls = calls + 1
            assert.is_true(done / total >= last)
            assert.is_true(done / total <= 1)
            last = done / total
        end)
        assert.is_true(calls > 81)
        assert.are.equal(1, last)
    end)

    it("generates a 9x9 grid of any level in reasonable time", function()
        -- Generous, for plain Lua: under LuaJIT on a desktop the worst 9x9
        -- grid takes ~40 ms (about 1 s on a Kobo Aura).
        for _, diff in ipairs(LEVELS) do
            for _, g in ipairs(run(diff)) do
                assert.is_true(g.secs < 3, diff .. " took " .. g.secs .. " s")
            end
        end
    end)
end)

describe("logic_solver.otherSolution", function()
    -- The dig's shortcut for "the grid without this clue is ambiguous" must
    -- agree with a full solution count on every clue of real puzzles.
    it("agrees with countSolutions() on every clue removal", function()
        local tests, ambiguous = 0, 0
        for seed = 1, 3 do
            local sol = PG.generateSolvedBoard(9, 3, 3, nil, seededRandInt(seed + 300))
            local puz = PG.createPuzzle(sol, "expert", 9, 3, 3, nil, seededRandInt(seed + 400))
            local ctx, empty = LS.digState(9, 3, 3, nil)
            for r = 1, 9 do
                for c = 1, 9 do
                    local digit = puz[r][c]
                    if digit ~= 0 then
                        puz[r][c] = 0
                        local st = LS.stateWithClues(ctx, empty, puz)
                        LS.deduceSingles(ctx, st)
                        local other = LS.otherSolution(ctx, st, (r - 1) * 9 + c, digit, 1e6)
                        local count = PG.countSolutions(puz, 2, 9, 3, 3, nil)
                        assert.are.equal(count > 1, other)
                        tests = tests + 1
                        if other then ambiguous = ambiguous + 1 end
                        puz[r][c] = digit
                    end
                end
            end
        end
        assert.is_true(tests > 50)
        -- Expert grids are minimal: most clue removals are ambiguous.
        assert.is_true(ambiguous > 0)
    end)

    it("says nil, not a guess, when the node budget runs out", function()
        local ctx, empty = LS.digState(9, 3, 3, nil)
        local blank = {}
        for r = 1, 9 do blank[r] = {} for c = 1, 9 do blank[r][c] = 0 end end
        blank[9][9] = 5
        local st = LS.stateWithClues(ctx, empty, blank)
        -- No node at all is not enough to fill 79 more cells.
        assert.is_nil(LS.otherSolution(ctx, st, 1, 1, 0))
        -- With room, an almost empty grid obviously has another solution.
        assert.is_true(LS.otherSolution(ctx, st, 1, 1, 1e6))
    end)
end)
