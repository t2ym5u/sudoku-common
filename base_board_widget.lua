local Blitbuffer    = require("ffi/blitbuffer")
local Device        = require("device")
local Font          = require("ui/font")
local GestureRange  = require("ui/gesturerange")
local Geom          = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local RenderText    = require("ui/rendertext")
local UIManager     = require("ui/uimanager")

local Screen = Device.screen

-- ---------------------------------------------------------------------------
-- Drawing helpers (exported for use in subclass paintTo implementations)
-- ---------------------------------------------------------------------------

local function drawLine(bb, x, y, w, h, color)
    bb:paintRect(x, y, w, h, color)
end

local function drawDiagonalLine(bb, x, y, length, dx, dy, color, thickness)
    color     = color     or Blitbuffer.COLOR_BLACK
    thickness = thickness or 1
    length    = math.max(0, length)
    for step = 0, length do
        local px = math.floor(x + dx * step)
        local py = math.floor(y + dy * step)
        bb:paintRect(px, py, thickness, thickness, color)
    end
end

-- Conflict marker.
--
-- KOReader's palette is greyscale only -- there is no Blitbuffer.COLOR_RED --
-- and every shade dark enough to read as "wrong" is already spoken for
-- (black = given, GRAY_2 = user entry, GRAY_4 = revealed solution). So the
-- conflict is signalled by shape instead: a bar under the digit, which also
-- survives the band/cell highlight painted behind it.
local function drawConflictMark(bb, cell_x, cell_y, cell, color)
    -- Digits sit on a baseline around 0.72 * cell, so a bar in the bottom
    -- margin clears their ink at every grid size (9x9 through 16x16) while
    -- still leaving a gap to the cell border below it.
    local inset     = math.max(1, math.floor(cell / 6))
    local margin    = math.max(2, math.floor(cell / 14))
    local thickness = math.max(2, math.floor(cell / 16))
    local width     = math.max(1, math.floor(cell - 2 * inset))
    local top       = math.floor(cell_y + cell - margin - thickness)
    bb:paintRect(math.floor(cell_x + inset), top, width, thickness,
                 color or Blitbuffer.COLOR_BLACK)
end

local function drawDashedLine(bb, x, y, w, h, color, dash, gap)
    dash = math.max(1, dash or 5)
    gap  = math.max(1, gap  or 3)
    if w >= h then
        local pos = x
        local on  = true
        while pos < x + w do
            local seg = math.min(on and dash or gap, x + w - pos)
            if on then bb:paintRect(math.floor(pos), y, math.max(1, math.floor(seg)), h, color) end
            pos = pos + seg
            on  = not on
        end
    else
        local pos = y
        local on  = true
        while pos < y + h do
            local seg = math.min(on and dash or gap, y + h - pos)
            if on then bb:paintRect(x, math.floor(pos), w, math.max(1, math.floor(seg)), color) end
            pos = pos + seg
            on  = not on
        end
    end
end

-- Largest face size whose ink box for `sample` fits max_w × max_h pixels.
--
-- Measured with an unbounded width: with max_w as the limit sizeUtf8Text cuts
-- the text at max_w, so a width test against it could never fail. y_top and
-- y_bottom are ink above and below the baseline, both positive, so the ink
-- height is their sum (their difference is negative for digits and let every
-- size through -- digits overflowed their cells). Font:getFace scales the
-- size it is given by the screen, so the search bound derived from pixels is
-- divided back by that factor.
local function fitFontSize(font_name, lo, max_w, max_h, sample)
    local scale = Screen:scaleBySize(1000) / 1000
    local hi    = math.max(lo, math.ceil(math.max(max_w, max_h) / scale))
    local best  = lo
    while lo <= hi do
        local mid  = math.floor((lo + hi) / 2)
        local face = Font:getFace(font_name, mid)
        local m    = RenderText:sizeUtf8Text(0, Screen:getWidth(), face, sample, true, false)
        if m.x <= max_w and (m.y_top + m.y_bottom) <= max_h then
            best = mid
            lo   = mid + 1
        else
            hi   = mid - 1
        end
    end
    return best
end

