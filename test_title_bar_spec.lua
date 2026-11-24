-- Spec for BaseScreen:buildTitleBar (same as game-common's), with KOReader's
-- widgets stubbed: the right icon is a house back to the Dashboard when it is
-- installed, close otherwise.
local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

describe("BaseScreen:buildTitleBar", function()
    local saved = {}
    local events      -- what happened, in order

    -- Every other module is a stub: any field is another stub, and calling
    -- one returns its last argument, so Class:extend{} returns its table.
    local function stub()
        return setmetatable({}, {
            __index = function(t, k) local s = stub(); rawset(t, k, s); return s end,
            __call  = function(_, a, b) if b ~= nil then return b end return a end,
        })
    end

    local function stubSearcher(name)
        return function() return stub() end, name
    end

    local function class(base)
        base = base or {}
        base.__index = base
        function base:extend(t) t = t or {}; t.__index = t; return setmetatable(t, self) end
        function base:new(o)
            o = setmetatable(o or {}, self)
            if o._init then o:_init() end
            if o.init then o:init() end
            return o
        end
        return base
    end

    setup(function()
        saved.path = package.path
        package.path = DIR .. "?.lua;" .. package.path
        saved.loaded = {}
        for k, v in pairs(package.loaded) do saved.loaded[k] = v end
        package.loaded["base_screen"] = nil

        package.loaded["device"] = { screen = {
            getWidth  = function() return 758 end,
            getHeight = function() return 1024 end,
        }, hasKeys = function() return false end }
        package.loaded["ui/widget/container/inputcontainer"] = class()
        package.loaded["ui/widget/widget"] = class()
        package.loaded["ui/widget/titlebar"] = class()
        package.loaded["ui/uimanager"] = setmetatable({
            close = function() events[#events + 1] = "close" end,
        }, { __index = function() return function() end end })

        local searchers = package.searchers or package.loaders
        searchers[#searchers + 1] = stubSearcher
    end)

    teardown(function()
        local searchers = package.searchers or package.loaders
        for i = #searchers, 1, -1 do
            if searchers[i] == stubSearcher then table.remove(searchers, i) end
        end
        for k in pairs(package.loaded) do
            if saved.loaded[k] == nil then package.loaded[k] = nil end
        end
        for k, v in pairs(saved.loaded) do package.loaded[k] = v end
        package.path = saved.path
    end)

    before_each(function() events = {} end)

    -- A game screen whose plugin's ui holds `dashboard` (nil: not installed).
    local function screen(dashboard)
        local ScreenBase = require("base_screen").BaseScreen
        local plugin = {
            ui = { dashboard = dashboard },
            saveState      = function() events[#events + 1] = "save" end,
            onScreenClosed = function() events[#events + 1] = "stats" end,
        }
        return setmetatable({ plugin = plugin }, { __index = ScreenBase })
    end

    local function dashboard()
        return { show = function() events[#events + 1] = "dashboard" end }
    end

    it("closes the game when the Dashboard is not installed", function()
        local tb = screen(nil):buildTitleBar("Game", function() return {} end)
        assert.is_function(tb.close_callback)
        assert.is_nil(tb.right_icon)
        tb.close_callback()
        assert.are.same({ "save", "stats", "close" }, events)
    end)

    it("shows a house that saves, closes, then opens the Dashboard", function()
        local tb = screen(dashboard()):buildTitleBar("Game", function() return {} end)
        assert.is_nil(tb.close_callback)
        assert.are.equal("home", tb.right_icon)
        assert.is_false(tb.right_icon_allow_flash)
        tb.right_icon_tap_callback()
        -- Recorded before the Dashboard builds, so its Resume card is current.
        assert.are.same({ "save", "stats", "close", "dashboard" }, events)
    end)

    it("keeps close when ui.dashboard is not the Dashboard plugin", function()
        local tb = screen({}):buildTitleBar("Game", function() return {} end)
        assert.is_function(tb.close_callback)
        assert.is_nil(tb.right_icon)
    end)

    it("still just closes on the Back key", function()
        local s = screen(dashboard())
        s:onClose()
        assert.are.same({ "save", "stats", "close" }, events)
    end)
end)
