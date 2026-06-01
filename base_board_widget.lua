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

-- ---------------------------------------------------------------------------
-- BaseBoardWidget — shared init / tap / refresh logic
--
-- Subclasses must implement :paintTo(bb, x, y).
-- Subclasses may override :init() and call BaseBoardWidget.init(self) first
-- to add variant-specific font setup (e.g. cage sum labels).
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
    self.dimen = Geom:new{ w = self.size, h = self.size }
    self.paint_rect = Geom:new{ x = 0, y = 0, w = self.size, h = self.size }
    self.number_face = Font:getFace("cfont", math.max(28, math.floor(self.size / 14)))
    self.note_face   = Font:getFace("smallinfofont", math.max(16, math.floor(self.size / 28)))
    self.number_face_size  = self.number_face.size
    self.number_cell_padding = 0
    self.note_face_size    = self.note_face.size
    self.note_mini_padding = 0

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
        local size    = self.note_face_size
        while size > 8 do
            local face = Font:getFace("smallinfofont", size)
            local m    = RenderText:sizeUtf8Text(0, max_w, face, "8", true, false)
            local h    = m.y_bottom - m.y_top
            if m.x <= max_w and h <= max_h then
                local final_size = math.max(8, size - 2)
                self.note_face      = Font:getFace("smallinfofont", final_size)
                self.note_face_size = final_size
                self.note_mini_padding = padding
                break
            end
            size = size - 1
        end
    end

    -- Number font: sized to fit in a full cell
    do
        local cell    = self.size / n
        local padding = math.max(2, math.floor(cell / 9))
        local safety  = math.max(1, math.floor(cell / 20))
        local max_w   = math.max(1, math.floor(cell - 2 * padding - safety))
        local max_h   = math.max(1, math.floor(cell - 2 * padding - safety))
        local size    = self.number_face_size
        while size > 10 do
            local face = Font:getFace("cfont", size)
            local m    = RenderText:sizeUtf8Text(0, max_w, face, "8", true, false)
            local h    = m.y_bottom - m.y_top
            if m.x <= max_w and h <= max_h then
                local final_size = math.max(10, size - 4)
                self.number_face      = Font:getFace("cfont", final_size)
                self.number_face_size = final_size
                self.number_cell_padding = padding
                break
            end
            size = size - 1
        end
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
}