-- ---------------------------------------------------------------------------
-- BaseBoardWidget — shared init / tap / refresh logic
--
-- Subclasses must implement :paintTo(bb, x, y).
-- Subclasses may override :init() and call BaseBoardWidget.init(self) first
-- to add variant-specific font setup (e.g. cage sum labels).
--
-- Options:
--   board    — the board model (required)
--   max_size — side in pixels; overrides the default 0.82 × the short screen
--              side when set (see BaseScreen:getBoardMaxSize)
-- ---------------------------------------------------------------------------

local BaseBoardWidget = InputContainer:extend{
    board = nil,
}

function BaseBoardWidget:init()
    local n        = self.board and self.board.n        or 9
    local box_rows = self.board and self.board.box_rows or 3
    local box_cols = self.board and self.board.box_cols or 3
    self.n        = n
    self.box_rows = box_rows
    self.box_cols = box_cols

    self.size = math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.82)
    -- A screen that knows how much room it has (BaseScreen:getBoardBudget)
    -- passes it here instead of relying on a fixed ratio of the screen.
    if self.max_size then
        self.size = math.max(n, math.floor(self.max_size))
    end
    self.dimen = Geom:new{ w = self.size, h = self.size }
    self.paint_rect = Geom:new{ x = 0, y = 0, w = self.size, h = self.size }

    -- Note font: sized to fit in a mini cell (cell/box_cols × cell/box_rows)
    do
        local cell    = self.size / n
        local mini_w  = cell / box_cols
        local mini_h  = cell / box_rows
        local mini    = math.min(mini_w, mini_h)
        local padding = math.max(1, math.floor(mini / 8))
        local safety  = math.max(1, math.floor(mini / 18))
        local max_w   = math.max(1, math.floor(mini_w - 2 * padding - safety))
        local max_h   = math.max(1, math.floor(mini_h - 2 * padding - safety))
        -- The floor stays low: at 16x16 a mini cell is ~14 px on a 300 dpi
        -- screen, and the old floor of 8 (~15 px there) overflowed it, so the
        -- top row of notes was clipped by the cell border.
        local size    = math.max(5, fitFontSize("smallinfofont", 5, max_w, max_h,
                              n > 9 and "G" or "8") - 1)
        self.note_face         = Font:getFace("smallinfofont", size)
        self.note_face_size    = size
        self.note_mini_padding = padding
    end

    -- Number font: sized to fit in a full cell
    do
        local cell    = self.size / n
        local padding = math.max(2, math.floor(cell / 9))
        local safety  = math.max(1, math.floor(cell / 20))
        local max_w   = math.max(1, math.floor(cell - 2 * padding - safety))
        local max_h   = math.max(1, math.floor(cell - 2 * padding - safety))
        local size    = math.max(10, fitFontSize("cfont", 10, max_w, max_h,
                              n > 9 and "G" or "8") - 2)
        self.number_face         = Font:getFace("cfont", size)
        self.number_face_size    = size
        self.number_cell_padding = padding
    end

    self.ges_events = {
        Tap = {
            GestureRange:new{
                ges   = "tap",
                range = function() return self.paint_rect end,
            }
        }
    }
end

function BaseBoardWidget:getCellFromPoint(x, y)
    local rect    = self.paint_rect
    local local_x = x - rect.x
    local local_y = y - rect.y
    if local_x < 0 or local_y < 0 or local_x > rect.w or local_y > rect.h then
        return nil
    end
    local cell_size = rect.w / self.n
    local col = math.floor(local_x / cell_size) + 1
    local row = math.floor(local_y / cell_size) + 1
    if row < 1 or row > self.n or col < 1 or col > self.n then
        return nil
    end
    return row, col
end

function BaseBoardWidget:onTap(_, ges)
    if not (self.board and ges and ges.pos) then
        return false
    end
    local row, col = self:getCellFromPoint(ges.pos.x, ges.pos.y)
    if not row then
        return false
    end
    self.board:setSelection(row, col)
    if self.onSelectionChanged then
        self.onSelectionChanged(row, col)
    end
    self:refresh()
    return true
end

function BaseBoardWidget:refresh()
    local rect = self.paint_rect
    UIManager:setDirty(self, function()
        return "ui", Geom:new{ x = rect.x, y = rect.y, w = rect.w, h = rect.h }
    end)
end

return {
    BaseBoardWidget  = BaseBoardWidget,
    drawLine         = drawLine,
    drawDiagonalLine = drawDiagonalLine,
    drawConflictMark = drawConflictMark,
    drawDashedLine   = drawDashedLine,
    fitFontSize      = fitFontSize,
}
