local ButtonTable    = require("ui/widget/buttontable")
local Blitbuffer     = require("ffi/blitbuffer")
local Device         = require("device")
local Font           = require("ui/font")
local Geom           = require("ui/geometry")
local InfoMessage    = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextViewer     = require("ui/widget/textviewer")
local TextWidget     = require("ui/widget/textwidget")
local UIManager      = require("ui/uimanager")
local _              = require("gettext")
local T              = require("ffi/util").template

local DeviceScreen = Device.screen

-- ---------------------------------------------------------------------------
-- Shared difficulty constants
-- ---------------------------------------------------------------------------

local DIFFICULTY_ORDER = { "easy", "medium", "hard" }
local DIFFICULTY_LABELS = {
    easy   = _("Easy"),
    medium = _("Medium"),
    hard   = _("Hard"),
}

-- ---------------------------------------------------------------------------
-- BaseScreen — shared full-screen game UI
--
-- Subclasses must implement:
--   :buildLayout()           — create board widget + button tables + self.layout
--   :getDifficultyButtonText() — returns localized string for difficulty button
--   :openDifficultyMenu()    — shows difficulty picker
--   :updateStatus([msg])     — refreshes status bar text
-- ---------------------------------------------------------------------------

local BaseScreen = InputContainer:extend{}

function BaseScreen:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = DeviceScreen:getWidth(), h = DeviceScreen:getHeight() }
    self.covers_fullscreen = true
    self.vertical_align    = "center"
    self.note_mode         = false
    self.undo_button       = nil
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
    end
    self.status_text = TextWidget:new{
        text = _("Tap a cell, then pick a number."),
        face = Font:getFace("smallinfofont"),
    }
    self:buildLayout()
    UIManager:setDirty(self, function()
        return "ui", self.dimen
    end)
end

function BaseScreen:paintTo(bb, x, y)
    self.dimen.x = x
    self.dimen.y = y
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, Blitbuffer.COLOR_WHITE)
    local content_size = self.layout:getSize()
    local offset_x = x + math.floor((self.dimen.w - content_size.w) / 2)
    local offset_y = y
    if self.vertical_align == "center" then
        offset_y = offset_y + math.floor((self.dimen.h - content_size.h) / 2)
    end
    self.layout:paintTo(bb, offset_x, offset_y)
end

-- ---------------------------------------------------------------------------
-- Button text helpers
-- ---------------------------------------------------------------------------

function BaseScreen:getNoteButtonText()
    return self.note_mode and _("Note: On") or _("Note: Off")
end

-- ---------------------------------------------------------------------------
-- Button update helpers
-- ---------------------------------------------------------------------------

function BaseScreen:updateNoteButton()
    if not self.note_button then return end
    self.note_button:setText(self:getNoteButtonText(), self.note_button.width)
end

function BaseScreen:updateUndoButton()
    if not self.undo_button then return end
    self.undo_button:enableDisable(self.board:canUndo())
end

function BaseScreen:updateDigitButtons()
    if not self.digit_buttons then return end
    local n = self.board.n
    for d = 1, n do
        local btn = self.digit_buttons[d]
        if btn then
            btn:enableDisable(self.board:countDigit(d) < n)
        end
    end
end

function BaseScreen:updateDifficultyButton()
    if not self.difficulty_button then return end
    self.difficulty_button:setText(self:getDifficultyButtonText(), self.difficulty_button.width)
end

-- ---------------------------------------------------------------------------
-- Mode toggles
-- ---------------------------------------------------------------------------

function BaseScreen:toggleNoteMode()
    self.note_mode = not self.note_mode
    self:updateNoteButton()
    self:updateStatus(self.note_mode and _("Note mode enabled.") or _("Note mode disabled."))
end

-- ---------------------------------------------------------------------------
-- Game actions
-- ---------------------------------------------------------------------------

function BaseScreen:onDigit(value)
    if self.note_mode then
        local ok, err = self.board:toggleNoteDigit(value)
        if not ok then
            self:updateStatus(err)
            return
        end
        self.board_widget:refresh()
        self:updateStatus()
        self.plugin:saveState()
        self:updateUndoButton()
        return
    end
    local ok, err = self.board:setValue(value)
    if not ok then
        self:updateStatus(err)
        return
    end
    self.board_widget:refresh()
    self:updateStatus()
    self.plugin:saveState()
    self:updateUndoButton()
    self:updateDigitButtons()
    if self.board:isSolved() then
        UIManager:show(InfoMessage:new{ text = _("Puzzle complete!"), timeout = 4 })
    end
end

function BaseScreen:onErase()
    local row, col = self.board:getSelection()
    self.board:clearNotes(row, col)
    local ok, err = self.board:clearSelection()
    if not ok then
        self:updateStatus(err)
        return
    end
    self.board_widget:refresh()
    self:updateStatus()
    self.plugin:saveState()
    self:updateUndoButton()
    self:updateDigitButtons()
end

function BaseScreen:onNewGame()
    self.board:generate(self.board.difficulty)
    self.plugin:saveState()
    self.board_widget:refresh()
    self:ensureShowButtonState()
    self:updateUndoButton()
    self:updateDigitButtons()
    self:updateStatus(_("Started a new game."))
end

function BaseScreen:toggleSolution()
    self.board:toggleSolution()
    self.plugin:saveState()
    self.board_widget:refresh()
    self:ensureShowButtonState()
    self:updateStatus(self.board:isShowingSolution() and _("Showing the solution.") or nil)
end

function BaseScreen:ensureShowButtonState()
    if not self.show_result_button then return end
    local text = self.board:isShowingSolution() and _("Hide result") or _("Show result")
    self.show_result_button:setText(text, self.show_result_button.width)
end

function BaseScreen:checkProgress()
    self.board:updateWrongMarks()
    self.board_widget:refresh()
    self.plugin:saveState()
    if self.board:isSolved() then
        self:updateStatus(_("Everything looks good!"))
    elseif self.board:getRemainingCells() == 0 then
        self:updateStatus(_("There are mistakes highlighted in red."))
    else
        self:updateStatus(_("Keep going!"))
    end
end

function BaseScreen:onClose()
    self.plugin:saveState()
    self.plugin:onScreenClosed()
end

function BaseScreen:onUndo()
    local ok, err = self.board:undo()
    if not ok then
        self:updateStatus(err)
        return
    end
    self.board_widget:refresh()
    self:updateStatus(_("Last move undone."))
    self.plugin:saveState()
    self:updateUndoButton()
    self:updateDigitButtons()
end

-- ---------------------------------------------------------------------------
-- Rules dialog (for use in ButtonTable rows)
-- ---------------------------------------------------------------------------

function BaseScreen:showRules(text)
    UIManager:show(TextViewer:new{
        title  = _("Rules"),
        text   = text,
        width  = math.floor(DeviceScreen:getWidth() * 0.9),
        height = math.floor(DeviceScreen:getHeight() * 0.9),
    })
end

function BaseScreen:makeRulesButtonConfig(en_text, fr_text)
    return {
        text     = _("Rules"),
        callback = function()
            local lang = (G_reader_settings and G_reader_settings:readSetting("language") or "en"):sub(1, 2)
            self:showRules((lang == "fr" and fr_text) or en_text)
        end,
    }
end

return {
    BaseScreen       = BaseScreen,
    DIFFICULTY_ORDER  = DIFFICULTY_ORDER,
    DIFFICULTY_LABELS = DIFFICULTY_LABELS,
}
