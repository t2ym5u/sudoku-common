-- sudoku_common_version.lua must stay in step with this directory and its
-- changelog: module_guard.lua (a verbatim copy of game-common's, tested
-- there) relies on both.
local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local info = dofile(DIR .. "sudoku_common_version.lua")

describe("sudoku_common_version.lua", function()
    it("matches the top entry of CHANGELOG.md", function()
        local f = assert(io.open(DIR .. "CHANGELOG.md"))
        local top = f:read("*a"):match("\n## %[([%d.]+)%]")
        f:close()
        assert.are.equal(top, info.version)
    end)

    it("lists every module of this directory, and nothing else", function()
        local listed, seen = {}, {}
        for _, n in ipairs(info.modules) do listed[n] = true end
        local p = io.popen('ls "' .. DIR .. '"')
        for file in p:lines() do
            local n = file:match("^(.+)%.lua$")
            if n and not n:match("^test_") and n ~= "module_guard" and n ~= "sudoku_common_version" then
                seen[n] = true
                assert.is_true(listed[n] == true, n .. ".lua is missing from sudoku_common_version.lua")
            end
        end
        p:close()
        for n in pairs(listed) do
            assert.is_true(seen[n] == true, n .. " is listed but has no .lua file")
        end
    end)

    it("loads through module_guard.lua", function()
        local Guard = dofile(DIR .. "module_guard.lua")
        local saved = package.loaded[Guard.REGISTRY]
        package.loaded[Guard.REGISTRY] = nil
        local g = Guard(DIR, "sudoku_common_version.lua")
        g.enter() -- a no-op guard (version file unreadable) creates no registry
        g.leave()
        local created = package.loaded[Guard.REGISTRY]
        package.loaded[Guard.REGISTRY] = saved
        assert.is_table(created)
    end)
end)
